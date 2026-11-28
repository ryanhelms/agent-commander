package device

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"time"

	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/identity"
	"agentcommander.network/pilot/internal/netlog"
)

const (
	retryMin = time.Second
	retryMax = time.Minute
	// wakeGap is how far the wall clock may run ahead of the monotonic clock
	// before a wait counts as interrupted by sleep. On macOS the monotonic
	// clock stops while the Mac sleeps; the wall clock does not.
	wakeGap = 5 * time.Second
	// wakePoll bounds how late a waiting loop notices a wake.
	wakePoll = 2 * time.Second

	sessionEndedText = "Your relay session ended (expired or revoked). Sign in again."
)

var errNotSignedIn = errors.New("sign in to the relay first")

// clock reads the monotonic and wall clocks separately so a sleep shows up as
// the difference between them.
type clock interface {
	Mono() time.Duration
	Wall() time.Time
}

type systemClock struct{ origin time.Time }

var processClock = systemClock{origin: time.Now()}

func (c systemClock) Mono() time.Duration { return time.Since(c.origin) }
func (systemClock) Wall() time.Time       { return time.Now().Round(0) }

// mark is one reading of both clocks.
type mark struct {
	mono time.Duration
	wall time.Time
}

func now(c clock) mark { return mark{c.Mono(), c.Wall()} }

// slept reports how much wall time passed beyond the monotonic time since m.
func (m mark) slept(c clock) time.Duration {
	if m.wall.IsZero() {
		return 0
	}
	gap := c.Wall().Sub(m.wall) - (c.Mono() - m.mono)
	if gap < wakeGap {
		return 0
	}
	return gap
}

// backoff doubles from retryMin to retryMax with ±20% jitter.
type backoff struct {
	attempt int
	jitter  func() float64 // [0,1); nil uses math/rand
}

func (b *backoff) next() time.Duration {
	base := retryMin << min(b.attempt, 16)
	if base > retryMax || base <= 0 {
		base = retryMax
	}
	b.attempt++
	r := 0.5
	if b.jitter != nil {
		r = b.jitter()
	} else {
		r = rand.Float64()
	}
	d := time.Duration(float64(base) * (0.8 + 0.4*r))
	return min(max(d, retryMin), retryMax)
}

func (b *backoff) reset() { b.attempt = 0 }

// refreshClass names how a failed refresh is handled.
type refreshClass string

const (
	refreshOK        refreshClass = "ok"
	refreshTransient refreshClass = "transient"
	refreshTerminal  refreshClass = "terminal"
	refreshCanceled  refreshClass = "canceled"
)

// classifyRefresh separates a relay that rejected the refresh token (401 or
// 403: the session is gone) from failures worth retrying.
func classifyRefresh(ctx context.Context, err error) (refreshClass, int) {
	if err == nil {
		return refreshOK, 0
	}
	var h identity.HTTPError
	if errors.As(err, &h) {
		if h.Status == http.StatusUnauthorized || h.Status == http.StatusForbidden {
			return refreshTerminal, h.Status
		}
		return refreshTransient, h.Status
	}
	if ctx != nil && ctx.Err() != nil {
		return refreshCanceled, 0
	}
	return refreshTransient, 0
}

// refreshError is a session renewal failure. Terminal ones ended the session.
type refreshError struct {
	terminal bool
	status   int
	retryIn  time.Duration
	err      error
}

func (e *refreshError) Error() string {
	if e.terminal {
		return sessionEndedText
	}
	return fmt.Sprintf("Could not renew the relay session; retrying in %s: %v", max(e.retryIn, time.Second).Round(time.Second), e.err)
}

func (e *refreshError) Unwrap() error { return e.err }

// refreshState spaces out renewal attempts after transient failures. authMu guards it.
type refreshState struct {
	attempts int
	failed   mark
	retryAt  time.Duration // monotonic
	backoff  backoff
	last     *refreshError
}

func (a *Agent) logger() *slog.Logger {
	if a.cfg.Log != nil {
		return a.cfg.Log
	}
	return netlog.Discard()
}

func (a *Agent) clock() clock {
	if a.cfg.clock != nil {
		return a.cfg.clock
	}
	return processClock
}

// pause waits d and returns early after a wake from sleep. It reports false
// when ctx ends.
func (a *Agent) pause(ctx context.Context, loop string, d time.Duration) bool {
	if a.cfg.sleep != nil {
		return a.cfg.sleep(ctx, d)
	}
	if d <= 0 {
		return ctx.Err() == nil
	}
	c := a.clock()
	start := now(c)
	deadline := time.NewTimer(d)
	defer deadline.Stop()
	tick := time.NewTicker(min(d, wakePoll))
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return false
		case <-deadline.C:
			return true
		case <-tick.C:
			if gap := start.slept(c); gap > 0 {
				a.logger().Info("wake_gap", "loop", loop, "gap_ms", gap.Milliseconds())
				return true
			}
		}
	}
}

// renew refreshes s under authMu. It returns the new session, or an error
// that is gated, transient or terminal.
func (a *Agent) renew(ctx context.Context, s identity.Session) (identity.Session, error) {
	c := a.clock()
	st := &a.refresh
	if st.last != nil {
		woke := st.failed.slept(c)
		if woke == 0 && c.Mono() < st.retryAt {
			gated := *st.last
			gated.retryIn = st.retryAt - c.Mono()
			return s, &gated
		}
		if woke > 0 {
			a.logger().Info("wake_gap", "loop", "refresh", "gap_ms", woke.Milliseconds())
			st.backoff.reset()
		}
	}
	st.attempts++
	started := time.Now()
	n, err := a.identity.Refresh(ctx, s.RefreshToken)
	if err == nil && (n.User != s.User || n.Device != s.Device) {
		err = errors.New("refreshed identity changed")
	}
	class, status := classifyRefresh(ctx, err)
	if err != nil && class == refreshOK {
		class = refreshTransient
	}
	attrs := []any{"attempt", st.attempts, "outcome", string(class), "status", status, "latency_ms", time.Since(started).Milliseconds()}
	switch class {
	case refreshOK:
		a.mu.Lock()
		next := a.creds
		next.Session = n
		// The relay already rotated. Keep the new session in memory even when
		// the Keychain write fails; the old token is dead.
		a.creds = next
		perr := a.persistCredentials(next)
		a.mu.Unlock()
		if perr != nil {
			attrs = append(attrs, "err", "persist: "+perr.Error())
		}
		a.logger().Info("refresh", attrs...)
		*st = refreshState{}
		return n, nil
	case refreshCanceled:
		a.logger().Info("refresh", append(attrs, "err", err.Error())...)
		return s, err
	case refreshTerminal:
		a.logger().Warn("refresh", append(attrs, "err", err.Error())...)
		*st = refreshState{}
		a.endSession(s.RefreshToken, status)
		return identity.Session{}, &refreshError{terminal: true, status: status, err: err}
	default:
		d := st.backoff.next()
		st.failed = now(c)
		st.retryAt = st.failed.mono + d
		st.last = &refreshError{status: status, retryIn: d, err: err}
		a.logger().Warn("refresh", append(attrs, "err", err.Error(), "retry_in_ms", d.Milliseconds())...)
		out := *st.last
		return s, &out
	}
}

// endSession forgets a session the relay no longer accepts. It keeps the
// device keys and runs under authMu. A sign-in or sign-out that already
// replaced the session wins.
func (a *Agent) endSession(refreshToken string, status int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.creds.Session.User == "" || a.creds.Session.RefreshToken != refreshToken {
		return
	}
	next := a.creds
	next.Session = identity.Session{}
	if err := a.persistCredentials(next); err != nil {
		// Forget it in memory anyway; a restart tries the dead token once more.
		a.logger().Error("session_clear", "err", err.Error())
	}
	a.creds = next
	if a.sessionStop != nil {
		a.sessionStop()
	}
	a.lease = control.Lease{}
	if err := a.loadPolicy(""); err != nil {
		a.logger().Error("policy_reset", "err", err.Error())
	}
	a.problem = sessionEndedText
	a.logger().Warn("state", "state", "signedOut", "reason", "refresh_rejected", "status", status)
}

// noteSessionProblem shows a loop's session error in the tray while the
// session that failed is still the current one.
func (a *Agent) noteSessionProblem(user string, err error) {
	if err == nil || user == "" || errors.Is(err, errNotSignedIn) || errors.Is(err, context.Canceled) {
		return
	}
	var re *refreshError
	if errors.As(err, &re) && re.terminal {
		return // endSession already set the message.
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.creds.Session.User == user {
		a.problem = err.Error()
	}
}

// retryDelay is how long a loop waits after err: the refresh gate's own
// schedule when it set one, otherwise the loop's backoff.
func retryDelay(err error, b *backoff) time.Duration {
	var re *refreshError
	if errors.As(err, &re) && !re.terminal && re.retryIn > 0 {
		return re.retryIn
	}
	return b.next()
}

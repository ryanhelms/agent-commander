package device

import (
	"context"
	"errors"
	"log/slog"
	"net/url"
	"os"
	"path/filepath"
	"time"

	"agentcommander.network/pilot/internal/devicekeys"
	"agentcommander.network/pilot/internal/netlog"
)

// relayHost is the relay origin's host for the log.
func relayHost(origin string) string {
	u, err := url.Parse(origin)
	if err != nil {
		return ""
	}
	return u.Host
}

const diagnosticsLines = 200

// diagnostics returns the network log's path and its last lines.
func (m *Manager) diagnostics() (any, error) {
	out := map[string]any{"logPath": m.cfg.LogPath, "tail": []string{}}
	if m.cfg.LogPath == "" {
		return out, nil
	}
	tail, err := netlog.Tail(m.cfg.LogPath, diagnosticsLines)
	if err != nil {
		return nil, err
	}
	out["tail"] = tail
	// The serve process's captured stderr holds any Go panic.
	stderr := filepath.Join(filepath.Dir(m.cfg.LogPath), netlog.StderrFileName)
	if lines, err := netlog.Tail(stderr, 50); err == nil && len(lines) > 0 {
		out["stderrPath"], out["stderrTail"] = stderr, lines
	}
	return out, nil
}

const (
	keychainWaitingText = "Respond to the macOS Keychain prompt if one appears. Agent Commander will continue when access is ready."
	keychainRetryText   = "Keychain access was declined or unavailable. Turn Connect automatically off and on to retry, then respond to any macOS prompt."
)

type serverActivation struct {
	ctx                context.Context
	cancel             context.CancelFunc
	starting           bool
	waitingForKeychain bool
	done               chan struct{}
}

type serverActivationStatus struct {
	state, detail string
}

func (e *serverActivationStatus) Error() string { return e.detail }

func (e *serverActivationStatus) status() map[string]any {
	return map[string]any{
		"state": e.state, "error": e.detail, "online": false, "signedIn": false,
		"loginPending": false, "handle": "", "friends": []any{}, "incoming": []any{},
		"outgoing": []any{}, "grants": []any{}, "resources": []any{}, "shared": []any{},
	}
}

// activationProblem is only read under m.mu.
func (m *Manager) activationProblem(s Server) error {
	if !s.AutoConnect {
		return nil
	}
	if attempt := m.activations[s.ID]; attempt != nil && attempt.starting {
		if attempt.waitingForKeychain {
			return &serverActivationStatus{state: "keychainPending", detail: keychainWaitingText}
		}
		return &serverActivationStatus{state: "connecting", detail: "The server is starting. Try again shortly."}
	}
	problem := m.problems[s.ID]
	if errors.Is(problem, devicekeys.ErrKeychainAccess) {
		return &serverActivationStatus{state: "error", detail: keychainRetryText}
	}
	return problem
}

// An invite that just added a server gives ordinary startup a brief chance to
// finish within that request. A held credential check returns the current
// waiting state, with no sign-in scheduled after the request has failed.
func (m *Manager) agentForInvite(ctx context.Context, id string) (*Agent, error) {
	m.mu.Lock()
	attempt := m.activations[id]
	if attempt == nil || !attempt.starting {
		defer m.mu.Unlock()
		return m.agentUseLocked(id, true)
	}
	m.mu.Unlock()

	timer := time.NewTimer(250 * time.Millisecond)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-attempt.ctx.Done():
	case <-attempt.done:
	case <-timer.C:
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	if current := m.activations[id]; current != nil && current != attempt {
		return nil, errors.New("The server connection changed. Try joining again.")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return m.agentUseLocked(id, true)
}

func (m *Manager) logger() *slog.Logger {
	if m.cfg.Log != nil {
		return m.cfg.Log
	}
	return netlog.Discard()
}

func (m *Manager) activate(ctx context.Context, s Server, attempt *serverActivation) {
	log := m.logger().With("server", s.ID)
	log.Info("activation_start", "relay", relayHost(s.URL))
	started := time.Now()
	a, err := m.openAgent(ctx, s, attempt)
	outcome := "ok"
	switch {
	case ctx.Err() != nil:
		outcome = "canceled"
	case err != nil:
		outcome = "error"
	}
	log.Info("activation_result", "outcome", outcome, "err", errText(err), "duration_ms", time.Since(started).Milliseconds())
	m.mu.Lock()
	defer m.mu.Unlock()
	defer close(attempt.done)

	attempt.starting = false
	if m.closed || ctx.Err() != nil || m.certChanged[s.ID] {
		delete(m.activations, s.ID)
		attempt.cancel()
		if a != nil {
			a.Close()
		}
		// An edit requested another connection while this one was stopping.
		// The original credential access has settled, so its replacement can start.
		if i := m.find(s.ID); !m.closed && m.ctx.Err() == nil && i >= 0 &&
			m.servers[i].AutoConnect && !m.certChanged[s.ID] {
			m.start(m.servers[i])
		}
		return
	}
	if err != nil {
		delete(m.activations, s.ID)
		attempt.cancel()
		m.problems[s.ID] = err
		return
	}
	m.agents[s.ID] = a
	a.start()
}

func (m *Manager) openAgent(ctx context.Context, s Server, attempt *serverActivation) (*Agent, error) {
	dir := filepath.Join(m.cfg.Dir, "servers", s.ID)
	if err := os.MkdirAll(filepath.Dir(dir), 0700); err != nil {
		return nil, err
	}
	store, err := m.cfg.Secrets(s.URL)
	if err != nil {
		return nil, err
	}
	config := Config{
		ServerID: s.ID, Relay: s.URL, Dir: dir, CommanderSocket: m.cfg.CommanderSocket,
		Secrets: store, Roots: m.cfg.Roots, OIDCHTTP: m.cfg.OIDCHTTP, OpenBrowser: m.cfg.OpenBrowser,
		Pin: s.Pin, GoogleDesktopConfig: filepath.Join(m.cfg.Dir, "google-desktop-client.json"),
		Log: m.logger().With("server", s.ID),
		OnPinMismatch: func() {
			go func() {
				m.mu.Lock()
				defer m.mu.Unlock()
				if m.activations[s.ID] == attempt && ctx.Err() == nil {
					m.certChanged[s.ID] = true
					m.stop(s.ID)
				}
			}()
		},
	}
	if devicekeys.IsKeychain(store) {
		config.onStartupCredentials = func(waiting bool) {
			m.logger().Info("keychain_wait", "server", s.ID, "waiting", waiting)
			m.mu.Lock()
			attempt.waitingForKeychain = waiting
			m.mu.Unlock()
		}
	}
	return prepareAgent(ctx, config)
}

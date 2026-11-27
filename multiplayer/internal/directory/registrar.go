package directory

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Registrar keeps one relay listed: it registers now, heartbeats every
// HeartbeatEvery, and removes the listing when its context ends. With Target
// set it reads the listing again on each check, so turning listing on, off or
// to another address takes effect without a restart.
type Registrar struct {
	Directory string // directory origin, e.g. DefaultURL
	PublicURL string // the relay's public https origin
	Cert      tls.Certificate
	HTTP      *http.Client
	Every     time.Duration
	// Target, when set, returns the public origin (empty for unlisted) and the
	// directory on each check, replacing PublicURL and Directory.
	Target func() (publicURL, directoryURL string)
	// Check is how often Target is read; default 30 seconds.
	Check time.Duration
	// OnStatus reports each registration attempt and each change of target.
	OnStatus func(Status)
	Now      func() time.Time
	Log      func(format string, args ...any)
}

// Status is the outcome of the last listing attempt.
type Status struct {
	URL       string    `json:"url,omitempty"`
	Listed    bool      `json:"listed"`
	Error     string    `json:"error,omitempty"`
	CheckedAt time.Time `json:"checkedAt"`
}

func (r Registrar) logf(format string, args ...any) {
	if r.Log != nil {
		r.Log(format, args...)
	}
}

func (r Registrar) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}

func (r Registrar) target() (string, string) {
	if r.Target != nil {
		return r.Target()
	}
	return r.PublicURL, r.Directory
}

func (r Registrar) report(s Status) {
	if r.OnStatus != nil {
		r.OnStatus(s)
	}
}

// Run keeps the listing current until ctx ends, then removes it.
func (r Registrar) Run(ctx context.Context) {
	every, check := r.Every, r.Check
	if every <= 0 {
		every = HeartbeatEvery
	}
	if check <= 0 {
		check = 30 * time.Second
	}
	if check > every {
		check = every
	}
	var listed, listedDir string // what the directory holds for us now
	var want, wantDir string     // the last target seen
	var next time.Time           // when to register again
	type place struct{ url, dir string }
	var stale []place // removals the directory refused, retried on each check
	step := func() {
		kept := stale[:0]
		for _, p := range stale {
			if err := r.sendTo(ctx, p.url, p.dir, "remove"); err != nil && ctx.Err() == nil {
				kept = append(kept, p)
			}
		}
		stale = kept
		raw, dir := r.target()
		origin := ""
		if raw != "" {
			var err error
			if origin, err = NormalizeURL(raw); err != nil {
				r.report(Status{URL: raw, Error: "the public address is not an https origin", CheckedAt: r.now()})
				return
			}
		}
		if origin != want || dir != wantDir {
			want, wantDir, next = origin, dir, time.Time{}
			if listed != "" {
				if err := r.sendTo(ctx, listed, listedDir, "remove"); err != nil && ctx.Err() == nil {
					r.logf("directory: could not remove %s yet: %v", listed, err)
					stale = append(stale, place{listed, listedDir})
				}
				listed = ""
			}
			if origin == "" {
				r.report(Status{CheckedAt: r.now()})
			}
		}
		if origin == "" || r.now().Before(next) {
			return
		}
		err := r.sendTo(ctx, origin, dir, "register")
		if ctx.Err() != nil {
			return
		}
		st := Status{URL: origin, Listed: err == nil, CheckedAt: r.now()}
		if err != nil {
			st.Error = err.Error()
			r.logf("directory: not listed: %v", err)
			next = r.now().Add(2 * check)
			listed = ""
		} else {
			listed, listedDir, next = origin, dir, r.now().Add(every)
		}
		r.report(st)
	}
	t := time.NewTicker(check)
	defer t.Stop()
	for {
		step()
		select {
		case <-ctx.Done():
			if listed != "" {
				stale = append(stale, place{listed, listedDir})
			}
			remove, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			for _, p := range stale {
				if err := r.sendTo(remove, p.url, p.dir, "remove"); err != nil {
					r.logf("directory: could not remove the listing: %v", err)
				}
			}
			cancel()
			return
		case <-t.C:
		}
	}
}

// Send signs and posts one registration or removal for PublicURL.
func (r Registrar) Send(ctx context.Context, action string) error {
	return r.sendTo(ctx, r.PublicURL, r.Directory, action)
}

func (r Registrar) sendTo(ctx context.Context, publicURL, directoryURL, action string) error {
	dir, err := NormalizeURL(directoryURL)
	if err != nil {
		return fmt.Errorf("directory URL: %w", err)
	}
	reg, err := NewRegistration(action, publicURL, r.Cert, r.now())
	if err != nil {
		return err
	}
	signed, err := Sign(reg, r.Cert)
	if err != nil {
		return err
	}
	body, err := json.Marshal(signed)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, "POST", dir+"/v1/relays", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	client := r.HTTP
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		var e struct{ Error string }
		_ = json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&e)
		if e.Error == "" {
			e.Error = resp.Status
		}
		return errors.New(strings.TrimSpace(e.Error))
	}
	return nil
}

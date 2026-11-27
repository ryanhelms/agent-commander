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
// HeartbeatEvery, and removes the listing when its context ends.
type Registrar struct {
	Directory string // directory origin, e.g. DefaultURL
	PublicURL string // the relay's public https origin
	Cert      tls.Certificate
	HTTP      *http.Client
	Every     time.Duration
	Now       func() time.Time
	Log       func(format string, args ...any)
}

func (r Registrar) logf(format string, args ...any) {
	if r.Log != nil {
		r.Log(format, args...)
	}
}

// Run registers until ctx ends, then removes the listing.
func (r Registrar) Run(ctx context.Context) {
	every := r.Every
	if every <= 0 {
		every = HeartbeatEvery
	}
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		if err := r.Send(ctx, "register"); err != nil && ctx.Err() == nil {
			r.logf("directory: not listed: %v", err)
		}
		select {
		case <-ctx.Done():
			remove, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			if err := r.Send(remove, "remove"); err != nil {
				r.logf("directory: could not remove the listing: %v", err)
			}
			cancel()
			return
		case <-t.C:
		}
	}
}

// Send signs and posts one registration or removal.
func (r Registrar) Send(ctx context.Context, action string) error {
	dir, err := NormalizeURL(r.Directory)
	if err != nil {
		return fmt.Errorf("directory URL: %w", err)
	}
	now := time.Now
	if r.Now != nil {
		now = r.Now
	}
	reg, err := NewRegistration(action, r.PublicURL, r.Cert, now())
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

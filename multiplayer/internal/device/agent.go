// Package device hosts the signed-in user's local multiplayer connection.
package device

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"agentcommander.network/pilot/internal/actions"
	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/devicekeys"
	"agentcommander.network/pilot/internal/identity"
	"agentcommander.network/pilot/internal/netlog"
)

const DefaultRelay = "https://srv01.agentmux.bytedesk.ai"

type Config struct {
	ServerID                    string
	Relay, Dir, CommanderSocket string
	Secrets                     devicekeys.Store
	Roots                       *x509.CertPool
	OpenBrowser                 func(string) error
	OIDCHTTP                    *http.Client
	// Pin, when set, replaces chain verification with a SubjectPublicKeyInfo
	// SHA-256 match ("sha256/<base64>"). OnPinMismatch runs when it fails.
	Pin                 string
	OnPinMismatch       func()
	GoogleDesktopConfig string
	// Log receives the network log's events. Nil discards them.
	Log                  *slog.Logger
	configureActions     func(actions.Config) actions.Config
	onStartupCredentials func(bool)
	// clock and sleep replace the system clock and wake-aware waits in tests.
	clock clock
	sleep func(context.Context, time.Duration) bool
}
type credentials struct {
	Keys    *devicekeys.Keys
	Session identity.Session
	Tokens  map[string]string
}
type localPolicy struct {
	Resources []actions.Resource
	Grants    []actions.Grant
	// GroupTemplates hold the owner's consent; Grants holds the per-member expansions.
	GroupTemplates []actions.Grant `json:"groupTemplates,omitempty"`
	Pins           map[string]devicekeys.Public
	// Published is the relay's display mirror. Only Grants authorizes execution.
	Published []trayGrant `json:"publishedGrants,omitempty"`
}
type Agent struct {
	cfg         Config
	http        *http.Client
	identity    identity.Client
	keys        *devicekeys.Keys
	mu          sync.Mutex
	authMu      sync.Mutex
	edit        sync.Mutex
	grantReadMu sync.Mutex
	sendMu      sync.Mutex
	receiptMu   sync.Mutex
	// sendMu guards the current account's outstanding requester audits.
	auditUser    string
	unsettled    map[string]bool
	creds        credentials
	policy       localPolicy
	lease        control.Lease
	loginPending bool
	problem      string
	// access is the membership-request state after a refused sign-in:
	// "", requestable, pending, approved, denied or full.
	access      string
	handle      string
	friendsOn   int
	incoming    int
	lastOnline  time.Time
	social      socialState
	pending     map[string]claimedRequest
	handovers   map[string]time.Time
	ctx         context.Context
	stop        context.CancelFunc
	loginStop   context.CancelFunc
	sessionStop context.CancelFunc
	// refresh spaces out renewal retries. authMu guards it.
	refresh refreshState
}

func key(text string) string { sum := sha256.Sum256([]byte(text)); return hex.EncodeToString(sum[:]) }
func save(path string, v any) error {
	return writePrivateFile(path, func(w io.Writer) error { return json.NewEncoder(w).Encode(v) })
}

func writePrivateFile(path string, write func(io.Writer) error) error {
	f, e := os.CreateTemp(filepath.Dir(path), ".save-*")
	if e != nil {
		return e
	}
	defer os.Remove(f.Name())
	if e = write(f); e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e != nil {
		return e
	}
	if ce != nil {
		return ce
	}
	if e = os.Rename(f.Name(), path); e != nil {
		return e
	}
	dir, e := os.Open(filepath.Dir(path))
	if e != nil {
		return e
	}
	defer dir.Close()
	return dir.Sync()
}
func privateDir(path string) error {
	if !filepath.IsAbs(path) {
		return errors.New("device state requires an absolute directory")
	}
	if e := os.MkdirAll(path, 0700); e != nil {
		return e
	}
	st, e := os.Lstat(path)
	if e != nil {
		return e
	}
	if !st.IsDir() || st.Mode().Perm()&0077 != 0 {
		return errors.New("device state directory must be private (0700)")
	}
	return nil
}
func New(ctx context.Context, c Config) (*Agent, error) {
	a, err := prepareAgent(ctx, c)
	if err != nil {
		return nil, err
	}
	a.start()
	return a, nil
}

func prepareAgent(ctx context.Context, c Config) (*Agent, error) {
	u, e := url.Parse(c.Relay)
	if e != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || strings.Trim(u.Path, "/") != "" {
		return nil, errors.New("expected HTTPS relay origin")
	}
	c.Relay = strings.TrimRight(c.Relay, "/")
	if c.Secrets == nil || c.OpenBrowser == nil {
		return nil, errors.New("credential store and system browser required")
	}
	if e = privateDir(c.Dir); e != nil {
		return nil, e
	}
	a := &Agent{cfg: c}
	if e = a.loadStartupCredentials(ctx); e != nil {
		return nil, e
	}
	if a.creds.Keys == nil {
		return nil, errors.New("invalid device credential record")
	}
	a.keys = a.creds.Keys
	cert, e := a.keys.TLSCertificate()
	if e != nil {
		return nil, e
	}
	tlsConfig := &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{cert}, RootCAs: c.Roots}
	if c.Pin != "" {
		tlsConfig.InsecureSkipVerify = true
		tlsConfig.VerifyConnection = func(cs tls.ConnectionState) error {
			if len(cs.PeerCertificates) == 0 || SPKIPin(cs.PeerCertificates[0]) != c.Pin {
				if c.OnPinMismatch != nil {
					c.OnPinMismatch()
				}
				return ErrPinMismatch
			}
			return nil
		}
	}
	transport := &http.Transport{TLSClientConfig: tlsConfig, ForceAttemptHTTP2: true}
	a.http = &http.Client{Transport: transport, Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	a.identity = identity.Client{
		BaseURL: c.Relay, HTTP: a.http, OIDCHTTP: c.OIDCHTTP,
		GoogleDesktopConfig: googleConfig(c),
	}
	a.ctx, a.stop = context.WithCancel(ctx)
	if e = a.loadPolicy(a.creds.Session.User); e != nil {
		a.stop()
		return nil, e
	}
	a.loadSocial()
	if err := ctx.Err(); err != nil {
		a.Close()
		return nil, err
	}
	return a, nil
}

func (a *Agent) start() {
	go a.receiveLoop()
	go a.eventsLoop()
}

// loadStartupCredentials can await the owner's OS interaction. An activation
// canceled during a read cannot generate or persist credentials afterward.
func (a *Agent) loadStartupCredentials(ctx context.Context) error {
	var raw []byte
	err := a.withStartupCredentialAccess(ctx, func() error {
		var err error
		raw, err = a.cfg.Secrets.Load()
		return err
	})
	switch {
	case errors.Is(err, os.ErrNotExist):
		a.creds.Keys, err = devicekeys.Generate()
		if err != nil {
			return err
		}
		return a.withStartupCredentialAccess(ctx, func() error {
			return a.persistCredentials(a.creds)
		})
	case err == nil:
		return json.Unmarshal(raw, &a.creds)
	default:
		return err
	}
}

func (a *Agent) withStartupCredentialAccess(ctx context.Context, access func() error) error {
	if progress := a.cfg.onStartupCredentials; progress != nil {
		progress(true)
		defer progress(false)
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	err := access()
	if ctxErr := ctx.Err(); ctxErr != nil {
		return ctxErr
	}
	return err
}

func (a *Agent) Close() { a.stop(); a.http.CloseIdleConnections() }
func (a *Agent) persistCredentials(c credentials) error {
	b, e := json.Marshal(c)
	if e != nil {
		return e
	}
	return a.cfg.Secrets.Save(b)
}
func (a *Agent) policyPath(user string) string {
	return filepath.Join(a.cfg.Dir, "policy-"+key(a.cfg.Relay+"|"+user)+".json")
}
func (a *Agent) loadPolicy(user string) error {
	var p localPolicy
	if user != "" {
		b, e := os.ReadFile(a.policyPath(user))
		if e == nil {
			if e = json.Unmarshal(b, &p); e != nil {
				return e
			}
		} else if !errors.Is(e, os.ErrNotExist) {
			return e
		}
	}
	if p.Pins == nil {
		p.Pins = map[string]devicekeys.Public{}
	}
	a.policy = p
	return nil
}
func (a *Agent) getSession(ctx context.Context) (identity.Session, error) {
	a.authMu.Lock()
	defer a.authMu.Unlock()
	a.mu.Lock()
	s := a.creds.Session
	a.mu.Unlock()
	if s.User == "" {
		return s, errNotSignedIn
	}
	if time.Until(s.ExpiresAt) > 30*time.Second {
		return s, nil
	}
	return a.renew(ctx, s)
}
func (a *Agent) startLogin(handle, invite string) (any, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.creds.Session.User != "" {
		return nil, errors.New("already signed in")
	}
	if a.loginPending {
		return map[string]bool{"pending": true}, nil
	}
	ctx, cancel := context.WithCancel(a.ctx)
	a.loginPending = true
	a.loginStop = cancel
	a.problem = ""
	go func() {
		ic := a.identity
		ic.Invite = invite
		s, e := ic.Login(ctx, a.keys, a.cfg.OpenBrowser)
		a.authMu.Lock()
		a.mu.Lock()
		if e == nil && ctx.Err() == nil {
			next := a.creds
			next.Session = s
			if e = a.loadPolicy(s.User); e == nil {
				e = a.persistCredentials(next)
			}
			if e == nil {
				a.creds = next
				a.refresh = refreshState{}
			}
		}
		a.mu.Unlock()
		a.authMu.Unlock()
		if e == nil && ctx.Err() == nil {
			a.logger().Info("state", "state", "signedIn", "device", netlog.DevicePrefix(s.Device))
		} else if e != nil {
			a.logger().Warn("login", "outcome", "error", "err", errText(e))
		}
		if e == nil && ctx.Err() == nil && handle != "" {
			e = a.remote(ctx, s, "PUT", "/v1/profile", map[string]string{"handle": handle}, nil)
		}
		a.mu.Lock()
		a.loginPending = false
		a.loginStop = nil
		if e != nil {
			a.problem = errText(e)
		}
		var refused identity.NotAdmittedError
		switch {
		case e == nil:
			a.access = ""
		case errors.As(e, &refused) && refused.Requestable && a.access != "pending":
			a.access = "requestable"
		}
		a.mu.Unlock()
		cancel()
	}()
	return map[string]bool{"pending": true}, nil
}
func (a *Agent) signout(ctx context.Context) error {
	a.authMu.Lock()
	defer a.authMu.Unlock()
	a.mu.Lock()
	if a.loginStop != nil {
		a.loginStop()
	}
	if a.sessionStop != nil {
		a.sessionStop()
	}
	s := a.creds.Session
	l := a.lease
	a.mu.Unlock()
	var remoteErr error
	if s.User != "" {
		attempt, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		if time.Until(s.ExpiresAt) < time.Second {
			s, remoteErr = a.identity.Refresh(attempt, s.RefreshToken)
		}
		if remoteErr == nil {
			if l.Session != "" {
				// Older edges expect this request. Leave time for credential sign-out.
				closeAttempt, closeCancel := context.WithTimeout(attempt, time.Second)
				_ = a.remote(closeAttempt, s, "DELETE", "/v1/session", proof(l), nil)
				closeCancel()
			}
			remoteErr = a.identity.SignOut(attempt, s.AccessToken)
		}
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	next := a.creds
	next.Session = identity.Session{}
	if e := a.persistCredentials(next); e != nil {
		return e
	}
	a.creds = next
	a.lease = control.Lease{}
	a.refresh = refreshState{}
	a.problem = ""
	a.logger().Info("state", "state", "signedOut", "reason", "signout")
	if remoteErr != nil {
		a.problem = "Signed out on this device. The relay could not confirm remote sign-out."
	}
	return a.loadPolicy("")
}

type statusError struct {
	code    int
	message string
	// A refused claim names the live claim that blocks it.
	holder, claim string
}

// refusalFields are the structured parts of a refused claim for the tray envelope.
func (e statusError) refusalFields() map[string]any {
	if e.code != http.StatusConflict || e.claim == "" {
		return nil
	}
	handle, agent, _ := strings.Cut(e.holder, "/")
	return map[string]any{"holder": handle, "agent": agent, "claim": e.claim}
}

func (e statusError) Error() string { return fmt.Sprintf("relay HTTP %d: %s", e.code, e.message) }
func (a *Agent) remote(ctx context.Context, s identity.Session, method, path string, in, out any) error {
	var body []byte
	var e error
	if in != nil {
		body, e = json.Marshal(in)
		if e != nil {
			return e
		}
	}
	req, e := http.NewRequestWithContext(ctx, method, a.cfg.Relay+path, bytes.NewReader(body))
	if e != nil {
		return e
	}
	if s.AccessToken != "" {
		req.Header.Set("Authorization", "Bearer "+s.AccessToken)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, e := a.http.Do(req)
	if e != nil {
		return e
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		var msg struct{ Error, Holder, Claim string }
		_ = json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&msg)
		if resp.StatusCode == http.StatusConflict && msg.Holder != "" {
			held := "held by " + msg.Holder
			if !strings.Contains(msg.Error, held) {
				msg.Error = strings.TrimSpace(msg.Error + " " + held)
			}
		}
		return statusError{code: resp.StatusCode, message: msg.Error, holder: msg.Holder, claim: msg.Claim}
	}
	if out == nil {
		_, e = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
		return e
	}
	data, e := io.ReadAll(io.LimitReader(resp.Body, 32<<20+1))
	if e != nil {
		return e
	}
	if len(data) > 32<<20 {
		return errors.New("relay response too large")
	}
	return json.Unmarshal(data, out)
}
func (a *Agent) pin(ctx context.Context, s identity.Session, user, device string) (devicekeys.Public, error) {
	p, e := a.identity.Lookup(ctx, s.AccessToken, device)
	if e != nil {
		return p, e
	}
	if p.User != user {
		return p, errors.New("device owner mismatch")
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.creds.Session.User != s.User {
		return p, errors.New("local identity changed")
	}
	if old, ok := a.policy.Pins[device]; ok {
		return p, devicekeys.VerifyPin(old, p)
	}
	a.policy.Pins[device] = p
	if e = save(a.policyPath(s.User), a.policy); e != nil {
		delete(a.policy.Pins, device)
	}
	return p, e
}
func (a *Agent) resources(ctx context.Context, s identity.Session) ([]control.Resource, error) {
	var data struct{ Resources []control.Resource }
	e := a.remote(ctx, s, "GET", "/v1/resources", nil, &data)
	return data.Resources, e
}
func (a *Agent) localConfig(s identity.Session) actions.Config {
	a.mu.Lock()
	defer a.mu.Unlock()
	cfg := actions.Config{StateDir: filepath.Join(a.cfg.Dir, key(s.User)), CommanderSocket: a.cfg.CommanderSocket, Resources: slices.Clone(a.policy.Resources), Grants: slices.Clone(a.policy.Grants), GitHubToken: func(ctx context.Context, id, capability string) (string, error) {
		a.mu.Lock()
		defer a.mu.Unlock()
		t := a.creds.Tokens[key(s.User+"|"+id)]
		if t == "" || a.creds.Session.User != s.User {
			return "", actions.ErrUnavailable
		}
		return t, nil
	}}
	cfg.ReceivedRequest = func(peer, resource, request string) bool {
		return a.receivedRequest(s.User, peer, resource, request)
	}
	if a.cfg.configureActions != nil {
		return a.cfg.configureActions(cfg)
	}
	return cfg
}

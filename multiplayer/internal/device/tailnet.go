package device

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"
)

// The tailnet adapter drives the local tailscale CLI. It never talks to the
// control server directly. See design/COMMANDER-NETWORK-TAILNET.md.

const (
	tailnetStatusTimeout = 5 * time.Second
	// tailnetKeyLoginTimeout stays below the tray server's 40 s write timeout.
	tailnetKeyLoginTimeout     = 30 * time.Second
	tailnetBrowserLoginTimeout = 10 * time.Minute
	tailnetAuthURLWait         = 15 * time.Second
	defaultRelayTag            = "tag:relay"
)

var (
	errTailscaleMissing = errors.New("the Tailscale CLI is not installed")
	dnsLabel            = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$`)
	tailnetPollInterval = 250 * time.Millisecond
)

// tailnetState tracks the one pending browser login.
type tailnetState struct {
	mu      sync.Mutex
	pending bool
}

// TailnetNode is one node on the tailnet.
type TailnetNode struct {
	HostName  string   `json:"hostName"`
	DNSName   string   `json:"dnsName"`
	Addresses []string `json:"addresses"`
	Online    bool     `json:"online"`
	Tags      []string `json:"tags"`
}

// TailnetStatus is the tray view of `tailscale status --json`.
type TailnetStatus struct {
	Installed      bool         `json:"installed"`
	BackendState   string       `json:"backendState"`
	Running        bool         `json:"running"`
	Tailnet        string       `json:"tailnet"`
	MagicDNSSuffix string       `json:"magicDNSSuffix"`
	Self           *TailnetNode `json:"self"`
	AuthURL        string       `json:"authURL"`
	LoginPending   bool         `json:"loginPending"`
}

// TailnetRelay is a tagged peer that can be added as a server.
type TailnetRelay struct {
	Name      string   `json:"name"`
	DNSName   string   `json:"dnsName"`
	Addresses []string `json:"addresses"`
	Online    bool     `json:"online"`
	OS        string   `json:"os"`
	URL       string   `json:"url"`
	Added     bool     `json:"added"`
}

type tsPeer struct {
	HostName     string
	DNSName      string
	OS           string
	TailscaleIPs []string
	Online       bool
	Tags         []string
}

type tsStatus struct {
	BackendState   string
	AuthURL        string
	MagicDNSSuffix string
	Self           *tsPeer
	CurrentTailnet *struct {
		Name           string
		MagicDNSSuffix string
	}
	Peer map[string]tsPeer
}

type tailnetInput struct {
	LoginServer string `json:"loginServer"`
	AuthKey     string `json:"authKey"`
	Hostname    string `json:"hostname"`
	Tag         string `json:"tag"`
}

func (m *Manager) tailnetVerb(ctx context.Context, verb string, in tailnetInput) (any, error) {
	switch verb {
	case "tailnet-status":
		return m.TailnetStatus(ctx)
	case "tailnet-join":
		return m.TailnetJoin(ctx, in.LoginServer, in.AuthKey, in.Hostname)
	case "tailnet-relays":
		relays, e := m.TailnetRelays(ctx, in.Tag)
		if e != nil {
			return nil, e
		}
		return map[string]any{"relays": relays}, nil
	}
	return nil, errors.New("unknown tailnet operation")
}

// tailscaleCLI finds the tailscale binary: the configured path, PATH,
// Homebrew, then the one inside Tailscale.app.
func (m *Manager) tailscaleCLI() (string, error) {
	if m.cfg.Tailscale != "" {
		if isExecutable(m.cfg.Tailscale) {
			return m.cfg.Tailscale, nil
		}
		return "", errTailscaleMissing
	}
	if p, e := exec.LookPath("tailscale"); e == nil {
		return p, nil
	}
	for _, p := range []string{"/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"} {
		if isExecutable(p) {
			return p, nil
		}
	}
	return "", errTailscaleMissing
}

func isExecutable(p string) bool {
	st, e := os.Stat(p)
	return e == nil && !st.IsDir() && st.Mode()&0111 != 0
}

// runTailscale runs the CLI and returns stdout. A failure carries stderr.
func (m *Manager) runTailscale(ctx context.Context, timeout time.Duration, args ...string) ([]byte, error) {
	cli, e := m.tailscaleCLI()
	if e != nil {
		return nil, e
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var stdout, stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, cli, args...)
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if e = cmd.Run(); e != nil {
		return stdout.Bytes(), tailscaleError(args[0], e, stderr.String())
	}
	return stdout.Bytes(), nil
}

func tailscaleError(sub string, e error, stderr string) error {
	if msg := strings.TrimSpace(stderr); msg != "" {
		return fmt.Errorf("tailscale %s: %s", sub, msg)
	}
	return fmt.Errorf("tailscale %s: %w", sub, e)
}

// rawTailnetStatus parses `tailscale status --json`. The CLI can exit
// non-zero while stopped or logged out and still print valid JSON.
func (m *Manager) rawTailnetStatus(ctx context.Context) (*tsStatus, error) {
	out, e := m.runTailscale(ctx, tailnetStatusTimeout, "status", "--json")
	if errors.Is(e, errTailscaleMissing) {
		return nil, e
	}
	var st tsStatus
	if perr := json.Unmarshal(out, &st); perr != nil {
		if e != nil {
			return nil, e
		}
		return nil, fmt.Errorf("tailscale status: unreadable output: %w", perr)
	}
	return &st, nil
}

func trimDot(s string) string { return strings.TrimSuffix(s, ".") }

// TailnetStatus reports whether this Mac is on a tailnet.
func (m *Manager) TailnetStatus(ctx context.Context) (TailnetStatus, error) {
	m.tailnet.mu.Lock()
	pending := m.tailnet.pending
	m.tailnet.mu.Unlock()
	st, e := m.rawTailnetStatus(ctx)
	if errors.Is(e, errTailscaleMissing) {
		return TailnetStatus{}, nil
	}
	if e != nil {
		return TailnetStatus{}, e
	}
	out := TailnetStatus{
		Installed: true, BackendState: st.BackendState, Running: st.BackendState == "Running",
		MagicDNSSuffix: st.MagicDNSSuffix, AuthURL: st.AuthURL, LoginPending: pending,
	}
	if st.CurrentTailnet != nil {
		out.Tailnet = st.CurrentTailnet.Name
		if out.MagicDNSSuffix == "" {
			out.MagicDNSSuffix = st.CurrentTailnet.MagicDNSSuffix
		}
	}
	if st.Self != nil {
		out.Self = &TailnetNode{
			HostName: st.Self.HostName, DNSName: trimDot(st.Self.DNSName), Addresses: nonNil(st.Self.TailscaleIPs),
			Online: st.Self.Online, Tags: nonNil(st.Self.Tags),
		}
	}
	return out, nil
}

func validLoginServer(raw string) (string, error) {
	u, e := url.Parse(strings.TrimSpace(raw))
	bad := errors.New("the login server must be an https:// URL")
	if e != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Opaque != "" {
		return "", bad
	}
	switch u.Scheme {
	case "https":
	case "http":
		if !isLoopback(u.Hostname()) {
			return "", bad
		}
	default:
		return "", bad
	}
	return u.String(), nil
}

func isLoopback(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// TailnetJoin logs this Mac into a tailnet. With an auth key it waits for the
// login and returns the new status. Without one it opens the login URL in the
// system browser and returns it while the login continues in the background.
func (m *Manager) TailnetJoin(ctx context.Context, loginServer, authKey, hostname string) (any, error) {
	server, e := validLoginServer(loginServer)
	if e != nil {
		return nil, e
	}
	hostname = strings.TrimSpace(hostname)
	if hostname != "" && !dnsLabel.MatchString(hostname) {
		return nil, errors.New("the hostname must be one DNS label: letters, digits and hyphens")
	}
	authKey = strings.TrimSpace(authKey)
	if strings.ContainsAny(authKey, "\r\n") {
		return nil, errors.New("invalid auth key")
	}
	m.tailnet.mu.Lock()
	if m.tailnet.pending {
		m.tailnet.mu.Unlock()
		return nil, errors.New("a tailnet login is already in progress")
	}
	m.tailnet.pending = true
	m.tailnet.mu.Unlock()
	keep := false
	defer func() {
		if !keep {
			m.endTailnetLogin()
		}
	}()

	st, e := m.rawTailnetStatus(ctx)
	if e != nil {
		return nil, e
	}
	if st.BackendState == "Running" {
		name := "a tailnet"
		if st.CurrentTailnet != nil && st.CurrentTailnet.Name != "" {
			name = "tailnet " + st.CurrentTailnet.Name
		}
		return nil, fmt.Errorf("this Mac is already on %s; leave it in Tailscale first", name)
	}
	args := []string{"login", "--login-server", server}
	if hostname != "" {
		args = append(args, "--hostname", hostname)
	}

	if authKey != "" {
		f, e := os.CreateTemp(m.cfg.Dir, ".tailnet-key-*")
		if e != nil {
			return nil, e
		}
		path := f.Name()
		defer os.Remove(path)
		_, we := f.WriteString(authKey)
		ce := f.Close()
		if e = errors.Join(os.Chmod(path, 0600), we, ce); e != nil {
			return nil, errors.New("could not store the auth key for the Tailscale CLI")
		}
		if _, e = m.runTailscale(ctx, tailnetKeyLoginTimeout, append(args, "--auth-key", "file:"+path)...); e != nil {
			return nil, e
		}
		return m.TailnetStatus(ctx)
	}

	cli, e := m.tailscaleCLI()
	if e != nil {
		return nil, e
	}
	lctx, cancel := context.WithTimeout(m.ctx, tailnetBrowserLoginTimeout)
	var stderr bytes.Buffer
	cmd := exec.CommandContext(lctx, cli, args...)
	cmd.Stderr = &stderr
	if e = cmd.Start(); e != nil {
		cancel()
		return nil, tailscaleError("login", e, "")
	}
	keep = true
	done := make(chan error, 1)
	go func() {
		err := cmd.Wait()
		cancel()
		m.endTailnetLogin()
		done <- err
	}()

	deadline := time.NewTimer(tailnetAuthURLWait)
	defer deadline.Stop()
	tick := time.NewTicker(tailnetPollInterval)
	defer tick.Stop()
	for {
		if st, e := m.rawTailnetStatus(ctx); e == nil {
			if st.AuthURL != "" {
				if e = m.cfg.OpenBrowser(st.AuthURL); e != nil {
					return nil, fmt.Errorf("open the login page: %w", e)
				}
				return map[string]any{"state": "needsLogin", "authURL": st.AuthURL}, nil
			}
			if st.BackendState == "Running" {
				return m.TailnetStatus(ctx)
			}
		}
		select {
		case err := <-done:
			if err != nil {
				return nil, tailscaleError("login", err, stderr.String())
			}
			return m.TailnetStatus(ctx)
		case <-deadline.C:
			cancel()
			return nil, errors.New("Tailscale did not offer a login page in time")
		case <-ctx.Done():
			cancel()
			return nil, ctx.Err()
		case <-tick.C:
		}
	}
}

func (m *Manager) endTailnetLogin() {
	m.tailnet.mu.Lock()
	m.tailnet.pending = false
	m.tailnet.mu.Unlock()
}

// TailnetRelays lists peers that carry the relay tag.
func (m *Manager) TailnetRelays(ctx context.Context, tag string) ([]TailnetRelay, error) {
	tag = strings.TrimSpace(tag)
	if tag == "" {
		tag = defaultRelayTag
	}
	if !strings.HasPrefix(tag, "tag:") || len(tag) == len("tag:") {
		return nil, errors.New(`a relay tag starts with "tag:"`)
	}
	st, e := m.rawTailnetStatus(ctx)
	if e != nil {
		return nil, e
	}
	if st.BackendState != "Running" {
		return nil, errors.New("this Mac is not on a tailnet")
	}
	m.mu.Lock()
	saved := map[string]bool{}
	for _, s := range m.servers {
		saved[s.URL] = true
	}
	m.mu.Unlock()
	out := []TailnetRelay{}
	for _, p := range st.Peer {
		dns := trimDot(p.DNSName)
		if dns == "" || !slices.Contains(p.Tags, tag) {
			continue
		}
		u, e := NormalizeRelay("https://" + dns)
		if e != nil {
			continue
		}
		out = append(out, TailnetRelay{
			Name: p.HostName, DNSName: dns, Addresses: nonNil(p.TailscaleIPs), Online: p.Online,
			OS: p.OS, URL: u, Added: saved[u],
		})
	}
	slices.SortFunc(out, func(a, b TailnetRelay) int {
		if c := strings.Compare(a.Name, b.Name); c != 0 {
			return c
		}
		return strings.Compare(a.DNSName, b.DNSName)
	})
	return out, nil
}

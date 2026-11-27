package device

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"agentcommander.network/pilot/internal/devicekeys"
)

// ErrPinMismatch reports a relay key that differs from the pinned one.
var ErrPinMismatch = errors.New("relay certificate key changed; confirm the new key before reconnecting")

// SPKIPin returns "sha256/<base64>" of a certificate's SubjectPublicKeyInfo.
func SPKIPin(c *x509.Certificate) string {
	sum := sha256.Sum256(c.RawSubjectPublicKeyInfo)
	return "sha256/" + base64.StdEncoding.EncodeToString(sum[:])
}

func googleConfig(c Config) string {
	if c.GoogleDesktopConfig != "" {
		return c.GoogleDesktopConfig
	}
	return filepath.Join(c.Dir, "google-desktop-client.json")
}

// Server is one saved relay.
type Server struct {
	ID          string    `json:"id"`
	URL         string    `json:"url"`
	Name        string    `json:"name"`
	Favorite    bool      `json:"favorite"`
	AutoConnect bool      `json:"autoConnect"`
	Pin         string    `json:"pin"`
	AddedAt     time.Time `json:"addedAt"`
	LastUsedAt  time.Time `json:"lastUsedAt"`
}

// ServerSummary is a Server with its live connection state.
type ServerSummary struct {
	Server
	State         string    `json:"state"`
	SignedIn      bool      `json:"signedIn"`
	Handle        string    `json:"handle"`
	LastSeen      time.Time `json:"lastSeen,omitzero"`
	Error         string    `json:"error"`
	FriendsOnline int       `json:"friendsOnline"`
	Incoming      int       `json:"incoming"`
	Presence      string    `json:"presence"`
	Unseen        int       `json:"unseen"`
}

// ManagerConfig configures the multi-server device agent.
type ManagerConfig struct {
	Dir, CommanderSocket string
	Secrets              func(relay string) (devicekeys.Store, error)
	Roots                *x509.CertPool
	OIDCHTTP             *http.Client
	OpenBrowser          func(string) error
	// SeedRelay is added as the first server when no server list exists.
	SeedRelay string
	// NoPresence disables automatic presence (tests).
	NoPresence bool
	// Dial is replaced in tests.
	Dial func(ctx context.Context, network, address string) (net.Conn, error)
	// Tailscale overrides the tailscale CLI path.
	Tailscale string
	// DNSSD overrides the dns-sd path used to browse for relays.
	DNSSD string
	// Discover refreshes relay discovery in the background every DiscoverEvery
	// (default one minute). BonjourWindow is how long each pass browses.
	Discover      bool
	DiscoverEvery time.Duration
	BonjourWindow time.Duration
	// DirectoryURL is the public relay directory discovery reads; empty
	// leaves it out.
	DirectoryURL string
}

// Manager runs one Agent per enabled server and serves the tray.
type Manager struct {
	cfg         ManagerConfig
	ctx         context.Context
	mu          sync.Mutex
	edit        sync.Mutex
	servers     []Server
	agents      map[string]*Agent
	problems    map[string]string
	certChanged map[string]bool
	rs          *remoteServer
	tailnet     tailnetState
	disc        discoveryState
}

func (m *Manager) listPath() string { return filepath.Join(m.cfg.Dir, "servers.json") }

// NewManager loads the server list and connects every auto-connect server.
func NewManager(ctx context.Context, c ManagerConfig) (*Manager, error) {
	if c.Secrets == nil || c.OpenBrowser == nil {
		return nil, errors.New("credential store and system browser required")
	}
	if e := privateDir(c.Dir); e != nil {
		return nil, e
	}
	if c.Dial == nil {
		c.Dial = (&net.Dialer{Timeout: 5 * time.Second}).DialContext
	}
	m := &Manager{cfg: c, ctx: ctx, agents: map[string]*Agent{}, problems: map[string]string{}, certChanged: map[string]bool{}}
	b, e := os.ReadFile(m.listPath())
	switch {
	case e == nil:
		var file struct{ Servers []Server }
		if e = json.Unmarshal(b, &file); e != nil {
			return nil, fmt.Errorf("read server list: %w", e)
		}
		m.servers = file.Servers
	case errors.Is(e, os.ErrNotExist):
		if c.SeedRelay != "" {
			u, e := NormalizeRelay(c.SeedRelay)
			if e != nil {
				return nil, e
			}
			now := time.Now().UTC()
			m.servers = []Server{{ID: newServerID(), URL: u, Name: hostOf(u), AutoConnect: true, AddedAt: now, LastUsedAt: now}}
			if e = m.persist(); e != nil {
				return nil, e
			}
		}
	default:
		return nil, e
	}
	for _, s := range m.servers {
		m.start(s)
	}
	if !c.NoPresence {
		go m.presenceLoop()
	}
	if c.Discover {
		go m.discoveryLoop()
	}
	return m, nil
}

// Close stops every connection.
func (m *Manager) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for id, a := range m.agents {
		a.Close()
		delete(m.agents, id)
	}
}

func (m *Manager) persist() error {
	return save(m.listPath(), map[string]any{"servers": m.servers})
}

func newServerID() string { return "s-" + newID()[:8] }

func hostOf(u string) string {
	p, e := url.Parse(u)
	if e != nil {
		return u
	}
	h := p.Hostname()
	if net.ParseIP(h) != nil {
		return h
	}
	first, _, _ := strings.Cut(h, ".")
	return first
}

// NormalizeRelay turns "host", "host:port" or an https URL into an https origin.
func NormalizeRelay(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", errors.New("enter a server host or URL")
	}
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	u, e := url.Parse(raw)
	if e != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || strings.Trim(u.Path, "/") != "" {
		return "", errors.New("expected a host, host:port or https:// origin")
	}
	host := u.Host
	if u.Port() == "443" {
		host = u.Hostname()
		if strings.Contains(host, ":") {
			host = "[" + host + "]"
		}
	}
	return "https://" + strings.ToLower(host), nil
}

func (m *Manager) start(s Server) {
	if s.ID == m.servers[0].ID {
		if err := migrateQueue(m.cfg.Dir, s.ID); err != nil {
			m.problems[s.ID] = err.Error()
			return
		}
	}
	if !s.AutoConnect {
		return
	}
	dir := filepath.Join(m.cfg.Dir, "servers", s.ID)
	if e := os.MkdirAll(filepath.Dir(dir), 0700); e != nil {
		m.problems[s.ID] = e.Error()
		return
	}
	secrets, e := m.cfg.Secrets(s.URL)
	if e != nil {
		m.problems[s.ID] = e.Error()
		return
	}
	id := s.ID
	a, e := New(m.ctx, Config{
		ServerID: s.ID, Relay: s.URL, Dir: dir, CommanderSocket: m.cfg.CommanderSocket, Secrets: secrets, Roots: m.cfg.Roots,
		OIDCHTTP: m.cfg.OIDCHTTP, OpenBrowser: m.cfg.OpenBrowser, Pin: s.Pin,
		GoogleDesktopConfig: filepath.Join(m.cfg.Dir, "google-desktop-client.json"),
		OnPinMismatch: func() {
			go func() {
				m.mu.Lock()
				defer m.mu.Unlock()
				m.certChanged[id] = true
				if a := m.agents[id]; a != nil {
					a.Close()
					delete(m.agents, id)
				}
			}()
		},
	})
	if e != nil {
		m.problems[s.ID] = e.Error()
		return
	}
	delete(m.problems, s.ID)
	m.agents[s.ID] = a
}

func (m *Manager) stop(id string) {
	if a := m.agents[id]; a != nil {
		a.Close()
		delete(m.agents, id)
	}
}

func (m *Manager) find(id string) int {
	return slices.IndexFunc(m.servers, func(s Server) bool { return s.ID == id })
}

func (m *Manager) summary(s Server) ServerSummary {
	out := ServerSummary{Server: s, State: "offline", Error: m.problems[s.ID]}
	if m.certChanged[s.ID] {
		out.State = "certChanged"
		out.Error = ErrPinMismatch.Error()
		return out
	}
	a := m.agents[s.ID]
	if a == nil {
		if out.Error != "" {
			out.State = "error"
		}
		return out
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	out.SignedIn = a.creds.Session.User != ""
	out.Handle, out.FriendsOnline, out.Incoming = a.handle, a.friendsOn, a.incoming
	out.Presence, out.Unseen = a.social.Pushed, a.unseen()
	if a.social.PresenceMode != "auto" {
		out.Presence = a.social.PresenceMode
	}
	if a.problem != "" {
		out.Error = a.problem
	}
	online := out.SignedIn && time.Now().Before(a.lease.ExpiresAt)
	if online {
		a.lastOnline = time.Now().UTC()
	}
	out.LastSeen = a.lastOnline
	switch {
	case a.loginPending:
		out.State = "connecting"
	case !out.SignedIn:
		out.State = "signedOut"
	case online:
		out.State = "online"
	case a.lastOnline.IsZero():
		out.State = "connecting"
	default:
		out.State = "offline"
	}
	return out
}

// Summaries lists servers: favorites first, then most recently used.
func (m *Manager) Summaries() []ServerSummary {
	m.mu.Lock()
	defer m.mu.Unlock()
	list := slices.Clone(m.servers)
	slices.SortStableFunc(list, func(a, b Server) int {
		if a.Favorite != b.Favorite {
			if a.Favorite {
				return -1
			}
			return 1
		}
		return b.LastUsedAt.Compare(a.LastUsedAt)
	})
	out := make([]ServerSummary, 0, len(list))
	for _, s := range list {
		out = append(out, m.summary(s))
	}
	return out
}

// ProbeStep is one stage of a server health check.
type ProbeStep struct {
	Step             string `json:"step"`
	OK               bool   `json:"ok"`
	Detail           string `json:"detail"`
	Pin              string `json:"pin,omitempty"`
	Fingerprint      string `json:"fingerprint,omitempty"`
	SystemTrusted    bool   `json:"systemTrusted"`
	ClientID         string `json:"clientId,omitempty"`
	ClientConfigured bool   `json:"clientConfigured,omitempty"`
}

// Probe is the result of checking a server before adding it.
type Probe struct {
	URL   string      `json:"url"`
	Steps []ProbeStep `json:"steps"`
	// Existing is the id of a saved server with the same URL.
	Existing string `json:"existing,omitempty"`
}

// RelayInfo is the unauthenticated relay description at /v1/info.
type RelayInfo struct {
	Version      string `json:"version"`
	Mode         string `json:"mode"`
	Issuer       string `json:"issuer"`
	ClientID     string `json:"clientId"`
	Name         string `json:"name"`
	Membership   string `json:"membership"`
	AdminContact string `json:"adminContact"`
}

func fingerprint(c *x509.Certificate) string {
	sum := sha256.Sum256(c.Raw)
	h := strings.ToUpper(hex.EncodeToString(sum[:]))
	parts := make([]string, 0, len(h)/2)
	for i := 0; i < len(h); i += 2 {
		parts = append(parts, h[i:i+2])
	}
	return strings.Join(parts, ":")
}

// ProbeServer runs the staged health check: DNS, TCP, TLS, relay info and sign-in provider.
func (m *Manager) ProbeServer(ctx context.Context, raw string) (Probe, error) {
	u, e := NormalizeRelay(raw)
	if e != nil {
		return Probe{}, e
	}
	p := Probe{URL: u}
	m.mu.Lock()
	if i := slices.IndexFunc(m.servers, func(s Server) bool { return s.URL == u }); i >= 0 {
		p.Existing = m.servers[i].ID
	}
	m.mu.Unlock()
	parsed, _ := url.Parse(u)
	host, port := parsed.Hostname(), parsed.Port()
	if port == "" {
		port = "443"
	}
	add := func(s ProbeStep) bool { p.Steps = append(p.Steps, s); return s.OK }

	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	addrs, e := net.DefaultResolver.LookupHost(ctx, host)
	if e != nil || len(addrs) == 0 {
		add(ProbeStep{Step: "dns", Detail: fmt.Sprintf("%s does not resolve: %v", host, e)})
		return p, nil
	}
	add(ProbeStep{Step: "dns", OK: true, Detail: strings.Join(addrs, ", ")})

	started := time.Now()
	conn, e := m.cfg.Dial(ctx, "tcp", net.JoinHostPort(host, port))
	if e != nil {
		add(ProbeStep{Step: "tcp", Detail: fmt.Sprintf("cannot connect to %s: %v", net.JoinHostPort(host, port), e)})
		return p, nil
	}
	add(ProbeStep{Step: "tcp", OK: true, Detail: fmt.Sprintf("%s in %d ms", conn.RemoteAddr(), time.Since(started).Milliseconds())})

	tc := tls.Client(conn, &tls.Config{ServerName: host, InsecureSkipVerify: true, MinVersion: tls.VersionTLS12})
	if e = tc.HandshakeContext(ctx); e != nil {
		conn.Close()
		add(ProbeStep{Step: "tls", Detail: "TLS handshake failed: " + e.Error()})
		return p, nil
	}
	certs := tc.ConnectionState().PeerCertificates
	tc.Close()
	leaf := certs[0]
	inter := x509.NewCertPool()
	for _, c := range certs[1:] {
		inter.AddCert(c)
	}
	_, verr := leaf.Verify(x509.VerifyOptions{DNSName: host, Intermediates: inter, Roots: m.cfg.Roots})
	tlsStep := ProbeStep{Step: "tls", OK: true, Pin: SPKIPin(leaf), Fingerprint: fingerprint(leaf), SystemTrusted: verr == nil}
	pin := tlsStep.Pin
	if verr == nil {
		tlsStep.Detail = "trusted by the system"
		pin = ""
	} else {
		tlsStep.Detail = "not trusted by the system; confirm the fingerprint to pin it"
	}
	add(tlsStep)

	client := &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{DialContext: m.cfg.Dial, TLSClientConfig: &tls.Config{
		MinVersion: tls.VersionTLS12, RootCAs: m.cfg.Roots, InsecureSkipVerify: pin != "",
		VerifyConnection: func(cs tls.ConnectionState) error {
			if pin != "" && (len(cs.PeerCertificates) == 0 || SPKIPin(cs.PeerCertificates[0]) != pin) {
				return ErrPinMismatch
			}
			return nil
		}}}}
	defer client.CloseIdleConnections()
	var info RelayInfo
	req, _ := http.NewRequestWithContext(ctx, "GET", u+"/v1/info", nil)
	resp, e := client.Do(req)
	if e == nil {
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			e = fmt.Errorf("HTTP %d", resp.StatusCode)
		} else {
			e = json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&info)
		}
	}
	if e != nil {
		add(ProbeStep{Step: "relay", Detail: "not a Commander relay or too old: " + e.Error()})
		return p, nil
	}
	add(ProbeStep{Step: "relay", OK: true, Detail: strings.TrimSpace("commander-relay " + info.Mode + " " + info.Version)})

	signin := ProbeStep{Step: "signin", Detail: info.Issuer, ClientID: info.ClientID}
	switch {
	case info.Issuer == "" || info.ClientID == "":
		signin.Detail = "the relay does not name a sign-in provider"
	case strings.TrimRight(info.Issuer, "/") == "https://accounts.google.com":
		var gc struct {
			Installed struct {
				ClientID string `json:"client_id"`
			}
		}
		b, e := os.ReadFile(filepath.Join(m.cfg.Dir, "google-desktop-client.json"))
		if e == nil && json.Unmarshal(b, &gc) == nil && gc.Installed.ClientID == info.ClientID {
			signin.OK, signin.ClientConfigured = true, true
		} else {
			signin.Detail = "Google Desktop OAuth JSON for this relay's client ID is missing from " + filepath.Join(m.cfg.Dir, "google-desktop-client.json")
		}
	default:
		signin.OK, signin.ClientConfigured = true, true
	}
	add(signin)
	return p, nil
}

type serverInput struct {
	Server      string `json:"server"`
	URL         string `json:"url"`
	Name        string `json:"name"`
	Pin         string `json:"pin"`
	Favorite    *bool  `json:"favorite"`
	AutoConnect *bool  `json:"autoConnect"`
}

func (m *Manager) serverVerb(ctx context.Context, verb string, in serverInput) (any, error) {
	if verb == "servers" {
		return map[string]any{"servers": m.Summaries()}, nil
	}
	if verb == "server-probe" {
		return m.ProbeServer(ctx, in.URL)
	}
	m.edit.Lock()
	defer m.edit.Unlock()
	m.mu.Lock()
	defer m.mu.Unlock()
	if verb == "server-add" {
		u, e := NormalizeRelay(in.URL)
		if e != nil {
			return nil, e
		}
		if slices.ContainsFunc(m.servers, func(s Server) bool { return s.URL == u }) {
			return nil, errors.New("that server is already in your list")
		}
		if in.Pin != "" && !strings.HasPrefix(in.Pin, "sha256/") {
			return nil, errors.New("invalid certificate pin")
		}
		name := strings.TrimSpace(in.Name)
		if name == "" {
			name = hostOf(u)
		}
		now := time.Now().UTC()
		s := Server{ID: newServerID(), URL: u, Name: name, AutoConnect: true, Pin: in.Pin, AddedAt: now, LastUsedAt: now}
		m.servers = append(m.servers, s)
		if e = m.persist(); e != nil {
			m.servers = m.servers[:len(m.servers)-1]
			return nil, e
		}
		m.start(s)
		return m.summary(s), nil
	}
	i := m.find(in.Server)
	if i < 0 {
		return nil, errors.New("unknown server")
	}
	s := m.servers[i]
	switch verb {
	case "server-update":
		if in.Name != "" {
			s.Name = strings.TrimSpace(in.Name)
		}
		if in.Favorite != nil {
			s.Favorite = *in.Favorite
		}
		restart := false
		if in.AutoConnect != nil && *in.AutoConnect != s.AutoConnect {
			s.AutoConnect, restart = *in.AutoConnect, true
		}
		m.servers[i] = s
		if e := m.persist(); e != nil {
			return nil, e
		}
		if restart {
			m.stop(s.ID)
			if s.AutoConnect {
				m.start(s)
			}
		}
		return m.summary(s), nil
	case "server-trust":
		if !strings.HasPrefix(in.Pin, "sha256/") {
			return nil, errors.New("invalid certificate pin")
		}
		s.Pin = in.Pin
		m.servers[i] = s
		if e := m.persist(); e != nil {
			return nil, e
		}
		delete(m.certChanged, s.ID)
		m.stop(s.ID)
		if s.AutoConnect {
			m.start(s)
		}
		return m.summary(s), nil
	case "server-remove":
		if a := m.agents[s.ID]; a != nil {
			m.mu.Unlock()
			_ = a.signout(ctx)
			m.mu.Lock()
		}
		m.stop(s.ID)
		if secrets, e := m.cfg.Secrets(s.URL); e == nil {
			_ = secrets.Delete()
		}
		m.servers = slices.Delete(m.servers, i, i+1)
		if e := m.persist(); e != nil {
			return nil, e
		}
		_ = os.RemoveAll(filepath.Join(m.cfg.Dir, "servers", s.ID))
		delete(m.problems, s.ID)
		delete(m.certChanged, s.ID)
		return struct{}{}, nil
	}
	return nil, fmt.Errorf("unknown server operation")
}

// agentFor picks the server a request names, or the only server.
func (m *Manager) agentFor(id string) (*Agent, error) { return m.agentUse(id, true) }

func (m *Manager) agentUse(id string, bump bool) (*Agent, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if id == "" {
		if len(m.servers) != 1 {
			return nil, errors.New("name a server")
		}
		id = m.servers[0].ID
	}
	i := m.find(id)
	if i < 0 {
		return nil, errors.New("unknown server")
	}
	if m.certChanged[id] {
		return nil, ErrPinMismatch
	}
	a := m.agents[id]
	if a == nil {
		if p := m.problems[id]; p != "" {
			return nil, errors.New(p)
		}
		return nil, errors.New("this server is not connected; turn on auto-connect")
	}
	if bump {
		m.servers[i].LastUsedAt = time.Now().UTC()
		_ = m.persist()
	}
	return a, nil
}

// coordinatorAgent picks the server for agent requests: the named one, else
// the first signed-in server in list order.
func (m *Manager) coordinatorAgent(id string) (*Agent, error) {
	if id != "" {
		return m.agentFor(id)
	}
	for _, s := range m.Summaries() {
		if s.SignedIn {
			return m.agentFor(s.ID)
		}
	}
	return nil, errors.New("sign in to a server first")
}

var readOnlyVerbs = map[string]bool{"workspace-prs": true,
	"status": true, "avatar": true, "approvals": true, "audit": true, "me": true, "membership": true,
	"groups": true, "workspaces": true, "knowledge": true, "queue": true, "threads": true,
	"admin-members": true, "workspace-combined": true, "admin-requests": true,
}

// Handler serves the tray and coordinator APIs for every server.
func (m *Manager) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /tray/{verb}", func(w http.ResponseWriter, r *http.Request) {
		raw, e := io.ReadAll(http.MaxBytesReader(w, r.Body, 196608))
		if e != nil {
			reply(w, nil, errors.New("invalid request"))
			return
		}
		verb := r.PathValue("verb")
		switch verb {
		case "remote-enable", "remote-disable", "remote-devices", "remote-revoke", "remote-rename":
			var in remoteInput
			d := json.NewDecoder(bytes.NewReader(raw))
			d.DisallowUnknownFields()
			if e = d.Decode(&in); e != nil {
				reply(w, nil, errors.New("invalid request"))
				return
			}
			res, e := m.remoteVerb(r.Context(), verb, in)
			reply(w, res, e)
			return
		case "contacts", "activity", "activity-seen", "join":
			var in struct {
				Cursor string `json:"cursor"`
				After  string `json:"after"`
				Link   string `json:"link"`
			}
			d := json.NewDecoder(bytes.NewReader(raw))
			d.DisallowUnknownFields()
			if e = d.Decode(&in); e != nil {
				reply(w, nil, errors.New("invalid request"))
				return
			}
			var res any
			switch verb {
			case "contacts":
				res, e = m.contacts(r.Context())
			case "activity":
				res = m.activity()
			case "activity-seen":
				e = m.activitySeen(in.Cursor)
			case "join":
				res, e = m.join(r.Context(), in.Link)
			}
			reply(w, res, e)
			return
		case "tailnet-status", "tailnet-join", "tailnet-relays":
			var in tailnetInput
			d := json.NewDecoder(bytes.NewReader(raw))
			d.DisallowUnknownFields()
			if e = d.Decode(&in); e != nil {
				reply(w, nil, errors.New("invalid request"))
				return
			}
			res, e := m.tailnetVerb(r.Context(), verb, in)
			reply(w, res, e)
			return
		case "relay-discover", "relay-discover-seen", "relay-join":
			var in discoveryInput
			d := json.NewDecoder(bytes.NewReader(raw))
			d.DisallowUnknownFields()
			if e = d.Decode(&in); e != nil {
				reply(w, nil, errors.New("invalid request"))
				return
			}
			res, e := m.discoveryVerb(r.Context(), verb, in)
			reply(w, res, e)
			return
		}
		if verb == "servers" || strings.HasPrefix(verb, "server-") {
			var in serverInput
			d := json.NewDecoder(bytes.NewReader(raw))
			d.DisallowUnknownFields()
			if e = d.Decode(&in); e != nil {
				reply(w, nil, errors.New("invalid request"))
				return
			}
			res, e := m.serverVerb(r.Context(), verb, in)
			reply(w, res, e)
			return
		}
		var target struct {
			Server string `json:"server"`
		}
		_ = json.Unmarshal(raw, &target)
		a, e := m.agentUse(target.Server, !readOnlyVerbs[verb])
		if e != nil {
			reply(w, nil, e)
			return
		}
		r.Body = io.NopCloser(bytes.NewReader(raw))
		a.Handler().ServeHTTP(w, r)
	})
	mux.HandleFunc("POST /coordinator/{verb}", func(w http.ResponseWriter, r *http.Request) {
		a, e := m.coordinatorAgent(r.Header.Get("X-Commander-Server"))
		if e != nil {
			reply(w, nil, e)
			return
		}
		a.Handler().ServeHTTP(w, r)
	})
	return mux
}

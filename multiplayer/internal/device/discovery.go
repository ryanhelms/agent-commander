package device

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
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
	"strconv"
	"strings"
	"sync"
	"time"

	"agentcommander.network/pilot/internal/bonjour"
)

// Relay discovery finds relays the person could join: tailnet peers tagged as
// relays and Bonjour advertisements. Every candidate is probed with
// GET /v1/info over one TLS connection, so the info always belongs to the key
// that was observed. See design/COMMANDER-NETWORK-DISCOVERY.md.

const (
	defaultDiscoverEvery = 60 * time.Second
	defaultBonjourWindow = 1500 * time.Millisecond
	discoverTimeout      = 20 * time.Second
	relayProbeTimeout    = 6 * time.Second
	maxRelayName         = 63
)

// DiscoveredRelay is one relay found on a network, merged across sources.
type DiscoveredRelay struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	URL     string   `json:"url"`
	Sources []string `json:"sources"`

	Reachable     bool   `json:"reachable"`
	Error         string `json:"error,omitempty"`
	Pin           string `json:"pin,omitempty"`
	Fingerprint   string `json:"fingerprint,omitempty"`
	SystemTrusted bool   `json:"systemTrusted"`
	// Verified is "tailnet" when tailscale whois confirmed the answering
	// address belongs to a tagged node of this tailnet.
	Verified    string `json:"verified,omitempty"`
	TailnetNode string `json:"tailnetNode,omitempty"`
	// AdvertisedPin is the pin a Bonjour TXT record or the directory claimed.
	// It is a hint only.
	AdvertisedPin        string `json:"advertisedPin,omitempty"`
	AdvertisedPinMatches bool   `json:"advertisedPinMatches,omitempty"`

	Version      string `json:"version,omitempty"`
	Mode         string `json:"mode,omitempty"`
	Membership   string `json:"membership,omitempty"`
	AdminContact string `json:"adminContact,omitempty"`
	Issuer       string `json:"issuer,omitempty"`
	ClientID     string `json:"clientId,omitempty"`

	Added    bool   `json:"added"`
	ServerID string `json:"serverId,omitempty"`
	New      bool   `json:"new"`
	// Next is the first join step left: unreachable, confirm, add, sign-in or done.
	Next     string    `json:"next"`
	LastSeen time.Time `json:"lastSeen"`

	candidates []relayCandidate
}

// DiscoverySource reports whether one discovery source could run.
type DiscoverySource struct {
	Name   string `json:"name"`
	OK     bool   `json:"ok"`
	Detail string `json:"detail,omitempty"`
}

// Discovery is the merged result of one discovery pass.
type Discovery struct {
	Relays      []DiscoveredRelay `json:"relays"`
	Sources     []DiscoverySource `json:"sources"`
	RefreshedAt time.Time         `json:"refreshedAt"`
}

type relayCandidate struct {
	source        string // "tailnet", "bonjour" or "directory"
	url           string // https origin shown to the person
	dial          string // host:port to connect to
	sni           string
	name          string
	advertisedPin string
	tailnetIP     string
	tailnetDNS    string
	offline       bool
}

type relayInspection struct {
	pin, fingerprint string
	systemTrusted    bool
	info             RelayInfo
}

type discoveryState struct {
	run  sync.Mutex // one pass at a time
	mu   sync.Mutex
	last *Discovery
	seen map[string]time.Time
}

func (m *Manager) bonjourTools() bonjour.Tools { return bonjour.Tools{DNSSD: m.cfg.DNSSD} }

func (m *Manager) discoverEvery() time.Duration {
	if m.cfg.DiscoverEvery > 0 {
		return m.cfg.DiscoverEvery
	}
	return defaultDiscoverEvery
}

func (m *Manager) discoveryPath() string { return filepath.Join(m.cfg.Dir, "discovery.json") }

func (m *Manager) loadSeen() {
	m.disc.mu.Lock()
	defer m.disc.mu.Unlock()
	if m.disc.seen != nil {
		return
	}
	m.disc.seen = map[string]time.Time{}
	if b, e := os.ReadFile(m.discoveryPath()); e == nil {
		var file struct{ Seen map[string]time.Time }
		if json.Unmarshal(b, &file) == nil && file.Seen != nil {
			m.disc.seen = file.Seen
		}
	}
}

// discoveryLoop refreshes discovery in the background while the agent runs.
func (m *Manager) discoveryLoop() {
	t := time.NewTicker(m.discoverEvery())
	defer t.Stop()
	for {
		ctx, cancel := context.WithTimeout(m.ctx, discoverTimeout)
		_, _ = m.Discover(ctx, true)
		cancel()
		select {
		case <-m.ctx.Done():
			return
		case <-t.C:
		}
	}
}

// Discover returns relays found on reachable networks. Without refresh it
// returns the last pass while it is fresh, with join state recomputed.
func (m *Manager) Discover(ctx context.Context, refresh bool) (Discovery, error) {
	m.loadSeen()
	m.disc.mu.Lock()
	last := m.disc.last
	m.disc.mu.Unlock()
	if !refresh && last != nil && time.Since(last.RefreshedAt) < m.discoverEvery() {
		return m.decorate(*last), nil
	}
	m.disc.run.Lock()
	defer m.disc.run.Unlock()
	// Another caller may have finished a pass while this one waited.
	m.disc.mu.Lock()
	if m.disc.last != nil && m.disc.last != last && time.Since(m.disc.last.RefreshedAt) < m.discoverEvery() {
		d := *m.disc.last
		m.disc.mu.Unlock()
		return m.decorate(d), nil
	}
	m.disc.mu.Unlock()

	var cands []relayCandidate
	var sources []DiscoverySource
	tc, ts := m.tailnetCandidates(ctx)
	bc, bs := m.bonjourCandidates(ctx)
	cands = append(append(cands, tc...), bc...)
	sources = append(sources, ts, bs)
	if m.cfg.DirectoryURL != "" {
		dc, ds := m.directoryCandidates(ctx)
		cands = append(cands, dc...)
		sources = append(sources, ds)
	}

	type probed struct {
		c        relayCandidate
		in       relayInspection
		err      error
		verified string
	}
	results := make([]probed, len(cands))
	var wg sync.WaitGroup
	for i, c := range cands {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r := probed{c: c}
			if c.offline {
				r.err = errors.New("offline on the tailnet")
			} else {
				r.in, r.err = m.inspectRelay(ctx, c)
				if r.err == nil && c.source == "tailnet" && m.verifyTailnetNode(ctx, c) == nil {
					r.verified = "tailnet"
				}
			}
			results[i] = r
		}()
	}
	wg.Wait()

	now := time.Now().UTC()
	byKey := map[string]*DiscoveredRelay{}
	var order []string
	for _, r := range results {
		k := r.c.url
		if r.err == nil {
			k = r.in.pin
		}
		d := byKey[k]
		if d == nil {
			d = &DiscoveredRelay{URL: r.c.url, Sources: []string{}, LastSeen: now}
			byKey[k] = d
			order = append(order, k)
		}
		d.candidates = append(d.candidates, r.c)
		if !slices.Contains(d.Sources, r.c.source) {
			d.Sources = append(d.Sources, r.c.source)
		}
		if r.c.advertisedPin != "" {
			d.AdvertisedPin = r.c.advertisedPin
		}
		if r.c.tailnetDNS != "" && d.TailnetNode == "" {
			d.TailnetNode = r.c.tailnetDNS
		}
		if d.Name == "" {
			d.Name = cleanRelayName(r.c.name)
		}
		if r.err != nil {
			if !d.Reachable {
				d.Error = r.err.Error()
			}
			continue
		}
		if !d.Reachable {
			// Tailnet candidates come first, so a checked tailnet origin wins.
			d.URL = r.c.url
		}
		d.Reachable, d.Error = true, ""
		d.Pin, d.Fingerprint, d.SystemTrusted = r.in.pin, r.in.fingerprint, r.in.systemTrusted
		info := r.in.info
		d.Version, d.Mode, d.Membership, d.AdminContact = info.Version, info.Mode, info.Membership, info.AdminContact
		d.Issuer, d.ClientID = info.Issuer, info.ClientID
		if n := cleanRelayName(info.Name); n != "" {
			d.Name = n
		}
		if r.verified != "" {
			d.Verified = r.verified
		}
	}
	out := Discovery{Relays: []DiscoveredRelay{}, Sources: sources, RefreshedAt: now}
	for _, k := range order {
		d := byKey[k]
		if d.Name == "" {
			d.Name = hostOf(d.URL)
		}
		if d.AdvertisedPin != "" && d.Pin != "" {
			d.AdvertisedPinMatches = d.AdvertisedPin == d.Pin
		}
		d.ID = "r-" + key(k)[:12]
		out.Relays = append(out.Relays, *d)
	}
	slices.SortFunc(out.Relays, func(a, b DiscoveredRelay) int {
		if a.Reachable != b.Reachable {
			if a.Reachable {
				return -1
			}
			return 1
		}
		if c := strings.Compare(strings.ToLower(a.Name), strings.ToLower(b.Name)); c != 0 {
			return c
		}
		return strings.Compare(a.URL, b.URL)
	})
	m.disc.mu.Lock()
	m.disc.last = &out
	m.disc.mu.Unlock()
	return m.decorate(out), nil
}

// decorate fills the fields that depend on the server list and seen set.
func (m *Manager) decorate(d Discovery) Discovery {
	summaries := m.Summaries()
	m.disc.mu.Lock()
	seen := m.disc.seen
	m.disc.mu.Unlock()
	relays := make([]DiscoveredRelay, len(d.Relays))
	for i, r := range d.Relays {
		r.Sources = slices.Clone(r.Sources)
		r.Added, r.ServerID = false, ""
		signedIn := false
		for _, s := range summaries {
			if s.URL == r.URL || (r.Pin != "" && s.Pin == r.Pin) {
				r.Added, r.ServerID, signedIn = true, s.ID, s.SignedIn
				break
			}
		}
		_, known := seen[r.ID]
		r.New = !known && !r.Added
		switch {
		case r.Added && signedIn:
			r.Next = "done"
		case r.Added:
			r.Next = "sign-in"
		case !r.Reachable:
			r.Next = "unreachable"
		case r.Verified == "tailnet" || r.SystemTrusted:
			r.Next = "add"
		default:
			r.Next = "confirm"
		}
		relays[i] = r
	}
	d.Relays = relays
	return d
}

func cleanRelayName(name string) string { return bonjour.CleanName(name) }

func (m *Manager) tailnetCandidates(ctx context.Context) ([]relayCandidate, DiscoverySource) {
	src := DiscoverySource{Name: "tailnet"}
	st, e := m.rawTailnetStatus(ctx)
	switch {
	case errors.Is(e, errTailscaleMissing):
		src.Detail = "Tailscale is not installed"
		return nil, src
	case e != nil:
		src.Detail = e.Error()
		return nil, src
	case st.BackendState != "Running":
		src.Detail = "this Mac is not on a tailnet"
		return nil, src
	}
	src.OK = true
	var out []relayCandidate
	for _, p := range st.Peer {
		dns := trimDot(p.DNSName)
		if dns == "" || !slices.Contains(p.Tags, defaultRelayTag) {
			continue
		}
		u, e := NormalizeRelay("https://" + dns)
		if e != nil {
			continue
		}
		ip := firstIPv4(p.TailscaleIPs)
		if ip == "" && len(p.TailscaleIPs) > 0 {
			ip = p.TailscaleIPs[0]
		}
		if ip == "" {
			continue
		}
		out = append(out, relayCandidate{
			source: "tailnet", url: u, dial: net.JoinHostPort(ip, "443"), sni: dns, name: p.HostName,
			tailnetIP: ip, tailnetDNS: dns, offline: !p.Online,
		})
	}
	slices.SortFunc(out, func(a, b relayCandidate) int { return strings.Compare(a.url, b.url) })
	return out, src
}

func firstIPv4(addrs []string) string {
	for _, a := range addrs {
		if ip := net.ParseIP(a); ip != nil && ip.To4() != nil {
			return a
		}
	}
	return ""
}

func (m *Manager) bonjourCandidates(ctx context.Context) ([]relayCandidate, DiscoverySource) {
	src := DiscoverySource{Name: "bonjour"}
	window := m.cfg.BonjourWindow
	if window <= 0 {
		window = defaultBonjourWindow
	}
	list, e := m.bonjourTools().Browse(ctx, window)
	if errors.Is(e, bonjour.ErrUnavailable) {
		src.Detail = "Bonjour is not available on this system"
		return nil, src
	}
	if e != nil {
		src.Detail = e.Error()
		return nil, src
	}
	src.OK = true
	var out []relayCandidate
	for _, in := range list {
		if v := in.TXT["v"]; v != "" && v != "1" {
			continue
		}
		host := strings.ToLower(in.Host)
		u, e := NormalizeRelay("https://" + net.JoinHostPort(host, strconv.Itoa(in.Port)))
		if e != nil {
			continue
		}
		name := in.TXT["name"]
		if name == "" {
			name = in.Name
		}
		pin := in.TXT["pin"]
		if !strings.HasPrefix(pin, "sha256/") {
			pin = ""
		}
		out = append(out, relayCandidate{
			source: "bonjour", url: u, dial: net.JoinHostPort(host, strconv.Itoa(in.Port)), sni: host,
			name: name, advertisedPin: pin,
		})
	}
	return out, src
}

// inspectRelay reads the relay's certificate and /v1/info over one connection.
func (m *Manager) inspectRelay(ctx context.Context, c relayCandidate) (relayInspection, error) {
	ctx, cancel := context.WithTimeout(ctx, relayProbeTimeout)
	defer cancel()
	conn, e := m.cfg.Dial(ctx, "tcp", c.dial)
	if e != nil {
		return relayInspection{}, fmt.Errorf("cannot connect: %w", e)
	}
	defer conn.Close()
	if dl, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(dl)
	}
	tc := tls.Client(conn, &tls.Config{ServerName: c.sni, InsecureSkipVerify: true, MinVersion: tls.VersionTLS12})
	if e = tc.HandshakeContext(ctx); e != nil {
		return relayInspection{}, fmt.Errorf("TLS handshake failed: %w", e)
	}
	certs := tc.ConnectionState().PeerCertificates
	leaf := certs[0]
	inter := x509.NewCertPool()
	for _, ct := range certs[1:] {
		inter.AddCert(ct)
	}
	_, verr := leaf.Verify(x509.VerifyOptions{DNSName: c.sni, Intermediates: inter, Roots: m.cfg.Roots})
	out := relayInspection{pin: SPKIPin(leaf), fingerprint: fingerprint(leaf), systemTrusted: verr == nil}

	req, e := http.NewRequestWithContext(ctx, "GET", c.url+"/v1/info", nil)
	if e != nil {
		return relayInspection{}, e
	}
	req.Close = true
	if e = req.Write(tc); e != nil {
		return relayInspection{}, fmt.Errorf("not a Commander relay: %w", e)
	}
	resp, e := http.ReadResponse(bufio.NewReader(tc), req)
	if e != nil {
		return relayInspection{}, fmt.Errorf("not a Commander relay: %w", e)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return relayInspection{}, fmt.Errorf("not a Commander relay: HTTP %d", resp.StatusCode)
	}
	if e = json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&out.info); e != nil || out.info.Version == "" {
		return relayInspection{}, errors.New("not a Commander relay: unreadable /v1/info")
	}
	return out, nil
}

type tsWhois struct {
	Node *struct {
		Name      string
		Tags      []string
		Addresses []string
	}
}

// verifyTailnetNode checks with tailscale whois that the candidate's address
// belongs to the tagged peer it was listed as. WireGuard has already
// authenticated that node's key for the connection to this address.
func (m *Manager) verifyTailnetNode(ctx context.Context, c relayCandidate) error {
	out, e := m.runTailscale(ctx, tailnetStatusTimeout, "whois", "--json", c.tailnetIP)
	if e != nil {
		return e
	}
	var w tsWhois
	if e = json.Unmarshal(out, &w); e != nil || w.Node == nil {
		return errors.New("tailscale whois: unreadable output")
	}
	if !strings.EqualFold(trimDot(w.Node.Name), c.tailnetDNS) {
		return errors.New("tailscale whois: the address belongs to a different node")
	}
	if !slices.Contains(w.Node.Tags, defaultRelayTag) {
		return errors.New("tailscale whois: the node is not tagged as a relay")
	}
	if !slices.ContainsFunc(w.Node.Addresses, func(a string) bool {
		ip, _, _ := strings.Cut(a, "/")
		return ip == c.tailnetIP
	}) {
		return errors.New("tailscale whois: the node does not own the address")
	}
	return nil
}

type discoveryInput struct {
	Refresh bool     `json:"refresh"`
	Relay   string   `json:"relay"`
	Relays  []string `json:"relays"`
	Pin     string   `json:"pin"`
	Name    string   `json:"name"`
}

func (m *Manager) discoveryVerb(ctx context.Context, verb string, in discoveryInput) (any, error) {
	switch verb {
	case "relay-discover":
		return m.Discover(ctx, in.Refresh)
	case "relay-discover-seen":
		return struct{}{}, m.markSeen(in.Relays)
	case "relay-join":
		return m.joinDiscovered(ctx, in)
	}
	return nil, errors.New("unknown discovery operation")
}

// markSeen clears the new flag for the named relays, or every relay listed.
func (m *Manager) markSeen(ids []string) error {
	m.loadSeen()
	m.disc.mu.Lock()
	defer m.disc.mu.Unlock()
	if len(ids) == 0 && m.disc.last != nil {
		for _, r := range m.disc.last.Relays {
			ids = append(ids, r.ID)
		}
	}
	now := time.Now().UTC()
	for _, id := range ids {
		if strings.HasPrefix(id, "r-") && len(id) <= 32 {
			if _, ok := m.disc.seen[id]; !ok {
				m.disc.seen[id] = now
			}
		}
	}
	return save(m.discoveryPath(), map[string]any{"seen": m.disc.seen})
}

// joinDiscovered adds a discovered relay to the server list. It re-checks the
// relay now rather than trusting the cached pass: a verified tailnet relay is
// pinned without a prompt, a system-trusted one needs no pin, and any other
// relay needs the pin the person confirmed.
func (m *Manager) joinDiscovered(ctx context.Context, in discoveryInput) (any, error) {
	m.disc.mu.Lock()
	var row *DiscoveredRelay
	if m.disc.last != nil {
		for i := range m.disc.last.Relays {
			if m.disc.last.Relays[i].ID == in.Relay {
				r := m.disc.last.Relays[i]
				row = &r
			}
		}
	}
	m.disc.mu.Unlock()
	if row == nil {
		return nil, errors.New("unknown relay; refresh discovery")
	}
	// Try the tailnet candidate first: only it can skip the confirmation.
	cands := slices.Clone(row.candidates)
	slices.SortStableFunc(cands, func(a, b relayCandidate) int {
		if (a.source == "tailnet") != (b.source == "tailnet") {
			if a.source == "tailnet" {
				return -1
			}
			return 1
		}
		return 0
	})
	var lastErr error
	for _, c := range cands {
		if c.offline {
			lastErr = errors.New("the relay is offline on the tailnet")
			continue
		}
		insp, e := m.inspectRelay(ctx, c)
		if e != nil {
			lastErr = e
			continue
		}
		pin := ""
		switch {
		case c.source == "tailnet" && m.verifyTailnetNode(ctx, c) == nil:
			pin = insp.pin
		case insp.systemTrusted:
		case in.Pin != "" && in.Pin == insp.pin:
			pin = insp.pin
		case in.Pin != "":
			return nil, ErrPinMismatch
		default:
			return nil, fmt.Errorf("confirm the certificate fingerprint %s to add this relay", insp.fingerprint)
		}
		name := strings.TrimSpace(in.Name)
		if name == "" {
			name = row.Name
		}
		return m.serverVerb(ctx, "server-add", serverInput{URL: c.url, Name: name, Pin: pin})
	}
	if lastErr == nil {
		lastErr = errors.New("the relay is unreachable")
	}
	return nil, lastErr
}

// directoryCandidates lists the relays in the public directory. The directory
// is reached with ordinary system trust; the pins it lists are hints, and each
// relay is still probed and confirmed on its own.
func (m *Manager) directoryCandidates(ctx context.Context) ([]relayCandidate, DiscoverySource) {
	src := DiscoverySource{Name: "directory"}
	base, e := NormalizeRelay(m.cfg.DirectoryURL)
	if e != nil {
		src.Detail = "the directory address is invalid"
		return nil, src
	}
	client := &http.Client{Timeout: relayProbeTimeout, Transport: &http.Transport{
		DialContext: m.cfg.Dial, TLSClientConfig: &tls.Config{RootCAs: m.cfg.Roots, MinVersion: tls.VersionTLS12},
	}}
	defer client.CloseIdleConnections()
	req, e := http.NewRequestWithContext(ctx, "GET", base+"/v1/relays", nil)
	if e != nil {
		src.Detail = e.Error()
		return nil, src
	}
	resp, e := client.Do(req)
	if e != nil {
		src.Detail = "cannot reach the directory"
		return nil, src
	}
	defer resp.Body.Close()
	var list struct {
		Relays []struct {
			URL  string `json:"url"`
			Name string `json:"name"`
			Pin  string `json:"pin"`
		} `json:"relays"`
	}
	if resp.StatusCode != http.StatusOK || json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&list) != nil {
		src.Detail = "the directory's answer is unreadable"
		return nil, src
	}
	src.OK = true
	var out []relayCandidate
	for _, r := range list.Relays {
		if len(out) >= 200 {
			break
		}
		u, e := NormalizeRelay(r.URL)
		if e != nil {
			continue
		}
		parsed, e := url.Parse(u)
		if e != nil {
			continue
		}
		port := parsed.Port()
		if port == "" {
			port = "443"
		}
		pin := r.Pin
		if !strings.HasPrefix(pin, "sha256/") {
			pin = ""
		}
		out = append(out, relayCandidate{
			source: "directory", url: u, dial: net.JoinHostPort(parsed.Hostname(), port), sni: parsed.Hostname(),
			name: r.Name, advertisedPin: pin,
		})
	}
	return out, src
}

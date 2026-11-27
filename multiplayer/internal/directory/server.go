package directory

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode"
)

const (
	maxRegistration  = 8 << 10
	registerInterval = 30 * time.Second
	attemptInterval  = 2 * time.Second
	dialTimeout      = 10 * time.Second
	maxListings      = 5000
)

// Server is the directory's HTTP service.
type Server struct {
	// State is the JSON file that keeps listings across restarts; empty keeps
	// them in memory only.
	State string
	// AllowPrivate lets tests register relays on loopback addresses.
	AllowPrivate bool
	// Resolve and Dial are replaced in tests.
	Resolve func(ctx context.Context, host string) ([]net.IP, error)
	Dial    func(ctx context.Context, network, address string) (net.Conn, error)
	Now     func() time.Time
	Log     func(format string, args ...any)

	mu       sync.Mutex
	listings map[string]Listing
	last     map[string]time.Time // verified registrations, by relay URL
	attempts map[string]time.Time // any attempt, by client IP
}

func (s *Server) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *Server) logf(format string, args ...any) {
	if s.Log != nil {
		s.Log(format, args...)
	}
}

// Load reads the state file, if any.
func (s *Server) Load() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.listings, s.last, s.attempts = map[string]Listing{}, map[string]time.Time{}, map[string]time.Time{}
	if s.State == "" {
		return nil
	}
	data, err := os.ReadFile(s.State)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var file struct{ Listings []Listing }
	if err := json.Unmarshal(data, &file); err != nil {
		return fmt.Errorf("directory state: %w", err)
	}
	for _, l := range file.Listings {
		s.listings[l.URL] = l
	}
	return nil
}

// persist writes the state file; the caller holds s.mu.
func (s *Server) persist() error {
	if s.State == "" {
		return nil
	}
	list := make([]Listing, 0, len(s.listings))
	for _, l := range s.listings {
		list = append(list, l)
	}
	slices.SortFunc(list, func(a, b Listing) int { return strings.Compare(a.URL, b.URL) })
	data, err := json.MarshalIndent(map[string]any{"listings": list}, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(s.State), ".directory-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err = tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err = tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), s.State)
}

// Prune removes listings without a heartbeat for KeptFor.
func (s *Server) Prune() {
	s.mu.Lock()
	defer s.mu.Unlock()
	cut := s.now().Add(-KeptFor)
	changed := false
	for u, l := range s.listings {
		if l.LastSeen.Before(cut) {
			delete(s.listings, u)
			changed = true
		}
	}
	if changed {
		if err := s.persist(); err != nil {
			s.logf("directory: save state: %v", err)
		}
	}
}

// Visible lists relays confirmed within VisibleFor, by name.
func (s *Server) Visible() []Listing {
	s.mu.Lock()
	defer s.mu.Unlock()
	cut := s.now().Add(-VisibleFor)
	out := []Listing{}
	for _, l := range s.listings {
		if !l.LastSeen.Before(cut) {
			out = append(out, l)
		}
	}
	slices.SortFunc(out, func(a, b Listing) int {
		if c := strings.Compare(strings.ToLower(a.Name), strings.ToLower(b.Name)); c != 0 {
			return c
		}
		return strings.Compare(a.URL, b.URL)
	})
	return out
}

// Handler serves GET /v1/relays and POST /v1/relays.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/relays", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "public, max-age=60")
		_ = json.NewEncoder(w).Encode(map[string]any{"relays": s.Visible()})
	})
	mux.HandleFunc("POST /v1/relays", s.register)
	mux.HandleFunc("GET /ready", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNoContent) })
	return mux
}

type statusErr struct {
	code int
	msg  string
}

func (e statusErr) Error() string { return e.msg }

func fail(code int, format string, args ...any) error {
	return statusErr{code, fmt.Sprintf(format, args...)}
}

func (s *Server) register(w http.ResponseWriter, r *http.Request) {
	var in Signed
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxRegistration))
	dec.DisallowUnknownFields()
	res, err := any(nil), dec.Decode(&in)
	if err != nil {
		err = fail(http.StatusBadRequest, "invalid registration")
	} else {
		client, _, _ := net.SplitHostPort(r.RemoteAddr)
		res, err = s.apply(r.Context(), client, in)
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	var se statusErr
	switch {
	case errors.As(err, &se):
		w.WriteHeader(se.code)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": se.msg})
	case err != nil:
		w.WriteHeader(http.StatusBadGateway)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
	default:
		_ = json.NewEncoder(w).Encode(res)
	}
}

func (s *Server) apply(ctx context.Context, client string, in Signed) (any, error) {
	if in.Action != "register" && in.Action != "remove" {
		return nil, fail(http.StatusBadRequest, "action must be register or remove")
	}
	origin, err := NormalizeURL(in.URL)
	if err != nil || origin != in.URL {
		return nil, fail(http.StatusBadRequest, "url must be a normalized https origin")
	}
	if !strings.HasPrefix(in.Pin, "sha256/") || len(in.Pin) > 100 {
		return nil, fail(http.StatusBadRequest, "invalid pin")
	}
	now := s.now()
	if d := now.Sub(time.Unix(in.Timestamp, 0)); d > clockSkew || d < -clockSkew {
		return nil, fail(http.StatusBadRequest, "the registration timestamp is outside five minutes")
	}
	s.mu.Lock()
	if s.listings == nil {
		s.listings, s.last, s.attempts = map[string]Listing{}, map[string]time.Time{}, map[string]time.Time{}
	}
	// Throttle each client, and each relay only after a verified registration,
	// so nobody can keep another relay unlisted by posting for its URL.
	if t, ok := s.attempts[client]; ok && now.Sub(t) < attemptInterval {
		s.mu.Unlock()
		return nil, fail(http.StatusTooManyRequests, "too many attempts")
	}
	s.attempts[client] = now
	if t, ok := s.last[origin]; ok && in.Action == "register" && now.Sub(t) < registerInterval {
		s.mu.Unlock()
		return nil, fail(http.StatusTooManyRequests, "registering too often")
	}
	for c, t := range s.attempts {
		if now.Sub(t) > time.Minute {
			delete(s.attempts, c)
		}
	}
	_, known := s.listings[origin]
	full := !known && len(s.listings) >= maxListings
	s.mu.Unlock()
	if full && in.Action == "register" {
		return nil, fail(http.StatusServiceUnavailable, "the directory is full")
	}

	conn, err := s.dialPublic(ctx, origin)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	host, _ := hostPort(origin)
	tc := tls.Client(conn, &tls.Config{ServerName: host, InsecureSkipVerify: true, MinVersion: tls.VersionTLS12})
	if err := tc.HandshakeContext(ctx); err != nil {
		return nil, fail(http.StatusBadGateway, "TLS handshake with the relay failed")
	}
	leaf := tc.ConnectionState().PeerCertificates[0]
	if SPKIPin(leaf) != in.Pin {
		return nil, fail(http.StatusForbidden, "the relay at that URL presents a different key")
	}
	if err := Verify(in, leaf); err != nil {
		return nil, fail(http.StatusForbidden, "%v", err)
	}

	if in.Action == "remove" {
		s.mu.Lock()
		delete(s.listings, origin)
		err := s.persist()
		s.mu.Unlock()
		s.logf("directory: removed %s", origin)
		return map[string]bool{"listed": false}, err
	}

	info, err := readInfo(ctx, tc, origin)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	l := s.listings[origin]
	if l.RegisteredAt.IsZero() {
		l.RegisteredAt = now.UTC()
	}
	l.URL, l.Pin, l.LastSeen = origin, in.Pin, now.UTC()
	l.Name, l.Membership, l.Issuer, l.Mode, l.Version = clean(info.Name, 63), clean(info.Membership, 16), clean(info.Issuer, 200), clean(info.Mode, 16), clean(info.Version, 16)
	if l.Name == "" {
		l.Name = host
	}
	s.listings[origin] = l
	s.last[origin] = now
	err = s.persist()
	s.mu.Unlock()
	s.logf("directory: listed %s (%s)", origin, l.Name)
	return map[string]any{"listed": true, "visibleUntil": now.Add(VisibleFor).UTC()}, err
}

// dialPublic resolves the relay's host and dials one of its public addresses
// directly, so a later DNS answer cannot redirect the check.
func (s *Server) dialPublic(ctx context.Context, origin string) (net.Conn, error) {
	host, port := hostPort(origin)
	ctx, cancel := context.WithTimeout(ctx, dialTimeout)
	defer cancel()
	var ips []net.IP
	if ip := net.ParseIP(host); ip != nil {
		ips = []net.IP{ip}
	} else {
		resolve := s.Resolve
		if resolve == nil {
			resolve = func(ctx context.Context, host string) ([]net.IP, error) {
				addrs, err := net.DefaultResolver.LookupIPAddr(ctx, host)
				out := make([]net.IP, 0, len(addrs))
				for _, a := range addrs {
					out = append(out, a.IP)
				}
				return out, err
			}
		}
		var err error
		if ips, err = resolve(ctx, host); err != nil || len(ips) == 0 {
			return nil, fail(http.StatusBadGateway, "the relay's host does not resolve")
		}
	}
	dial := s.Dial
	if dial == nil {
		dial = (&net.Dialer{}).DialContext
	}
	var lastErr error = fail(http.StatusForbidden, "the relay's address is not public")
	for _, ip := range ips {
		if !s.AllowPrivate && !PublicIP(ip) {
			continue
		}
		conn, err := dial(ctx, "tcp", net.JoinHostPort(ip.String(), port))
		if err == nil {
			_ = conn.SetDeadline(time.Now().Add(dialTimeout))
			return conn, nil
		}
		lastErr = fail(http.StatusBadGateway, "cannot connect to the relay")
	}
	return nil, lastErr
}

type relayInfo struct {
	Version    string `json:"version"`
	Mode       string `json:"mode"`
	Name       string `json:"name"`
	Membership string `json:"membership"`
	Issuer     string `json:"issuer"`
}

func readInfo(ctx context.Context, conn net.Conn, origin string) (relayInfo, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", origin+"/v1/info", nil)
	if err != nil {
		return relayInfo{}, err
	}
	req.Close = true
	if err := req.Write(conn); err != nil {
		return relayInfo{}, fail(http.StatusBadGateway, "the relay did not answer /v1/info")
	}
	resp, err := http.ReadResponse(bufio.NewReader(conn), req)
	if err != nil {
		return relayInfo{}, fail(http.StatusBadGateway, "the relay did not answer /v1/info")
	}
	defer resp.Body.Close()
	var info relayInfo
	if resp.StatusCode != http.StatusOK || json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&info) != nil || info.Version == "" {
		return relayInfo{}, fail(http.StatusBadGateway, "the URL is not a Commander relay")
	}
	return info, nil
}

func clean(s string, max int) string {
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, strings.TrimSpace(s))
	if r := []rune(s); len(r) > max {
		s = string(r[:max])
	}
	return s
}

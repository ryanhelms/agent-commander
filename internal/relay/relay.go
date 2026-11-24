package relay

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	maxHosts        = 128
	maxHandshakes   = 32
	maxRequestBytes = 1 << 20
	appWriteTimeout = 8 * time.Second
)

var hostName = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$`)

// Instance binds the public app endpoint to one host certificate. Multiple
// instances may share the relay, but a pin can identify only one instance.
type Instance struct {
	Host              string `json:"host"`
	CertificateSHA256 string `json:"certificate_sha256"`
}

type Relay struct {
	mu            sync.RWMutex
	routes        routes
	forwarded     atomic.Uint64
	unavailable   atomic.Uint64
	saturated     atomic.Uint64
	interrupted   atomic.Uint64
	responseBytes atomic.Uint64
}

type routes struct {
	hosts map[string]*host
	pins  map[[sha256.Size]byte]*host
}

type host struct {
	pin    [sha256.Size]byte
	mu     sync.Mutex
	active *session
}

type session struct {
	conn      *tunnelConn
	transport *http.Transport
	requests  chan struct{}
}

func New(instances []Instance) (*Relay, error) {
	table, err := buildRoutes(instances)
	if err != nil {
		return nil, err
	}
	return &Relay{routes: table}, nil
}

func buildRoutes(instances []Instance) (routes, error) {
	if instances == nil || len(instances) > maxHosts {
		return routes{}, errors.New("configure an explicit array of up to 128 relay instances")
	}
	table := routes{hosts: make(map[string]*host, len(instances)), pins: make(map[[sha256.Size]byte]*host, len(instances))}
	for _, item := range instances {
		raw, err := hex.DecodeString(item.CertificateSHA256)
		if err != nil || len(raw) != sha256.Size || len(item.Host) > 253 || !hostName.MatchString(item.Host) {
			return routes{}, errors.New("relay instance requires a lowercase DNS name and SHA-256 certificate pin")
		}
		pin := [sha256.Size]byte(raw)
		if table.hosts[item.Host] != nil || table.pins[pin] != nil {
			return routes{}, errors.New("relay host names and certificate pins must be unique")
		}
		instance := &host{pin: pin}
		table.hosts[item.Host], table.pins[pin] = instance, instance
	}
	return table, nil
}

// ReplaceInstances preserves tunnels for unchanged pairs and closes displaced tunnels.
func (r *Relay) ReplaceInstances(instances []Instance) error {
	next, err := buildRoutes(instances)
	if err != nil {
		return err
	}
	r.mu.Lock()
	previous := r.routes
	for name, candidate := range next.hosts {
		if current := previous.hosts[name]; current != nil && current.pin == candidate.pin {
			next.hosts[name], next.pins[candidate.pin] = current, current
		}
	}
	r.routes = next
	r.mu.Unlock()
	for name, instance := range previous.hosts {
		if instance != next.hosts[name] {
			if s := instance.connected(); s != nil {
				_ = s.conn.SetDeadline(time.Now())
				_ = s.conn.Close()
			}
		}
	}
	return nil
}

// Accept handles host-initiated connections on a separate TCP listener. Until
// certificate proof and the HTTP/2 probe succeed, an instance is unavailable.
func (r *Relay) Accept(ctx context.Context, listener net.Listener, cert tls.Certificate) error {
	config := &tls.Config{
		MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{cert},
		ClientAuth: tls.RequireAnyClientCert, NextProtos: []string{"commander-relay/1"},
		VerifyConnection: func(state tls.ConnectionState) error {
			if r.instance(state) == nil {
				return errors.New("unregistered relay connector")
			}
			return nil
		},
	}
	stop := context.AfterFunc(ctx, func() { _ = listener.Close() })
	defer stop()
	pending := make(chan struct{}, maxHandshakes)
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		select {
		case pending <- struct{}{}:
			go r.acceptOne(ctx, tls.Server(conn, config), pending)
		default:
			_ = conn.Close()
		}
	}
}

func (r *Relay) instance(state tls.ConnectionState) *host {
	if len(state.PeerCertificates) == 0 || state.NegotiatedProtocol != "commander-relay/1" {
		return nil
	}
	leaf := state.PeerCertificates[0]
	now := time.Now()
	if now.Before(leaf.NotBefore) || !now.Before(leaf.NotAfter) {
		return nil
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.routes.pins[sha256.Sum256(leaf.Raw)]
}

func (r *Relay) acceptOne(ctx context.Context, raw *tls.Conn, pending chan struct{}) {
	conn := newTunnelConn(raw)
	ready := false
	defer func() {
		_ = conn.Close()
		if !ready {
			<-pending
		}
	}()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	verify, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := raw.HandshakeContext(verify); err != nil {
		return
	}
	state := raw.ConnectionState()
	instance := r.instance(state)
	if instance == nil {
		return
	}
	s := newSession(conn)
	req, _ := http.NewRequestWithContext(verify, http.MethodGet, tunnelOrigin+probePath, nil)
	res, err := s.transport.RoundTrip(req)
	if err != nil {
		return
	}
	_ = res.Body.Close()
	if res.StatusCode != http.StatusNoContent || res.ProtoMajor != 2 || !r.register(instance, s) {
		return
	}
	<-pending
	ready = true
	// An expired connector must authenticate with a renewed certificate.
	expiry := time.NewTimer(time.Until(state.PeerCertificates[0].NotAfter))
	defer expiry.Stop()
	select {
	case <-conn.done:
	case <-expiry.C:
		_ = conn.Close()
	}
	instance.mu.Lock()
	if instance.active == s {
		instance.active = nil
	}
	instance.mu.Unlock()
}

func (r *Relay) register(instance *host, s *session) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.routes.pins[instance.pin] == instance && instance.register(s)
}

func newSession(conn *tunnelConn) *session {
	var dialed atomic.Bool
	transport := &http.Transport{
		Protocols: protocols(), HTTP2: http2Limits(),
		DisableCompression: true, MaxConnsPerHost: 1,
		MaxResponseHeaderBytes: 32 << 10, ResponseHeaderTimeout: 20 * time.Second,
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			if dialed.Swap(true) {
				return nil, net.ErrClosed
			}
			return conn, nil
		},
	}
	return &session{conn: conn, transport: transport, requests: make(chan struct{}, maxStreams)}
}

func (h *host) connected() *session {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.active != nil {
		select {
		case <-h.active.conn.done:
			h.active = nil
		default:
		}
	}
	return h.active
}

func (h *host) register(session *session) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.active != nil {
		select {
		case <-h.active.conn.done:
		default:
			return false
		}
	}
	h.active = session
	return true
}

func (r *Relay) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if req.TLS == nil || (req.Method != http.MethodGet && req.Method != http.MethodPost) ||
		!strings.HasPrefix(req.URL.Path, "/v1/") || req.ContentLength > maxRequestBytes {
		http.Error(w, "Unsupported relay request", http.StatusBadRequest)
		return
	}
	name := req.Host
	if host, _, err := net.SplitHostPort(name); err == nil {
		name = host
	}
	r.mu.RLock()
	instance := r.routes.hosts[strings.ToLower(name)]
	r.mu.RUnlock()
	if instance == nil || !strings.EqualFold(req.TLS.ServerName, name) {
		http.Error(w, "Unknown relay instance", http.StatusMisdirectedRequest)
		return
	}
	if !hasBearer(req.Header.Values("Authorization")) {
		w.Header().Set("WWW-Authenticate", "Bearer")
		http.Error(w, "OAuth access token required", http.StatusUnauthorized)
		return
	}
	s := instance.connected()
	if s == nil {
		r.unavailable.Add(1)
		w.Header().Set("Retry-After", "1")
		http.Error(w, "Commander host unavailable; request was not forwarded", http.StatusServiceUnavailable)
		return
	}
	select {
	case s.requests <- struct{}{}:
		defer func() { <-s.requests }()
	default:
		r.saturated.Add(1)
		w.Header().Set("Retry-After", "1")
		http.Error(w, "Commander host is at its concurrent request limit", http.StatusTooManyRequests)
		return
	}
	r.forwarded.Add(1)
	r.forward(w, req, s)
}

// Metrics exposes aggregate operational counters on the operator listener.
func (r *Relay) Metrics(w http.ResponseWriter, _ *http.Request) {
	r.mu.RLock()
	connected := 0
	for _, instance := range r.routes.hosts {
		if instance.connected() != nil {
			connected++
		}
	}
	r.mu.RUnlock()
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	for _, metric := range []struct {
		name  string
		kind  string
		value uint64
	}{
		{"connected_hosts", "gauge", uint64(connected)},
		{"forwarded_requests_total", "counter", r.forwarded.Load()},
		{"unavailable_requests_total", "counter", r.unavailable.Load()},
		{"saturated_requests_total", "counter", r.saturated.Load()},
		{"interrupted_requests_total", "counter", r.interrupted.Load()},
		{"response_bytes_total", "counter", r.responseBytes.Load()},
	} {
		_, _ = fmt.Fprintf(w, "# TYPE commander_relay_%s %s\ncommander_relay_%s %d\n",
			metric.name, metric.kind, metric.name, metric.value)
	}
}

func hasBearer(headers []string) bool {
	if len(headers) != 1 {
		return false
	}
	parts := strings.Fields(headers[0])
	return len(parts) == 2 && strings.EqualFold(parts[0], "Bearer") && len(parts[1]) <= 8192
}

func (r *Relay) forward(w http.ResponseWriter, req *http.Request, s *session) {
	out := req.Clone(req.Context())
	out.URL = &url.URL{Scheme: "http", Host: "commander", Path: req.URL.Path, RawPath: req.URL.RawPath, RawQuery: req.URL.RawQuery}
	out.Host, out.RequestURI = out.URL.Host, ""
	out.Trailer = nil
	out.TransferEncoding = nil
	out.GetBody = nil
	out.Header = http.Header{}
	for _, name := range []string{"Authorization", "Content-Type", "Accept", "Idempotency-Key"} {
		for _, value := range req.Header.Values(name) {
			out.Header.Add(name, value)
		}
	}
	if out.Body != nil && out.Body != http.NoBody {
		out.Body = http.MaxBytesReader(w, req.Body, maxRequestBytes)
	}
	response, err := s.transport.RoundTrip(out)
	if err != nil {
		if req.Context().Err() == nil {
			r.interrupted.Add(1)
			http.Error(w, "Commander connection ended; reconcile using the original operation identifier", http.StatusBadGateway)
		}
		return
	}
	defer response.Body.Close()
	for _, name := range []string{"Content-Type", "WWW-Authenticate", "X-Accel-Buffering", "Commander-Frontend-Tools"} {
		for _, value := range response.Header.Values(name) {
			w.Header().Add(name, value)
		}
	}
	controller := http.NewResponseController(w)
	write := func(chunk []byte) error {
		deadline := time.Now().Add(appWriteTimeout)
		_ = controller.SetWriteDeadline(deadline)
		var err error
		if chunk == nil {
			w.WriteHeader(response.StatusCode)
		} else {
			var written int
			written, err = w.Write(chunk)
			r.responseBytes.Add(uint64(written))
		}
		if err == nil {
			err = controller.Flush()
		}
		// Waiting for the next upstream frame is outside the app write deadline.
		_ = controller.SetWriteDeadline(time.Time{})
		if err != nil && (req.Context().Err() == nil || !time.Now().Before(deadline)) {
			r.interrupted.Add(1)
		}
		return err
	}
	if err := write(nil); err != nil {
		return
	}
	buf := make([]byte, 32<<10)
	for {
		n, err := response.Body.Read(buf)
		if n > 0 && write(buf[:n]) != nil {
			return
		}
		if err != nil {
			if err != io.EOF && req.Context().Err() == nil {
				r.interrupted.Add(1)
				panic(http.ErrAbortHandler)
			}
			return
		}
	}
}

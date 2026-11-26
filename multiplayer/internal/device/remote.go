package device

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	_ "embed"
	"encoding/base32"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

//go:embed remote/index.html
var remotePage []byte

// tailnet is 100.64.0.0/10, the CGNAT range Tailscale and Headscale assign.
var tailnet = &net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}

// TailnetAddress returns this Mac's tailnet IPv4 address.
func TailnetAddress() (string, error) {
	addrs, e := net.InterfaceAddrs()
	if e != nil {
		return "", e
	}
	for _, a := range addrs {
		if n, ok := a.(*net.IPNet); ok && n.IP.To4() != nil && tailnet.Contains(n.IP) {
			return n.IP.String(), nil
		}
	}
	return "", errors.New("no tailnet address on this Mac; connect Tailscale or Headscale first")
}

type remoteDevice struct {
	ID      string    `json:"id"`
	Name    string    `json:"name"`
	Hash    []byte    `json:"hash"`
	Paired  time.Time `json:"paired"`
	Expires time.Time `json:"expires"`
}

type remoteServer struct {
	mu       sync.Mutex
	srv      *http.Server
	url      string
	code     string
	codeExp  time.Time
	devices  []remoteDevice
	statePth string
}

func randomToken(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return strings.TrimRight(base32.StdEncoding.EncodeToString(b), "=")
}

func (m *Manager) remote() *remoteServer {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.rs == nil {
		m.rs = &remoteServer{statePth: filepath.Join(m.cfg.Dir, "remote-devices.json")}
		if b, e := os.ReadFile(m.rs.statePth); e == nil {
			_ = json.Unmarshal(b, &m.rs.devices)
		}
	}
	return m.rs
}

func (r *remoteServer) persist() error { return save(r.statePth, r.devices) }

func (m *Manager) remoteVerb(ctx context.Context, verb string, in remoteInput) (any, error) {
	rs := m.remote()
	switch verb {
	case "remote-enable":
		rs.mu.Lock()
		defer rs.mu.Unlock()
		if rs.srv == nil {
			listen := in.Listen
			if listen == "" {
				ip, e := TailnetAddress()
				if e != nil {
					return nil, e
				}
				listen = net.JoinHostPort(ip, "8780")
			}
			host, _, e := net.SplitHostPort(listen)
			if ip := net.ParseIP(host); e != nil || ip == nil || !(tailnet.Contains(ip) || ip.IsLoopback()) {
				return nil, errors.New("the remote view listens only on a tailnet or loopback address")
			}
			l, e := net.Listen("tcp", listen)
			if e != nil {
				return nil, e
			}
			rs.srv = &http.Server{Handler: m.remoteHandler(), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 60 * time.Second}
			rs.url = "http://" + l.Addr().String()
			go func() { _ = rs.srv.Serve(l) }()
		}
		rs.code, rs.codeExp = randomToken(5)[:8], time.Now().Add(10*time.Minute)
		return map[string]any{"url": rs.url, "code": rs.code, "expiresAt": rs.codeExp, "pairURL": rs.url + "/pair?code=" + rs.code}, nil
	case "remote-disable":
		rs.mu.Lock()
		defer rs.mu.Unlock()
		if rs.srv != nil {
			_ = rs.srv.Close()
			rs.srv, rs.url = nil, ""
		}
		return struct{}{}, nil
	case "remote-devices":
		rs.mu.Lock()
		defer rs.mu.Unlock()
		out := []map[string]any{}
		for _, d := range rs.devices {
			out = append(out, map[string]any{"id": d.ID, "name": d.Name, "paired": d.Paired, "expires": d.Expires})
		}
		return map[string]any{"devices": out, "url": rs.url, "running": rs.srv != nil}, nil
	case "remote-revoke":
		rs.mu.Lock()
		defer rs.mu.Unlock()
		for i, d := range rs.devices {
			if d.ID == in.Device {
				rs.devices = append(rs.devices[:i], rs.devices[i+1:]...)
				return struct{}{}, rs.persist()
			}
		}
		return nil, errors.New("unknown device")
	}
	return nil, errors.New("unknown operation")
}

type remoteInput struct {
	Listen string `json:"listen"`
	Device string `json:"device"`
}

func hashToken(t string) []byte { h := key(t); return []byte(h) }

func (rs *remoteServer) session(r *http.Request) bool {
	c, e := r.Cookie("ac_remote")
	if e != nil {
		return false
	}
	h := hashToken(c.Value)
	rs.mu.Lock()
	defer rs.mu.Unlock()
	for _, d := range rs.devices {
		if subtle.ConstantTimeCompare(d.Hash, h) == 1 && time.Now().Before(d.Expires) {
			return true
		}
	}
	return false
}

func (m *Manager) remoteHandler() http.Handler {
	rs := m.remote()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /pair", func(w http.ResponseWriter, r *http.Request) {
		code := r.URL.Query().Get("code")
		rs.mu.Lock()
		ok := rs.code != "" && time.Now().Before(rs.codeExp) && subtle.ConstantTimeCompare([]byte(code), []byte(rs.code)) == 1
		if ok {
			rs.code = "" // single use
		}
		rs.mu.Unlock()
		if !ok {
			http.Error(w, "This pairing code is invalid or expired. Create a new one in the Agent Commander tray.", http.StatusForbidden)
			return
		}
		token := randomToken(32)
		name := r.URL.Query().Get("name")
		if name == "" {
			name = "Phone"
		}
		d := remoteDevice{ID: randomToken(5)[:8], Name: name, Hash: hashToken(token), Paired: time.Now().UTC(), Expires: time.Now().Add(30 * 24 * time.Hour)}
		rs.mu.Lock()
		rs.devices = append(rs.devices, d)
		e := rs.persist()
		rs.mu.Unlock()
		if e != nil {
			http.Error(w, "could not save pairing", http.StatusInternalServerError)
			return
		}
		http.SetCookie(w, &http.Cookie{Name: "ac_remote", Value: token, Path: "/", HttpOnly: true, SameSite: http.SameSiteStrictMode, Expires: d.Expires})
		http.Redirect(w, r, "/", http.StatusSeeOther)
	})
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		if !rs.session(r) {
			http.Error(w, "Pair this device from the Agent Commander tray first.", http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:")
		_, _ = w.Write(remotePage)
	})
	api := func(pattern string, f func(*http.Request) (any, error)) {
		mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
			if !rs.session(r) {
				reply(w, nil, errors.New("not paired"))
				return
			}
			if r.Method == "POST" && r.Header.Get("X-Commander-Remote") != "1" {
				reply(w, nil, errors.New("missing request guard"))
				return
			}
			v, e := f(r)
			reply(w, v, e)
		})
	}
	api("GET /api/overview", func(r *http.Request) (any, error) {
		return map[string]any{"servers": m.Summaries(), "approvals": m.allApprovals(r.Context()), "activity": m.activity()}, nil
	})
	api("GET /api/approvals", func(r *http.Request) (any, error) {
		return map[string]any{"approvals": m.allApprovals(r.Context())}, nil
	})
	api("POST /api/approvals/{server}/{id}/{decision}", func(r *http.Request) (any, error) {
		a, e := m.agentUse(r.PathValue("server"), false)
		if e != nil {
			return nil, e
		}
		d := r.PathValue("decision")
		if d != "approve" && d != "deny" {
			return nil, errors.New("unknown decision")
		}
		return a.tray(r.Context(), d, input{ID: r.PathValue("id")})
	})
	api("GET /api/activity", func(r *http.Request) (any, error) { return m.activity(), nil })
	api("GET /api/handoffs", func(r *http.Request) (any, error) { return m.perServer(r.Context(), "handoffs", input{}) })
	api("GET /api/watch/{server}/{resource}", func(r *http.Request) (any, error) {
		a, e := m.agentUse(r.PathValue("server"), false)
		if e != nil {
			return nil, e
		}
		s, e := a.getSession(r.Context())
		if e != nil {
			return nil, e
		}
		return a.liveVerb(r.Context(), s, "watch", input{Resource: r.PathValue("resource"), After: r.URL.Query().Get("after")})
	})
	return mux
}

// allApprovals lists pending approvals on every server.
func (m *Manager) allApprovals(ctx context.Context) []map[string]any {
	m.mu.Lock()
	agents := map[string]*Agent{}
	for id, a := range m.agents {
		agents[id] = a
	}
	m.mu.Unlock()
	out := []map[string]any{}
	for id, a := range agents {
		s, err := a.getSession(ctx)
		if err != nil {
			continue
		}
		list, _ := a.approvals(ctx, s)["approvals"].([]Approval)
		for _, ap := range list {
			out = append(out, map[string]any{"server": id, "approval": ap})
		}
	}
	return out
}

// perServer runs a read verb on every signed-in server.
func (m *Manager) perServer(ctx context.Context, verb string, in input) (any, error) {
	out := map[string]any{}
	for _, s := range m.Summaries() {
		if !s.SignedIn {
			continue
		}
		a, e := m.agentUse(s.ID, false)
		if e != nil {
			continue
		}
		sess, e := a.getSession(ctx)
		if e != nil {
			continue
		}
		if v, e := a.requesterVerb(ctx, sess, verb, in); e == nil {
			out[s.ID] = v
		}
	}
	return out, nil
}

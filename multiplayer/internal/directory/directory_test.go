package directory

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"errors"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func selfSigned(t *testing.T, key crypto.Signer) tls.Certificate {
	t.Helper()
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "relay.example.test"},
		DNSNames: []string{"relay.example.test"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, key.Public(), key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, _ := x509.ParseCertificate(der)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: leaf}
}

func ecKey(t *testing.T) crypto.Signer {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func TestSignAndVerify(t *testing.T) {
	rsaKey, _ := rsa.GenerateKey(rand.Reader, 2048)
	_, edKey, _ := ed25519.GenerateKey(rand.Reader)
	for name, key := range map[string]crypto.Signer{"ecdsa": ecKey(t), "rsa": rsaKey, "ed25519": edKey} {
		t.Run(name, func(t *testing.T) {
			cert := selfSigned(t, key)
			reg, err := NewRegistration("register", "relay.example.test:443", cert, time.Now())
			if err != nil {
				t.Fatal(err)
			}
			if reg.URL != "https://relay.example.test" || reg.Pin != SPKIPin(cert.Leaf) {
				t.Fatalf("registration %+v", reg)
			}
			signed, err := Sign(reg, cert)
			if err != nil {
				t.Fatal(err)
			}
			if err := Verify(signed, cert.Leaf); err != nil {
				t.Fatal(err)
			}
			tampered := signed
			tampered.Action = "remove"
			if Verify(tampered, cert.Leaf) == nil {
				t.Fatal("verified a changed action")
			}
			if Verify(signed, selfSigned(t, ecKey(t)).Leaf) == nil {
				t.Fatal("verified with another key")
			}
		})
	}
}

func TestPublicIPAndURL(t *testing.T) {
	for ip, want := range map[string]bool{
		"8.8.8.8": true, "2606:4700::1111": true, "10.0.0.1": false, "192.168.1.5": false, "127.0.0.1": false,
		"100.64.0.7": false, "169.254.1.1": false, "fd7a:115c:a1e0::1": false, "::1": false, "0.0.0.0": false, "224.0.0.1": false,
	} {
		if got := PublicIP(net.ParseIP(ip)); got != want {
			t.Errorf("PublicIP(%s) = %v", ip, got)
		}
	}
	for in, want := range map[string]string{"Relay.Example.org": "https://relay.example.org", "https://r.example.org:443/": "https://r.example.org", "r.example.org:8443": "https://r.example.org:8443"} {
		if got, err := NormalizeURL(in); err != nil || got != want {
			t.Errorf("NormalizeURL(%q) = %q, %v", in, got, err)
		}
	}
	for _, bad := range []string{"http://r", "https://r/path", "https://u@r"} {
		if _, err := NormalizeURL(bad); err == nil {
			t.Errorf("accepted %q", bad)
		}
	}
}

type clock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *clock) Now() time.Time      { c.mu.Lock(); defer c.mu.Unlock(); return c.now }
func (c *clock) add(d time.Duration) { c.mu.Lock(); c.now = c.now.Add(d); c.mu.Unlock() }

type fixture struct {
	relay    *httptest.Server
	cert     tls.Certificate
	origin   string
	dir      *Server
	dirHTTP  *httptest.Server
	clock    *clock
	info     map[string]any
	infoLock sync.Mutex
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	f := &fixture{clock: &clock{now: time.Now()}, info: map[string]any{"version": "1", "mode": "host", "name": "Studio\x07 Relay", "membership": "allowlist", "issuer": "https://accounts.google.com"}}
	f.cert = selfSigned(t, ecKey(t))
	f.relay = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/info" {
			f.infoLock.Lock()
			defer f.infoLock.Unlock()
			json.NewEncoder(w).Encode(f.info)
			return
		}
		http.NotFound(w, r)
	}))
	f.relay.TLS = &tls.Config{Certificates: []tls.Certificate{f.cert}}
	f.relay.StartTLS()
	t.Cleanup(f.relay.Close)
	_, port, _ := net.SplitHostPort(f.relay.Listener.Addr().String())
	f.origin = "https://relay.example.test:" + port
	f.dir = &Server{State: filepath.Join(t.TempDir(), "directory.json"), AllowPrivate: true, Now: f.clock.Now,
		Resolve: func(ctx context.Context, host string) ([]net.IP, error) {
			if host == "relay.example.test" {
				return []net.IP{net.ParseIP("127.0.0.1")}, nil
			}
			return nil, errors.New("no such host")
		}}
	if err := f.dir.Load(); err != nil {
		t.Fatal(err)
	}
	f.dirHTTP = httptest.NewTLSServer(f.dir.Handler())
	t.Cleanup(f.dirHTTP.Close)
	return f
}

func (f *fixture) registrar(cert tls.Certificate) Registrar {
	return Registrar{Directory: f.dirHTTP.URL, PublicURL: f.origin, Cert: cert, HTTP: f.dirHTTP.Client(), Now: f.clock.Now}
}

func (f *fixture) listed(t *testing.T) []Listing {
	t.Helper()
	resp, err := f.dirHTTP.Client().Get(f.dirHTTP.URL + "/v1/relays")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if cc := resp.Header.Get("Cache-Control"); !strings.Contains(cc, "public") {
		t.Fatalf("cache control %q", cc)
	}
	var out struct{ Relays []Listing }
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	return out.Relays
}

func TestRegisterListAndExpire(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	if err := f.registrar(f.cert).Send(ctx, "register"); err != nil {
		t.Fatal(err)
	}
	list := f.listed(t)
	if len(list) != 1 {
		t.Fatalf("listings %+v", list)
	}
	l := list[0]
	if l.URL != f.origin || l.Name != "Studio Relay" || l.Membership != "allowlist" || l.Pin != SPKIPin(f.cert.Leaf) || l.Mode != "host" {
		t.Fatalf("listing %+v", l)
	}

	// Heartbeats too soon are refused; a later one renews.
	f.clock.add(3 * time.Second)
	if err := f.registrar(f.cert).Send(ctx, "register"); err == nil || !strings.Contains(err.Error(), "too often") {
		t.Fatalf("early heartbeat: %v", err)
	}
	f.clock.add(10 * time.Minute)
	if err := f.registrar(f.cert).Send(ctx, "register"); err != nil {
		t.Fatal(err)
	}
	// Hidden after VisibleFor without a heartbeat, kept until KeptFor.
	f.clock.add(16 * time.Minute)
	if len(f.listed(t)) != 0 {
		t.Fatal("stale listing still visible")
	}
	f.dir.Prune()
	reloaded := &Server{State: f.dir.State, Now: f.clock.Now}
	if err := reloaded.Load(); err != nil || len(reloaded.listings) != 1 {
		t.Fatalf("state after restart: %v %v", reloaded.listings, err)
	}
	f.clock.add(8 * 24 * time.Hour)
	f.dir.Prune()
	if err := reloaded.Load(); err != nil || len(reloaded.listings) != 0 {
		t.Fatalf("pruned state: %v %v", reloaded.listings, err)
	}
}

func TestRegistrationIsVerified(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	step := func() { f.clock.add(3 * time.Second) }

	// Another key cannot list the relay, with its own pin or the relay's.
	other := selfSigned(t, ecKey(t))
	if err := f.registrar(other).Send(ctx, "register"); err == nil || !strings.Contains(err.Error(), "different key") {
		t.Fatalf("other key: %v", err)
	}
	step()
	reg, _ := NewRegistration("register", f.origin, f.cert, f.clock.Now())
	forged, _ := Sign(reg, other)
	if code, msg := post(t, f, forged); code != http.StatusForbidden || !strings.Contains(msg, "signature") {
		t.Fatalf("forged signature: %d %s", code, msg)
	}
	step()
	// Old timestamps are refused.
	stale, _ := NewRegistration("register", f.origin, f.cert, f.clock.Now().Add(-10*time.Minute))
	signed, _ := Sign(stale, f.cert)
	if code, _ := post(t, f, signed); code != http.StatusBadRequest {
		t.Fatalf("stale: %d", code)
	}
	step()
	// Something that is not a relay is refused.
	f.infoLock.Lock()
	f.info = map[string]any{}
	f.infoLock.Unlock()
	if err := f.registrar(f.cert).Send(ctx, "register"); err == nil || !strings.Contains(err.Error(), "not a Commander relay") {
		t.Fatalf("not a relay: %v", err)
	}
	step()
	// Clients are throttled.
	reg, _ = NewRegistration("register", f.origin, f.cert, f.clock.Now())
	signed, _ = Sign(reg, f.cert)
	post(t, f, signed)
	if code, msg := post(t, f, signed); code != http.StatusTooManyRequests || !strings.Contains(msg, "attempts") {
		t.Fatalf("throttle: %d %s", code, msg)
	}
	// Private addresses are refused outside tests.
	f.dir.AllowPrivate = false
	step()
	if err := f.registrar(f.cert).Send(ctx, "register"); err == nil || !strings.Contains(err.Error(), "not public") {
		t.Fatalf("private address: %v", err)
	}
	if len(f.listed(t)) != 0 {
		t.Fatal("an unverified relay was listed")
	}
}

func post(t *testing.T, f *fixture, s Signed) (int, string) {
	t.Helper()
	body, _ := json.Marshal(s)
	resp, err := f.dirHTTP.Client().Post(f.dirHTTP.URL+"/v1/relays", "application/json", strings.NewReader(string(body)))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var e struct{ Error string }
	json.NewDecoder(resp.Body).Decode(&e)
	return resp.StatusCode, e.Error
}

func TestRegistrarRunRegistersAndRemoves(t *testing.T) {
	f := newFixture(t)
	r := f.registrar(f.cert)
	r.Now = nil // real time; the run removes right after it registers
	f.dir.Now = nil
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { r.Run(ctx); close(done) }()
	deadline := time.Now().Add(5 * time.Second)
	for len(f.listed(t)) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("never listed")
		}
		time.Sleep(20 * time.Millisecond)
	}
	// The removal comes from the same client right away; let the per-client throttle pass.
	time.Sleep(attemptInterval + 100*time.Millisecond)
	cancel()
	<-done
	if len(f.listed(t)) != 0 {
		t.Fatal("still listed after the relay stopped")
	}
	if _, err := os.Stat(f.dir.State); err != nil {
		t.Fatal(err)
	}
}

func TestRegistrarFollowsItsTarget(t *testing.T) {
	f := newFixture(t)
	f.dir.Now = nil
	var mu sync.Mutex
	target := ""
	var statuses []Status
	r := f.registrar(f.cert)
	r.Now, r.Check = nil, 100*time.Millisecond
	r.Target = func() (string, string) { mu.Lock(); defer mu.Unlock(); return target, f.dirHTTP.URL }
	r.OnStatus = func(s Status) { mu.Lock(); statuses = append(statuses, s); mu.Unlock() }
	last := func() Status {
		mu.Lock()
		defer mu.Unlock()
		if len(statuses) == 0 {
			return Status{}
		}
		return statuses[len(statuses)-1]
	}
	wait := func(what string, ok func() bool) {
		t.Helper()
		deadline := time.Now().Add(8 * time.Second)
		for !ok() {
			if time.Now().After(deadline) {
				t.Fatalf("timed out waiting for %s; last status %+v", what, last())
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { r.Run(ctx); close(done) }()

	// Unlisted to begin with: nothing is sent.
	time.Sleep(300 * time.Millisecond)
	if len(f.listed(t)) != 0 || last().Listed {
		t.Fatalf("listed without a target: %+v", last())
	}
	// Turning listing on registers within a check.
	mu.Lock()
	target = f.origin
	mu.Unlock()
	wait("the listing", func() bool { return len(f.listed(t)) == 1 && last().Listed && last().URL == f.origin })
	// Turning it off removes the listing, retrying past the per-client throttle.
	mu.Lock()
	target = ""
	mu.Unlock()
	wait("the removal", func() bool { return len(f.listed(t)) == 0 && last().URL == "" && !last().Listed })
	cancel()
	<-done
}

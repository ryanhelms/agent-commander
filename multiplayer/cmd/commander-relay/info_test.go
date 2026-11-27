package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/devicekeys"
	"agentcommander.network/pilot/internal/hostmode"
	"agentcommander.network/pilot/internal/identity"
)

// Exercise the HTTPS server and client over a pipe without reserving a TCP port.
type pipeListener struct {
	conns chan net.Conn
	done  chan struct{}
	once  sync.Once
}

func newPipeListener() *pipeListener {
	return &pipeListener{conns: make(chan net.Conn), done: make(chan struct{})}
}

func (p *pipeListener) Addr() net.Addr { return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 443} }
func (p *pipeListener) Accept() (net.Conn, error) {
	select {
	case c := <-p.conns:
		return c, nil
	case <-p.done:
		return nil, net.ErrClosed
	}
}
func (p *pipeListener) Close() error {
	p.once.Do(func() { close(p.done) })
	return nil
}
func (p *pipeListener) dial(ctx context.Context, _, _ string) (net.Conn, error) {
	client, server := net.Pipe()
	select {
	case p.conns <- server:
		return client, nil
	case <-ctx.Done():
		client.Close()
		server.Close()
		return nil, ctx.Err()
	}
}

func TestRelayInfo(t *testing.T) {
	dir := t.TempDir()
	cert, err := hostmode.EnsureTLS(dir, []string{"127.0.0.1"})
	if err != nil {
		t.Fatal(err)
	}
	rootCAs, err := roots(filepath.Join(dir, "tls", "ca.pem"))
	if err != nil {
		t.Fatal(err)
	}
	keys, err := devicekeys.Generate()
	if err != nil {
		t.Fatal(err)
	}
	deviceCert, err := keys.TLSCertificate()
	if err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{"edge", "host"} {
		t.Run(mode, func(t *testing.T) {
			var secret atomic.Value
			secret.Store("")
			cfg := relaySettings{mode: mode, name: "Studio", identity: identity.Config{Issuer: "https://issuer.test", ClientID: "desktop",
				ClientSecret: func() string { return secret.Load().(string) }}}
			var membership atomic.Value
			membership.Store("open")
			// A 204 means the request reached the existing protected router.
			server := relayServer(cert, cfg, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(http.StatusNoContent)
			}), func(context.Context) (control.PublicSettings, error) {
				return control.PublicSettings{Membership: membership.Load().(string), AdminContact: "owner@example.test", Policy: control.Policy{RetentionDays: 30}}, nil
			})
			ln := newPipeListener()
			ts := &httptest.Server{Listener: ln, Config: server, TLS: server.TLSConfig}
			ts.StartTLS()
			defer ts.Close()
			client := func(certs ...tls.Certificate) *http.Client {
				tr := &http.Transport{DialContext: ln.dial, TLSClientConfig: &tls.Config{RootCAs: rootCAs, Certificates: certs}}
				t.Cleanup(tr.CloseIdleConnections)
				return &http.Client{Transport: tr, Timeout: 5 * time.Second}
			}
			anon := client()
			checkInfo(t, anon, ts.URL, mode, cfg.name, cfg.identity.Issuer, cfg.identity.ClientID, "open")
			membership.Store("invite")
			checkInfo(t, anon, ts.URL, mode, cfg.name, cfg.identity.Issuer, cfg.identity.ClientID, "invite")
			// /v1/info says whether the relay provides its sign-in client, never the secret.
			if body := rawInfo(t, anon, ts.URL); !strings.Contains(body, `"clientSecretProvided":false`) {
				t.Fatalf("info without a secret: %s", body)
			}
			secret.Store("installed-app-secret")
			if body := rawInfo(t, anon, ts.URL); !strings.Contains(body, `"clientSecretProvided":true`) || strings.Contains(body, "installed-app-secret") {
				t.Fatalf("info with a secret: %s", body)
			}
			for _, req := range []struct{ method, path string }{
				{"GET", "/ready"}, {"POST", "/v1/auth/challenge"}, {"GET", "/v1/profile"},
				{"HEAD", "/v1/info"}, {"POST", "/v1/info"}, {"GET", "/v1/info/"},
			} {
				r, err := http.NewRequest(req.method, ts.URL+req.path, nil)
				if err != nil {
					t.Fatal(err)
				}
				res, err := anon.Do(r)
				if err != nil {
					t.Fatal(err)
				}
				res.Body.Close()
				if res.StatusCode != http.StatusUnauthorized {
					t.Errorf("anonymous %s %s: HTTP %d", req.method, req.path, res.StatusCode)
				}
			}
			res, err := client(deviceCert).Get(ts.URL + "/ready")
			if err != nil {
				t.Fatal(err)
			}
			res.Body.Close()
			if res.StatusCode != http.StatusNoContent {
				t.Errorf("valid device certificate: HTTP %d", res.StatusCode)
			}
			if res, err := client(cert).Get(ts.URL + "/v1/info"); err == nil {
				res.Body.Close()
				t.Error("TLS accepted a server certificate as a device credential")
			}
		})
	}
}

func checkInfo(t *testing.T, client *http.Client, origin, mode, name, issuer, id, membership string) {
	t.Helper()
	res, err := client.Get(origin + "/v1/info")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var info struct {
		Version, Mode, Name, Issuer, ClientID string
		control.PublicSettings
	}
	if err := json.NewDecoder(res.Body).Decode(&info); err != nil {
		t.Fatal(err)
	}
	if res.StatusCode != http.StatusOK || info.Version != "1" || info.Mode != mode || info.Name != name ||
		info.Issuer != issuer || info.ClientID != id || info.Membership != membership ||
		info.AdminContact != "owner@example.test" || info.Policy.RetentionDays != 30 {
		t.Fatalf("GET /v1/info returned HTTP %d %+v", res.StatusCode, info)
	}
}

func rawInfo(t *testing.T, client *http.Client, origin string) string {
	t.Helper()
	res, err := client.Get(origin + "/v1/info")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	b, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

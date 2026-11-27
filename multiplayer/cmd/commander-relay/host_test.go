package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/devicekeys"
	"agentcommander.network/pilot/internal/hostmode"
)

func TestHostModeIntegration(t *testing.T) {
	const bin = "/opt/homebrew/opt/postgresql@17/bin"
	for _, name := range []string{"initdb", "postgres"} {
		if _, err := os.Stat(filepath.Join(bin, name)); errors.Is(err, os.ErrNotExist) {
			t.Skipf("PostgreSQL 17 binary %s is missing", name)
		} else if err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("COMMANDER_PG_BIN", bin)
	// Keep the full Unix socket path inside Darwin's sockaddr_un limit.
	dir, err := os.MkdirTemp("/tmp", "commander-host-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)

	// Supply a private HTTPS discovery endpoint. The relay itself binds a real
	// TCP port and uses its production PostgreSQL, NATS and HTTP server.
	discovered := make(chan struct{}, 1)
	oidcListener := newPipeListener()
	issuer := &httptest.Server{Listener: oidcListener, Config: &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/.well-known/openid-configuration" {
			http.NotFound(w, r)
			return
		}
		origin := "https://" + r.Host
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{
			"issuer": origin, "authorization_endpoint": origin + "/auth", "token_endpoint": origin + "/token", "jwks_uri": origin + "/keys",
		})
		select {
		case discovered <- struct{}{}:
		default:
		}
	})}}
	issuer.StartTLS()
	defer issuer.Close()
	issuer.Client().Transport.(*http.Transport).DialContext = oidcListener.dial

	ctx, stop := context.WithTimeout(context.Background(), 90*time.Second)
	defer stop()
	args := []string{"host", "init", "--dir", dir, "--name", "Studio host", "--listen", "127.0.0.1:0",
		"--hostname", "studio.test", "--hostname", "127.0.0.1", "--issuer", issuer.URL,
		"--client-id", "desktop", "--allow-email", "guest@example.test", "--admin", "owner@example.test"}
	if err := run(ctx, args); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	var runErr error
	go func() {
		runErr = serveHost(ctx, dir, issuer.Client())
		close(done)
	}()
	defer func() {
		stop()
		select {
		case <-done:
			if runErr != nil && !t.Failed() {
				t.Errorf("host exited: %v", runErr)
			}
			if _, err := os.Stat(filepath.Join(dir, "postgres", "postmaster.pid")); !errors.Is(err, os.ErrNotExist) {
				t.Errorf("PostgreSQL failed to remove postmaster.pid: %v", err)
			}
		case <-time.After(15 * time.Second):
			t.Error("host failed to shut down")
		}
	}()
	select {
	case <-discovered:
	case <-done:
		t.Fatalf("host startup: %v", runErr)
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	var status bytes.Buffer
	if err := hostmode.Status(dir, &status); err != nil {
		t.Fatal(err)
	}
	var origin string
	for line := range strings.Lines(status.String()) {
		if addr, ok := strings.CutPrefix(line, "Listen URL: "); ok {
			origin = strings.TrimSpace(addr)
		}
	}
	rootCAs, err := roots(filepath.Join(dir, "tls", "ca.pem"))
	if err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: rootCAs}}}
	defer client.CloseIdleConnections()
	checkInfo(t, client, origin, "host", "Studio host", issuer.URL, "desktop", "allowlist")

	key, err := devicekeys.Generate()
	if err != nil {
		t.Fatal(err)
	}
	cert, err := key.TLSCertificate()
	if err != nil {
		t.Fatal(err)
	}
	device := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: rootCAs, Certificates: []tls.Certificate{cert}}}}
	defer device.CloseIdleConnections()
	for {
		res, err := device.Get(origin + "/ready")
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		if res.StatusCode == http.StatusNoContent {
			break
		}
		if res.StatusCode != http.StatusServiceUnavailable {
			t.Fatalf("unexpected readiness response: HTTP %d", res.StatusCode)
		}
		select {
		case <-time.After(50 * time.Millisecond):
		case <-done:
			t.Fatalf("host exited before becoming ready: %v", runErr)
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
	}
}

func TestHostJSONReportsStateAndFailure(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	dir := filepath.Join(t.TempDir(), "relay")
	var out bytes.Buffer
	if err := hostJSON(&out, dir, "status", nil); err != nil {
		t.Fatal(err)
	}
	var result hostResult
	if err := json.Unmarshal(out.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if !result.OK || result.Host == nil || result.Host.State != "unconfigured" {
		t.Fatalf("status of an unconfigured host: %s", out.String())
	}

	out.Reset()
	err := hostJSON(&out, dir, "install", nil)
	if !errors.Is(err, errReported) {
		t.Fatalf("install without host.json: %v", err)
	}
	result = hostResult{}
	if err := json.Unmarshal(out.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.OK || result.Host != nil || result.Error == "" {
		t.Fatalf("failed install: %s", out.String())
	}
}

func TestHostConfigureClientSecret(t *testing.T) {
	dir := t.TempDir()
	if err := hostmode.InitConfig(dir, hostmode.Config{
		Name: "Relay", Listen: ":8443", Hostnames: []string{"relay.example.test"},
		Issuer: hostmode.GoogleIssuer, ClientID: "desktop", Admins: []string{"admin@example.test"},
	}); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(t.TempDir(), "client.json")
	if err := os.WriteFile(file, []byte(`{"installed":{"client_id":"desktop","client_secret":"GOCSPX-x"}}`), 0600); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if err := hostCommand(ctx, []string{"--dir", dir, "configure", "--client-secret-file", file}); err != nil {
		t.Fatal(err)
	}
	if got := hostmode.ClientSecret(dir); got != "GOCSPX-x" {
		t.Fatalf("secret %q", got)
	}
	cfg, err := hostmode.ReadConfig(dir)
	if err != nil || cfg.Listen != ":8443" {
		t.Fatalf("setting the secret changed the configuration: %+v %v", cfg, err)
	}
	if err := hostCommand(ctx, []string{"--dir", dir, "configure", "--client-secret-file", file, "--clear-client-secret"}); err == nil {
		t.Fatal("accepted both flags")
	}
	if err := hostCommand(ctx, []string{"--dir", dir, "configure", "--clear-client-secret"}); err != nil {
		t.Fatal(err)
	}
	if hostmode.ClientSecret(dir) != "" {
		t.Fatal("secret not cleared")
	}
}

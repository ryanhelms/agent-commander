package main

import (
	"crypto/tls"
	"encoding/pem"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestPrivateIssuerTrustIsExplicitAndSeparate(t *testing.T) {
	issuer := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if len(r.TLS.PeerCertificates) != 0 {
			t.Error("issuer received a relay device certificate")
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	issuer.TLS = &tls.Config{ClientAuth: tls.RequestClientCert}
	issuer.StartTLS()
	defer issuer.Close()
	ca := filepath.Join(t.TempDir(), "issuer.pem")
	if err := os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: issuer.Certificate().Raw}), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("COMMANDER_NETWORK_CA", ca)
	t.Setenv("COMMANDER_NETWORK_OIDC_CA", "")
	if client, err := issuerClient(); err != nil || client != nil {
		t.Fatalf("relay trust changed the system issuer transport: %v", err)
	}
	t.Setenv("COMMANDER_NETWORK_CA", filepath.Join(t.TempDir(), "unused-relay.pem"))
	t.Setenv("COMMANDER_NETWORK_OIDC_CA", ca)
	client, err := issuerClient()
	if err != nil || client == nil {
		t.Fatalf("could not load the private issuer root: %v", err)
	}
	defer client.CloseIdleConnections()
	res, err := client.Get(issuer.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusNoContent {
		t.Fatalf("private issuer request returned HTTP %d", res.StatusCode)
	}
	if err := os.WriteFile(ca, []byte("invalid PEM"), 0600); err != nil {
		t.Fatal(err)
	}
	if client, err := issuerClient(); err == nil || client != nil {
		t.Fatal("invalid explicit issuer trust did not fail closed")
	}
}

func TestDaemonOwnershipBeforeDeviceInitialization(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "ac-device-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	t.Setenv("COMMANDER_NETWORK_CA", filepath.Join(dir, "absent-ca.pem"))
	socket := filepath.Join(dir, "device.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	original, err := os.Stat(socket)
	if err != nil {
		t.Fatal(err)
	}

	// Changing sockets must not give two daemons access to the same policies.
	state, err := os.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer state.Close()
	if err := syscall.Flock(int(state.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	otherSocket := filepath.Join(dir, "alternate.sock")
	if err := daemon(t.Context(), dir, otherSocket, ""); !errors.Is(err, errDaemonBusy) {
		t.Fatalf("contended state returned %v", err)
	}
	if _, err := os.Lstat(otherSocket); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("loser touched alternate socket: %v", err)
	}
	if err := syscall.Flock(int(state.Fd()), syscall.LOCK_UN); err != nil {
		t.Fatal(err)
	}
	if err := daemon(t.Context(), dir, socket, ""); err == nil || !strings.Contains(err.Error(), "socket is in use") {
		t.Fatalf("live listener returned %v", err)
	}
	if current, err := os.Stat(socket); err != nil || !os.SameFile(original, current) {
		t.Fatalf("live socket replaced: %v", err)
	}
}

func TestServeOutputIsPrivateAndBounded(t *testing.T) {
	dir := t.TempDir()
	f, err := serveOutput(dir)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString("panic: first\n")
	f.Close()
	name := filepath.Join(dir, "logs", "serve.stderr.log")
	if st, err := os.Stat(name); err != nil || st.Mode().Perm() != 0600 {
		t.Fatalf("stderr file mode: %v", err)
	}
	if st, err := os.Stat(filepath.Join(dir, "logs")); err != nil || st.Mode().Perm() != 0700 {
		t.Fatalf("logs dir mode: %v", err)
	}
	if f, err = serveOutput(dir); err != nil {
		t.Fatal(err)
	}
	f.Close()
	if data, _ := os.ReadFile(name); string(data) != "panic: first\n" {
		t.Fatalf("output not appended: %q", data)
	}
	if err = os.WriteFile(name, make([]byte, 6<<20), 0600); err != nil {
		t.Fatal(err)
	}
	if f, err = serveOutput(dir); err != nil {
		t.Fatal(err)
	}
	f.Close()
	if st, _ := os.Stat(name); st.Size() != 0 {
		t.Fatalf("oversized output kept %d bytes", st.Size())
	}
}

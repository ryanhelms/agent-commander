//go:build darwin && cgo

package device

import (
	"bytes"
	"context"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/devicekeys"
	"agentcommander.network/pilot/internal/testpilot"
	"github.com/jackc/pgx/v5/pgxpool"
)

const keychainProcessConfig = "PILOT_TEST_KEYCHAIN_PROCESS"
const keychainTestPrefix = "test-keychain-restart-"

type keychainPeerConfig struct {
	Socket, Dir, Store, Relay, Issuer, CA, IssuerCA string
	ExpireAccess                                    bool
}

func TestKeychainPeerProcess(t *testing.T) {
	raw := os.Getenv(keychainProcessConfig)
	if raw == "" {
		t.Skip("invoked by TestMacOSKeychainSessionRestart")
	}
	var cfg keychainPeerConfig
	if err := json.Unmarshal([]byte(raw), &cfg); err != nil {
		t.Fatal("invalid private test device configuration")
	}
	suffix, fixture := strings.CutPrefix(cfg.Store, keychainTestPrefix)
	if id, err := hex.DecodeString(suffix); !fixture || err != nil || len(id) != 16 {
		t.Fatal("expected a disposable Keychain account")
	}
	pem, err := os.ReadFile(cfg.CA)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(pem) {
		t.Fatal("invalid fixture CA")
	}
	issuerPEM, err := os.ReadFile(cfg.IssuerCA)
	if err != nil {
		t.Fatal(err)
	}
	issuerRoots := x509.NewCertPool()
	if !issuerRoots.AppendCertsFromPEM(issuerPEM) {
		t.Fatal("invalid fixture issuer CA")
	}
	store, err := devicekeys.Keychain(cfg.Store)
	if err != nil {
		t.Fatal(err)
	}
	p := &testpilot.Pilot{Issuer: cfg.Issuer, IssuerRoots: issuerRoots}
	browser := p.Browser("keychain-alice")
	if cfg.ExpireAccess {
		// The same persisted session is restored after the test advances only
		// its local access-token deadline. The relay must rotate the credential.
		saved, err := store.Load()
		if err != nil {
			t.Fatal(err)
		}
		var record credentials
		if json.Unmarshal(saved, &record) != nil || record.Session.User == "" {
			t.Fatal("no signed-in session persisted in Keychain")
		}
		record.Session.ExpiresAt = time.Now().Add(-time.Minute)
		saved, err = json.Marshal(record)
		if err != nil {
			t.Fatal(err)
		}
		if err := store.Save(saved); err != nil {
			t.Fatal(err)
		}
		browser = func(string) error { return errors.New("session restart must not open a browser") }
	}
	issuerHTTP := p.OIDCHTTP()
	defer issuerHTTP.CloseIdleConnections()
	a, err := New(t.Context(), Config{Relay: cfg.Relay, Dir: cfg.Dir, Roots: roots, OIDCHTTP: issuerHTTP, OpenBrowser: browser, Secrets: store})
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	ln, err := net.Listen("unix", cfg.Socket)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	if err := os.Chmod(cfg.Socket, 0600); err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: a.Handler(), ReadHeaderTimeout: 5 * time.Second}
	if err := server.Serve(ln); err != nil {
		t.Fatal(err)
	}
}

func TestMacOSKeychainSessionRestart(t *testing.T) {
	if os.Getenv("PILOT_TEST_MACOS_KEYCHAIN") != "1" {
		t.Skip("set PILOT_TEST_MACOS_KEYCHAIN=1 to use a disposable macOS Keychain item")
	}
	p := testpilot.Start(t)
	ctx, cancel := context.WithTimeout(t.Context(), 90*time.Second)
	defer cancel()
	item := keychainTestPrefix + newID()
	store, err := devicekeys.Keychain(item)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Load(); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("disposable Keychain item was not empty")
	}
	t.Cleanup(func() {
		if err := store.Delete(); err != nil {
			t.Error(err)
		} else if _, err := store.Load(); !errors.Is(err, os.ErrNotExist) {
			t.Error("disposable Keychain item remained after cleanup")
		}
	})
	folder, err := os.MkdirTemp("/tmp", "ac-keychain-e2e-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(folder) })
	cfg := keychainPeerConfig{
		Socket: filepath.Join(folder, "device.sock"), Dir: filepath.Join(folder, "state"), Store: item,
		Relay: p.Edges[0], Issuer: p.Issuer, CA: p.CAPath, IssuerCA: p.IssuerCAPath,
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	start := func() (*pilotPeer, func()) {
		t.Helper()
		data, err := json.Marshal(cfg)
		if err != nil {
			t.Fatal(err)
		}
		cmd := exec.CommandContext(ctx, exe, "-test.run=^TestKeychainPeerProcess$")
		cmd.Env = append(os.Environ(), keychainProcessConfig+"="+string(data))
		var diagnostic bytes.Buffer
		cmd.Stderr, cmd.Stdout = &diagnostic, &diagnostic
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		done := make(chan error, 1)
		go func() { done <- cmd.Wait() }()
		stop := func() {
			_ = cmd.Process.Kill()
			<-done
			_ = os.Remove(cfg.Socket)
		}
		stopped := false
		cleanup := func() {
			if !stopped {
				stopped = true
				stop()
			}
		}
		t.Cleanup(cleanup)
		transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", cfg.Socket)
		}}
		t.Cleanup(transport.CloseIdleConnections)
		client := &http.Client{Transport: transport, Timeout: 2 * time.Second}
		for {
			reply, err := client.Post("http://keychain-peer/tray/status", "application/json", bytes.NewBufferString("{}"))
			if err == nil {
				reply.Body.Close()
				if reply.StatusCode == http.StatusOK {
					break
				}
			}
			select {
			case err := <-done:
				done <- err
				t.Fatalf("device helper exited: %v\n%s", err, diagnostic.String())
			case <-ctx.Done():
				t.Fatal("device helper never became available")
			case <-time.After(75 * time.Millisecond):
			}
		}
		proxy := httputil.NewSingleHostReverseProxy(&url.URL{Scheme: "http", Host: "keychain-peer"})
		proxy.Transport = transport
		return &pilotPeer{handle: "keychain-alice", api: proxy}, cleanup
	}
	alice, stopAlice := start()
	alice.must(t, ctx, "/tray/login", input{Handle: alice.handle}, nil)
	alice.waitOnline(t, ctx)

	bob := startPeer(t, ctx, p, 1, "keychain-bob", nil)
	bob.must(t, ctx, "/tray/login", input{Handle: bob.handle}, nil)
	bob.waitOnline(t, ctx)
	alice.must(t, ctx, "/tray/request", input{Handle: bob.handle}, nil)
	bob.must(t, ctx, "/tray/accept", input{Handle: alice.handle}, nil)
	bob.must(t, ctx, "/tray/resource-add", input{ID: "worker", Name: "Peer worker", Kind: "agent", Target: bob.worker}, nil)
	bob.must(t, ctx, "/tray/grant", input{Approval: "auto", Handle: alice.handle, Resource: "worker", Capability: "agent.ask", MaxUses: 1}, nil)

	pool, err := pgxpool.New(ctx, p.DatabaseURL)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	type deviceState struct {
		user, device string
		accessHash   []byte
		refreshHash  []byte
		generation   int64
	}
	read := func(handle string) deviceState {
		t.Helper()
		var row deviceState
		err := pool.QueryRow(ctx, `SELECT p.user_id,d.device,d.access_hash,d.refresh_hash,l.generation
			FROM mp_profiles p JOIN mp_auth_devices d ON p.user_id=d.user_id
			JOIN mp_leases l ON d.device=l.device WHERE p.handle=$1`, handle).
			Scan(&row.user, &row.device, &row.accessHash, &row.refreshHash, &row.generation)
		if err != nil {
			t.Fatal(err)
		}
		return row
	}
	previous := read(alice.handle)
	if read(bob.handle).user == previous.user {
		t.Fatal("fixture accounts resolved to the same identity")
	}
	stopAlice()
	cfg.ExpireAccess = true
	alice, _ = start()
	alice.waitOnline(t, ctx)
	current := read(alice.handle)
	if current.user != previous.user || current.device != previous.device || current.generation <= previous.generation {
		t.Fatal("restart did not recover the same device and advance its lease")
	}
	if bytes.Equal(current.accessHash, previous.accessHash) || bytes.Equal(current.refreshHash, previous.refreshHash) {
		t.Fatal("restart did not rotate both relay credentials")
	}
	friends := alice.state(t, ctx).Friends
	if len(friends) != 1 || friends[0].Handle != bob.handle || !friends[0].Online {
		t.Fatal("restart did not recover the live friendship")
	}
	var status struct {
		Shared []struct {
			ID      string
			Actions []string
		}
	}
	alice.must(t, ctx, "/tray/status", input{}, &status)
	if len(status.Shared) != 1 || status.Shared[0].ID != "worker" ||
		!slices.Equal(status.Shared[0].Actions, []string{"agent.ask"}) {
		t.Fatal("restart did not recover the scoped resource grant")
	}
	t.Log("macOS helper restarted, rotated its Keychain-backed session, and recovered the friend and grant")
}

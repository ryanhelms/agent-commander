package device

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/devicekeys"
)

const heldRelay = "https://held.example.test"

type gatedCredentials struct {
	loads   chan struct{}
	results chan error
	abort   chan struct{}
	saving  chan struct{}
	saved   chan error
	saves   atomic.Int32
}

func (s *gatedCredentials) KeychainBacked() bool { return true }

func (s *gatedCredentials) Load() ([]byte, error) {
	select {
	case <-s.abort:
		return nil, devicekeys.ErrKeychainAccess
	case s.loads <- struct{}{}:
	}
	select {
	case <-s.abort:
		return nil, devicekeys.ErrKeychainAccess
	case err := <-s.results:
		return nil, err
	}
}

func (s *gatedCredentials) Save([]byte) error {
	s.saves.Add(1)
	if s.saving == nil {
		return nil
	}
	close(s.saving)
	select {
	case <-s.abort:
		return devicekeys.ErrKeychainAccess
	case e := <-s.saved:
		return e
	}
}
func (s *gatedCredentials) Delete() error { return nil }

type startupTestReply struct {
	OK    bool
	Data  json.RawMessage
	Error string
}

func startupTestManager(t *testing.T, holdSave bool) (*Manager, *gatedCredentials, func(string, any) startupTestReply, *atomic.Int32) {
	t.Helper()
	root := t.TempDir()
	state := filepath.Join(root, "state")
	if err := privateDir(state); err != nil {
		t.Fatal(err)
	}
	if err := save(filepath.Join(state, "servers.json"), map[string][]Server{"servers": {
		{ID: "held", URL: heldRelay, AutoConnect: true},
		{ID: "ready", URL: "https://ready.example.test", AutoConnect: true},
	}}); err != nil {
		t.Fatal(err)
	}
	store := &gatedCredentials{loads: make(chan struct{}, 3), results: make(chan error, 3), abort: make(chan struct{})}
	if holdSave {
		store.saving, store.saved = make(chan struct{}), make(chan error, 1)
	}
	browsers := &atomic.Int32{}
	c := ManagerConfig{
		Dir: state, NoPresence: true,
		OpenBrowser: func(string) error { browsers.Add(1); return nil },
		Secrets: func(url string) (devicekeys.Store, error) {
			if url == heldRelay {
				return store, nil
			}
			return devicekeys.Directory(filepath.Join(root, "ready-credentials"))
		},
	}
	type managerResult struct {
		manager *Manager
		err     error
	}
	created := make(chan managerResult, 1)
	go func() {
		m, err := NewManager(t.Context(), c)
		created <- managerResult{m, err}
	}()
	var m *Manager
	select {
	case result := <-created:
		if result.err != nil {
			close(store.abort)
			t.Fatal(result.err)
		}
		m = result.manager
	case <-time.After(2 * time.Second):
		close(store.abort)
		t.Fatal("credential access blocked construction of the local API")
	}
	httpd := httptest.NewServer(m.Handler())
	t.Cleanup(func() {
		close(store.abort)
		m.Close()
		httpd.Close()
	})
	client := httpd.Client()
	client.Timeout = 2 * time.Second
	request := func(verb string, in any) startupTestReply {
		t.Helper()
		raw, err := json.Marshal(in)
		if err != nil {
			t.Fatal(err)
		}
		r, err := client.Post(httpd.URL+"/tray/"+verb, "application/json", bytes.NewReader(raw))
		if err != nil {
			t.Fatalf("%s did not respond during startup: %v", verb, err)
		}
		defer r.Body.Close()
		var reply startupTestReply
		if err = json.NewDecoder(r.Body).Decode(&reply); err != nil {
			t.Fatalf("%s returned an invalid envelope: %v", verb, err)
		}
		return reply
	}
	return m, store, request, browsers
}

func waitCredentialLoad(t *testing.T, s *gatedCredentials) {
	t.Helper()
	select {
	case <-s.loads:
	case <-time.After(2 * time.Second):
		t.Fatal("credential read did not start")
	}
}

func TestStartupKeychainPendingKeepsLocalAPIAndOtherRelaysResponsive(t *testing.T) {
	m, store, request, browsers := startupTestManager(t, false)
	waitCredentialLoad(t, store)
	waitManagerAgent(t, m, "ready")
	reply := request("servers", map[string]string{})
	var list struct{ Servers []ServerSummary }
	if !reply.OK || json.Unmarshal(reply.Data, &list) != nil || len(list.Servers) != 2 {
		t.Fatalf("server list unavailable: %+v", reply)
	}
	for _, server := range list.Servers {
		switch server.ID {
		case "held":
			if server.State != "keychainPending" || server.SignedIn || server.Error != keychainWaitingText {
				t.Fatalf("pending server presented stale availability: %+v", server)
			}
		case "ready":
			if server.State != "signedOut" {
				t.Fatalf("other server could not start independently: %+v", server)
			}
		default:
			t.Fatalf("unexpected server: %+v", server)
		}
	}
	held := map[string]string{"server": "held"}
	reply = request("status", held)
	var scoped struct {
		State, Error, Handle           string
		Online, SignedIn, LoginPending bool
	}
	if !reply.OK || json.Unmarshal(reply.Data, &scoped) != nil || scoped.State != "keychainPending" ||
		scoped.Error != keychainWaitingText || scoped.SignedIn || scoped.Online || scoped.LoginPending || scoped.Handle != "" {
		t.Fatalf("pending status presented stale session state: %s", reply.Data)
	}
	if reply = request("status", map[string]string{"server": "held", "unexpected": "value"}); reply.OK {
		t.Fatal("pending status accepted an unknown request field")
	}
	if reply = request("grant", map[string]string{"server": "held", "resource": "project", "handle": "peer"}); reply.OK || reply.Error != keychainWaitingText {
		t.Fatalf("grant did not refuse the pending connection: %+v", reply)
	}
	coordinator := httptest.NewRequest("POST", "/coordinator/resources", strings.NewReader("{}"))
	coordinator.Header.Set("X-Commander-Server", "held")
	denied := httptest.NewRecorder()
	m.Handler().ServeHTTP(denied, coordinator)
	if strings.Contains(denied.Body.String(), "Keychain") || !strings.Contains(denied.Body.String(), "coordinator credential") {
		t.Fatalf("an unauthenticated coordinator saw credential state: %s", denied.Body.String())
	}
	invite := InviteLink(heldRelay, "", "example", "")
	if reply = request("join", map[string]string{"link": invite}); reply.OK || reply.Error != keychainWaitingText {
		t.Fatalf("invite did not refuse the pending connection: %+v", reply)
	}

	// A denied store can include platform diagnostics. They must not appear in
	// the list, scoped status, or refused operation.
	store.results <- fmt.Errorf("an internal OS error with diagnostics: %w", devicekeys.ErrKeychainAccess)
	end := time.Now().Add(2 * time.Second)
	for {
		reply = request("status", held)
		if strings.Contains(string(reply.Data), keychainRetryText) {
			break
		}
		if time.Now().After(end) {
			t.Fatalf("denial did not replace the pending state: %s", reply.Data)
		}
		testSleep()
	}
	if !reply.OK || json.Unmarshal(reply.Data, &scoped) != nil || scoped.State != "error" ||
		scoped.Error != keychainRetryText || strings.Contains(string(reply.Data), "diagnostics") {
		t.Fatalf("denial did not return actionable sanitized status: %+v", reply)
	}
	if reply = request("grant", held); reply.OK || reply.Error != keychainRetryText {
		t.Fatalf("grant did not refuse denied activation: %+v", reply)
	}
	select {
	case <-store.loads:
		t.Fatal("credential denial was retried without the owner's action")
	default:
	}
	for _, enabled := range []bool{false, true} {
		if reply = request("server-update", map[string]any{"server": "held", "autoConnect": enabled}); !reply.OK {
			t.Fatalf("toggle Auto-connect: %+v", reply)
		}
	}
	waitCredentialLoad(t, store)
	store.results <- os.ErrNotExist
	waitManagerAgent(t, m, "held")
	if store.saves.Load() != 1 || browsers.Load() != 0 {
		t.Fatalf("recovery invoked credential saves=%d, browsers=%d", store.saves.Load(), browsers.Load())
	}
	if reply = request("grant", held); reply.OK || reply.Error == keychainWaitingText || reply.Error == keychainRetryText {
		t.Fatalf("ready connection did not handle the new grant attempt itself: %+v", reply)
	}
}

func TestStartupKeychainAllowedReadContinuesTheSameActivation(t *testing.T) {
	m, store, request, _ := startupTestManager(t, false)
	waitCredentialLoad(t, store)
	m.mu.Lock()
	first := m.activations["held"]
	m.mu.Unlock()
	held := map[string]string{"server": "held"}
	reply := request("status", held)
	if !reply.OK || !strings.Contains(string(reply.Data), `"state":"keychainPending"`) {
		t.Fatalf("read did not expose the pending state: %+v", reply)
	}
	store.results <- os.ErrNotExist
	waitManagerAgent(t, m, "held")
	m.mu.Lock()
	current := m.activations["held"]
	m.mu.Unlock()
	reply = request("status", held)
	if current != first || !reply.OK || strings.Contains(string(reply.Data), "keychainPending") || store.saves.Load() != 1 {
		t.Fatalf("allow did not continue the original startup: %+v", reply)
	}
}

func TestStartupKeychainPendingWhileCreatingCredentials(t *testing.T) {
	m, store, request, _ := startupTestManager(t, true)
	waitCredentialLoad(t, store)
	store.results <- os.ErrNotExist
	select {
	case <-store.saving:
	case <-time.After(2 * time.Second):
		t.Fatal("initial credential save did not start")
	}
	reply := request("status", map[string]string{"server": "held"})
	if !reply.OK || !strings.Contains(string(reply.Data), `"state":"keychainPending"`) {
		t.Fatalf("first save did not expose a bounded waiting status: %+v", reply)
	}
	store.saved <- nil
	waitManagerAgent(t, m, "held")
}

func TestStartupKeychainFencesRetiredAccess(t *testing.T) {
	t.Run("disable and reenable", func(t *testing.T) {
		m, store, request, _ := startupTestManager(t, false)
		waitCredentialLoad(t, store)
		m.mu.Lock()
		first := m.activations["held"]
		m.mu.Unlock()
		for _, enabled := range []bool{false, true} {
			if reply := request("server-update", map[string]any{"server": "held", "autoConnect": enabled}); !reply.OK {
				t.Fatalf("toggle Auto-connect: %+v", reply)
			}
		}
		select {
		case <-store.loads:
			t.Fatal("replacement started while native access was outstanding")
		default:
		}
		store.results <- os.ErrNotExist
		waitCredentialLoad(t, store)
		m.mu.Lock()
		replacement, active := m.activations["held"], m.agents["held"]
		m.mu.Unlock()
		if replacement == first || active != nil || store.saves.Load() != 0 {
			t.Fatal("the retired credential check published or saved credentials")
		}
		store.results <- os.ErrNotExist
		waitManagerAgent(t, m, "held")
		if store.saves.Load() != 1 {
			t.Fatalf("credential saves=%d, want one for only the replacement", store.saves.Load())
		}
	})
	t.Run("shutdown", func(t *testing.T) {
		m, store, _, _ := startupTestManager(t, false)
		waitCredentialLoad(t, store)
		m.mu.Lock()
		attempt := m.activations["held"]
		m.mu.Unlock()
		stopped := make(chan struct{})
		go func() { m.Close(); close(stopped) }()
		select {
		case <-stopped:
		case <-time.After(2 * time.Second):
			t.Fatal("shutdown waited for Keychain")
		}
		store.results <- os.ErrNotExist
		select {
		case <-attempt.done:
		case <-time.After(2 * time.Second):
			t.Fatal("retired check failed to settle")
		}
		m.mu.Lock()
		defer m.mu.Unlock()
		if m.activations["held"] != nil || m.agents["held"] != nil || store.saves.Load() != 0 {
			t.Fatal("a credential check continued activation after shutdown")
		}
		if attempt.ctx.Err() != context.Canceled {
			t.Fatal("the start context was not canceled")
		}
	})
}

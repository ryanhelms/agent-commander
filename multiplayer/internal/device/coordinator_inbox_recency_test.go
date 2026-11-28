package device

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/actions"
	"agentcommander.network/pilot/internal/identity"
)

func TestCoordinatorInboxPreservesRelayRecency(t *testing.T) {
	who, socket := startPilotCommander(t, "inbox-recency")
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/v1/resources" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(`{"resources":[]}`))
	}))
	t.Cleanup(relay.Close)

	dir := t.TempDir()
	servers := []Server{
		{ID: "alternate", AutoConnect: true, LastUsedAt: time.Unix(2, 0).UTC()},
		{ID: "favorite", AutoConnect: true, Favorite: true, LastUsedAt: time.Unix(1, 0).UTC()},
	}
	m := &Manager{
		cfg:     ManagerConfig{Dir: dir, CommanderSocket: socket},
		servers: append([]Server(nil), servers...),
		agents:  make(map[string]*Agent),
	}
	var selected string
	for _, server := range servers {
		a := &Agent{
			cfg: Config{
				Relay:           relay.URL,
				Dir:             filepath.Join(dir, server.ID),
				CommanderSocket: socket,
				configureActions: func(c actions.Config) actions.Config {
					selected = server.ID
					c.Resources = []actions.Resource{
						{ID: "inbox", Kind: "agent", Coordinator: true, Target: who.actor, Run: who.run},
					}
					return c
				},
			},
			http: relay.Client(),
		}
		a.creds.Session = identity.Session{User: "fixture-user", ExpiresAt: time.Now().Add(time.Hour)}
		m.agents[server.ID] = a
	}
	if err := m.persist(); err != nil {
		t.Fatal(err)
	}

	saved := func() (os.FileInfo, []byte) {
		t.Helper()
		info, err := os.Stat(m.listPath())
		if err != nil {
			t.Fatal(err)
		}
		data, err := os.ReadFile(m.listPath())
		if err != nil {
			t.Fatal(err)
		}
		return info, data
	}
	initialFile, initialData := saved()
	handler := m.Handler()
	request := func(t *testing.T, verb, server, body, bearer string, status int) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest(http.MethodPost, "/coordinator/"+verb, strings.NewReader(body)).WithContext(t.Context())
		r.Header.Set("X-Commander-Server", server)
		r.Header.Set("Authorization", "Bearer "+bearer)
		r.Header.Set("X-Commander-Worker", who.actor)
		r.Header.Set("X-Commander-Run", who.run)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != status {
			t.Fatalf("%s %q status %d, want %d: %s", verb, server, w.Code, status, w.Body.String())
		}
		return w
	}
	assertNoRecencyChange := func(t *testing.T) {
		t.Helper()
		info, data := saved()
		if !os.SameFile(info, initialFile) || !bytes.Equal(data, initialData) {
			t.Error("inbox read rewrote saved relay preferences")
		}
		for i, initial := range servers {
			if !m.servers[i].LastUsedAt.Equal(initial.LastUsedAt) {
				t.Errorf("inbox read changed %s last-used time", initial.ID)
			}
		}
	}

	for _, tc := range []struct{ label, server, body, want string }{
		{"default", "", `{}`, "favorite"},
		{"named", "alternate", `{}`, "alternate"},
		{"bounded wait", "alternate", `{"waitSeconds":1}`, "alternate"},
		{"default after named", "", `{}`, "favorite"},
	} {
		t.Run(tc.label, func(t *testing.T) {
			selected = ""
			w := request(t, "inbox", tc.server, tc.body, who.bearer, http.StatusOK)
			var out struct {
				OK   bool
				Data struct{ Messages []json.RawMessage }
			}
			if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil || !out.OK || out.Data.Messages == nil || len(out.Data.Messages) != 0 {
				t.Fatalf("unexpected inbox response: %s", w.Body.String())
			}
			if selected != tc.want {
				t.Errorf("coordinator used relay %q, want %q", selected, tc.want)
			}
			assertNoRecencyChange(t)
		})
	}

	selected = ""
	request(t, "inbox", "alternate", `{}`, "invalid-fixture-bearer", http.StatusBadRequest)
	if selected != "" {
		t.Error("invalid coordinator proof reached an inbox")
	}
	assertNoRecencyChange(t)

	request(t, "discover", "alternate", `{}`, who.bearer, http.StatusOK)
	info, data := saved()
	if os.SameFile(info, initialFile) || bytes.Equal(data, initialData) {
		t.Error("deliberate discovery did not save relay recency")
	}
	if !m.servers[0].LastUsedAt.After(servers[0].LastUsedAt) || !m.servers[1].LastUsedAt.Equal(servers[1].LastUsedAt) {
		t.Error("deliberate discovery did not record use of only the named relay")
	}
}

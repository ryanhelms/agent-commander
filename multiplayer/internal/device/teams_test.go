package device

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/identity"
)

func TestLooksSecret(t *testing.T) {
	for _, s := range []string{"token=abcdef123456", "ghp_abcdefghijklmnopqrstuvwxyz123456", "-----BEGIN RSA PRIVATE KEY-----"} {
		if !LooksSecret(s) {
			t.Errorf("missed %q", s)
		}
	}
	for _, s := range []string{"token=${GITHUB_TOKEN}", "Use the review skill", `"env": {"API_KEY": "${API_KEY}"}`} {
		if LooksSecret(s) {
			t.Errorf("false positive %q", s)
		}
	}
}

func TestKnowledgeInstall(t *testing.T) {
	makeItem := func(kind, content string) json.RawMessage {
		t.Helper()
		b, err := json.Marshal(map[string]string{"kind": kind, "name": "sample", "content": content})
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	a := &Agent{creds: credentials{Session: identity.Session{User: "me", ExpiresAt: time.Now().Add(time.Hour)}}}
	for _, kind := range []string{"prompt", "instructions", "summary"} {
		data, msg := call(t, a.Handler(), "knowledge-install", input{Item: makeItem(kind, "copy ${EXAMPLE}")})
		var out struct{ Content string }
		if msg != "" || json.Unmarshal(data, &out) != nil || out.Content != "copy ${EXAMPLE}" {
			t.Fatalf("%s copy: %s, %s", kind, data, msg)
		}
	}

	path := filepath.Join(t.TempDir(), "mcp.json")
	if err := os.WriteFile(path, []byte("previous config"), 0644); err != nil {
		t.Fatal(err)
	}
	var accounts []string
	const value = "value with \"quotes\" and\na newline"
	lookup := func(_ context.Context, name string) (string, error) {
		accounts = append(accounts, name)
		if name == "KNOWN" {
			return value, nil
		}
		return "", os.ErrNotExist
	}
	in := input{Item: makeItem("mcp", `{"env":["${KNOWN}", "${UNKNOWN} ${OTHER}", "${KNOWN} ${UNKNOWN}"]}`), Destination: path}
	reply, err := installKnowledge(t.Context(), in, lookup)
	if err != nil {
		t.Fatal(err)
	}
	result := reply.(map[string]any)
	if !slices.Equal(accounts, []string{"KNOWN", "UNKNOWN", "OTHER"}) || result["installed"] != path ||
		!slices.Equal(result["missing"].([]string), []string{"UNKNOWN", "OTHER"}) {
		t.Fatalf("keychain lookups %v, install result %v", accounts, result)
	}
	b, err := os.ReadFile(path)
	var cfg struct{ Env []string }
	if err != nil || json.Unmarshal(b, &cfg) != nil || !slices.Equal(cfg.Env, []string{value, "${UNKNOWN} ${OTHER}", value + " ${UNKNOWN}"}) {
		t.Fatalf("installed MCP configuration has wrong values (%v)", err)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("MCP destination permissions: %v (%v)", info, err)
	}
}

func TestKnowledgeShareVersion(t *testing.T) {
	var routes []string
	mock := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		routes = append(routes, r.Method+" "+r.URL.Path)
		var item struct{ Content string }
		if json.NewDecoder(r.Body).Decode(&item) != nil || item.Content != "token=${TOKEN}" {
			t.Error("wrong relay payload")
		}
		_, _ = w.Write([]byte(`{"id":"item-1"}`))
	})
	a := &Agent{cfg: Config{Relay: testRelayURL}, http: &http.Client{Transport: relayTransport{mock}},
		creds: credentials{Session: identity.Session{User: "me", ExpiresAt: time.Now().Add(time.Hour)}}}
	for _, id := range []string{"", "item-1"} {
		in := input{ID: id, Item: json.RawMessage(`{"kind":"mcp","name":"config","content":"token=${TOKEN}"}`)}
		data, msg := call(t, a.Handler(), "knowledge-share", in)
		if msg != "" || !strings.Contains(string(data), "item-1") {
			t.Fatalf("shared version %q: %s %s", id, data, msg)
		}
		in.Item = json.RawMessage(`{"content":"token=example123456"}`)
		if _, msg = call(t, a.Handler(), "knowledge-share", in); !strings.Contains(msg, "seems to contain a secret") {
			t.Fatalf("secret check on %q: %s", id, msg)
		}
	}
	if !slices.Equal(routes, []string{"POST /v1/knowledge", "PUT /v1/knowledge/item-1"}) {
		t.Fatalf("knowledge routes: %v", routes)
	}
}

func queueTestRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	pilotGit(t, dir, "init", "-b", "release")
	pilotGit(t, dir, "config", "user.name", "Queue Test")
	pilotGit(t, dir, "config", "user.email", "queue@localhost")
	pilotGit(t, dir, "config", "core.hooksPath", "/dev/null")
	pilotGit(t, dir, "config", "commit.gpgsign", "false")
	pilotGit(t, dir, "commit", "--allow-empty", "-qm", "base")
	return dir
}

func TestTrayServerQueues(t *testing.T) {
	m := testManager(t)
	ctx, stop := context.WithCancel(t.Context())
	stop()
	m.ctx = ctx // Keep the fixture's signed-in devices offline.
	h := m.Handler()
	legacy := filepath.Join(m.cfg.Dir, queueFile)
	checkout := queueTestRepo(t)
	pilotGit(t, checkout, "switch", "-c", "other")
	pilotGit(t, checkout, "commit", "--allow-empty", "-qm", "contribution")
	pilotGit(t, checkout, "switch", "-c", "unrelated", "release")
	unrelated := pilotGit(t, checkout, "rev-parse", "unrelated")
	if err := save(legacy, []queueEntry{{Workspace: "w", Branch: "legacy", Checkout: checkout, State: "queued"}}); err != nil {
		t.Fatal(err)
	}
	addServer := func(url string) string {
		t.Helper()
		data, msg := call(t, h, "server-add", map[string]string{"url": url})
		var s ServerSummary
		if msg != "" || json.Unmarshal(data, &s) != nil || s.ID == "" || s.Error != "" {
			t.Fatalf("add server: %s %s", data, msg)
		}
		m.agents[s.ID].creds.Session = identity.Session{User: "me", ExpiresAt: time.Now().Add(time.Hour)}
		m.agents[s.ID].http = &http.Client{Transport: relayTransport{http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != "GET" || r.URL.Path != "/v1/workspaces" || r.URL.Host != url {
				t.Errorf("unexpected workspace lookup: %s %s", r.Method, r.URL)
			}
			if url == "b.example.test" {
				w.Write([]byte(`{"workspaces":[{"id":"w","base":"release","integration":"queue"},{"id":"pr","base":"release","integration":"pull_request"}]}`))
			} else {
				w.Write([]byte(`{"workspaces":[]}`))
			}
		})}}
		return s.ID
	}
	a, b := addServer("a.example.test"), addServer("b.example.test")
	if _, err := os.Stat(legacy); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("legacy queue still present: %v", err)
	}
	queue := func(verb string, in input) []queueEntry {
		t.Helper()
		data, msg := call(t, h, verb, in)
		var result struct{ Queue []queueEntry }
		if msg != "" || json.Unmarshal(data, &result) != nil {
			t.Fatalf("%s: %s %s", verb, data, msg)
		}
		return result.Queue
	}
	if rows := queue("queue", input{Server: b}); len(rows) != 0 {
		t.Fatalf("second server inherited queue: %+v", rows)
	}
	if _, why := call(t, h, "queue-add", input{Server: a, Workspace: "w", Branch: "other", Checkout: checkout}); !strings.Contains(why, "unknown workspace w") {
		t.Fatalf("workspace on the wrong server: %s", why)
	}
	nonGit := t.TempDir()
	bare := t.TempDir()
	pilotGit(t, bare, "init", "--bare")
	for _, tc := range []struct{ workspace, checkout, want string }{
		{"pr", checkout, "pull_request"},
		{"w", nonGit, "not a Git work tree"},
		{"w", bare, "not a Git work tree"},
		{"w", filepath.Join(nonGit, "missing"), "missing"},
	} {
		_, why := call(t, h, "queue-add", input{Server: b, Workspace: tc.workspace, Branch: "other", Checkout: tc.checkout})
		if !strings.Contains(why, tc.want) {
			t.Errorf("add %s in %s: got %q, want %q", tc.workspace, tc.checkout, why, tc.want)
		}
	}
	if rows := queue("queue", input{Server: b}); len(rows) != 0 {
		t.Fatalf("refused entries were queued: %+v", rows)
	}
	queue("queue-add", input{Server: b, Workspace: "w", Branch: "other", Checkout: checkout})
	if rows := queue("queue-merge", input{Server: b, Workspace: "w"}); len(rows) != 1 || rows[0].Branch != "other" || rows[0].State != "merged" {
		t.Fatalf("second server merge: %+v", rows)
	}
	if pilotGit(t, checkout, "rev-parse", "release^2") != pilotGit(t, checkout, "rev-parse", "other") ||
		pilotGit(t, checkout, "rev-parse", "unrelated") != unrelated {
		t.Fatal("contribution did not land on the workspace base alone")
	}
	if rows := queue("queue", input{Server: a}); len(rows) != 1 || rows[0].Branch != "legacy" || rows[0].State != "queued" {
		t.Fatalf("first server queue: %+v", rows)
	}
	if _, msg := call(t, h, "queue", input{}); msg == "" {
		t.Fatal("ambiguous server accepted")
	}
	if rows := queue("queue-remove", input{Server: a, Workspace: "w", Branch: "legacy"}); len(rows) != 0 {
		t.Fatalf("remove stale queued entry: %+v", rows)
	}
	if rows := queue("queue", input{Server: b}); len(rows) != 1 {
		t.Fatalf("removal changed another server's queue: %+v", rows)
	}
	for _, other := range []input{{Server: b, Workspace: "pr", Branch: "other"}, {Server: b, Workspace: "w", Branch: "unrelated"}} {
		if rows := queue("queue-remove", other); len(rows) != 1 {
			t.Fatalf("removal ignored the workspace or branch: %+v", rows)
		}
	}
	if rows := queue("queue-remove", input{Server: b, Workspace: "w", Branch: "other"}); len(rows) != 0 {
		t.Fatalf("remove merged entry: %+v", rows)
	}
	queue("queue-add", input{Server: b, Workspace: "w", Branch: "other", Checkout: checkout})
	if err := os.Rename(checkout, filepath.Join(t.TempDir(), "moved")); err != nil {
		t.Fatal(err)
	}
	queue("queue-merge", input{Server: b, Workspace: "w"})
	if rows := queue("queue", input{Server: b}); len(rows) != 1 || rows[0].State != "failed" || !strings.Contains(rows[0].Output, checkout) {
		t.Fatalf("missing checkout at merge time: %+v", rows)
	}
}

func TestQueueMergeConflictAndFailedChecks(t *testing.T) {
	dir := queueTestRepo(t)
	commitFile := func(contents string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, "shared"), []byte(contents), 0600); err != nil {
			t.Fatal(err)
		}
		pilotGit(t, dir, "add", "shared")
		pilotGit(t, dir, "commit", "-qm", contents)
	}
	commitFile("base")
	pilotGit(t, dir, "switch", "-c", "topic")
	commitFile("topic")
	pilotGit(t, dir, "switch", "release")
	entry := queueEntry{Branch: "topic", Checkout: dir, Test: []string{"sh", "-c", "echo checks-failed; exit 1"}}
	base := pilotGit(t, dir, "rev-parse", "release")
	if state, out := mergeBranch(t.Context(), entry, "release"); state != "failed" || !strings.Contains(out, "checks-failed") {
		t.Fatalf("failed check: %s %q", state, out)
	}
	if pilotGit(t, dir, "rev-parse", "release") != base || pilotGit(t, dir, "status", "--porcelain") != "" {
		t.Fatal("failed checks changed base or left a dirty checkout")
	}
	commitFile("divergent")
	entry.Test = nil
	base = pilotGit(t, dir, "rev-parse", "release")
	if state, out := mergeBranch(t.Context(), entry, "release"); state != "conflict" || out == "" {
		t.Fatalf("merge conflict: %s %q", state, out)
	}
	if pilotGit(t, dir, "rev-parse", "release") != base || pilotGit(t, dir, "status", "--porcelain") != "" {
		t.Fatal("conflict changed base or left a dirty checkout")
	}
}

func TestQueueMigrationWithExistingServerFile(t *testing.T) {
	m := testManager(t)
	servers := []Server{{ID: "first", URL: "https://a.example.test"}, {ID: "second", URL: "https://b.example.test", Favorite: true}}
	if err := save(m.listPath(), map[string]any{"servers": servers}); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(m.cfg.Dir, "servers", "first")
	if err := privateDir(dir); err != nil {
		t.Fatal(err)
	}
	old := []queueEntry{{Branch: "old", State: "queued"}, {Branch: "shared", State: "queued"}}
	scoped := []queueEntry{{Branch: "shared", State: "merged"}, {Branch: "new", State: "queued"}}
	if err := save(filepath.Join(m.cfg.Dir, queueFile), old); err != nil {
		t.Fatal(err)
	}
	if err := save(filepath.Join(dir, queueFile), scoped); err != nil {
		t.Fatal(err)
	}
	reloaded, err := NewManager(t.Context(), m.cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer reloaded.Close()
	rows, err := readQueue(filepath.Join(dir, queueFile))
	if err != nil || len(rows) != 3 || rows[0].Branch != "old" || rows[1].State != "merged" || rows[2].Branch != "new" {
		t.Fatalf("merged migration: %+v, %v", rows, err)
	}
}

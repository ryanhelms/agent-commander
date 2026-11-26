package device

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/actions"
	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/devicekeys"
	"agentcommander.network/pilot/internal/testpilot"
)

// The test uses the tray's and coordinator's public request handlers. Its only
// substitute for a local Commander is the worker/actor Unix socket on each Mac.
type pilotPeer struct {
	handle, actor, worker, run, bearer string
	api                                http.Handler
	agent                              *Agent
	otherRun                           *pilotPeer
	turns                              atomic.Int32
}

func startPeer(t *testing.T, ctx context.Context, p *testpilot.Pilot, edge int, handle string, configureActions func(actions.Config) actions.Config) *pilotPeer {
	t.Helper()
	who := &pilotPeer{handle: handle, actor: handle + "-coordinator", worker: handle + "-assistant", run: handle + "-run", bearer: newID()}
	who.otherRun = &pilotPeer{handle: handle, actor: handle + "-other-worker", run: handle + "-other-run", bearer: newID()}
	socketDir, err := os.MkdirTemp("/tmp", "ac-peer-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(socketDir) })
	socket := filepath.Join(socketDir, "commander.sock")
	ln, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/network/coordinator", func(w http.ResponseWriter, r *http.Request) {
		for _, caller := range []*pilotPeer{who, who.otherRun} {
			if r.Header.Get("Authorization") == "Bearer "+caller.bearer && r.Header.Get("X-Commander-Worker") == caller.actor && r.Header.Get("X-Commander-Run") == caller.run {
				json.NewEncoder(w).Encode(map[string]string{"run": caller.run, "worker": caller.actor})
				return
			}
		}
		http.Error(w, "invalid actor", 403)
	})
	for _, coordinator := range []*pilotPeer{who, who.otherRun} {
		mux.HandleFunc("GET /v1/ag-ui/workers/"+coordinator.actor, func(w http.ResponseWriter, r *http.Request) {
			json.NewEncoder(w).Encode(map[string]any{"workerId": coordinator.actor, "role": "coordinator", "runId": coordinator.run, "runStatus": "running", "generation": 1})
		})
	}
	base := "/v1/ag-ui/workers/" + who.worker
	mux.HandleFunc("GET "+base, func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"workerId": who.worker, "role": "worker", "generation": 1})
	})
	mux.HandleFunc("POST "+base+"/run", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			RunID, ThreadID string
			ForwardedProps  struct{ Generation int }
			Messages        []struct{ Role, Content string }
		}
		if json.NewDecoder(r.Body).Decode(&in) != nil || r.Header.Get("Authorization") != "" || in.RunID == "" || in.ThreadID != who.worker || len(in.Messages) != 1 || in.Messages[0].Role != "user" || in.ForwardedProps.Generation != 1 || !strings.HasPrefix(in.Messages[0].Content, "[Shared operation ") {
			http.Error(w, "invalid local agent turn", 400)
			return
		}
		who.turns.Add(1)
		w.Header().Set("Content-Type", "text/event-stream")
		event := func(v any) { b, _ := json.Marshal(v); fmt.Fprintf(w, "data: %s\n\n", b) }
		event(map[string]any{"type": "STATE_SNAPSHOT", "snapshot": map[string]any{"workerId": who.worker, "operationId": "local-" + in.RunID, "operationStatus": "completed"}})
		event(map[string]any{"type": "MESSAGES_SNAPSHOT", "messages": []map[string]any{
			{"role": "user", "content": in.Messages[0].Content},
			{"role": "assistant", "content": "answer from " + handle},
			{"role": "system", "metadata": map[string]any{"acp": map[string]any{
				"source": "live", "kind": "acp.prompt_result", "turnId": "local-" + in.RunID,
				"turnTokens": map[string]int{"totalTokens": 7},
			}}},
		}})
		event(map[string]any{"type": "RUN_FINISHED", "runId": in.RunID})
	})
	server := &http.Server{Handler: mux}
	go server.Serve(ln)
	t.Cleanup(func() { server.Close() })
	dir := t.TempDir()
	secrets, err := devicekeys.Directory(filepath.Join(dir, "secrets"))
	if err != nil {
		t.Fatal(err)
	}
	issuerHTTP := p.OIDCHTTP()
	t.Cleanup(issuerHTTP.CloseIdleConnections)
	who.agent, err = New(ctx, Config{Relay: p.Edges[edge], Dir: filepath.Join(dir, "device"), CommanderSocket: socket, Roots: p.Roots, OpenBrowser: p.Browser(handle), Secrets: secrets, OIDCHTTP: issuerHTTP, configureActions: configureActions})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(who.agent.Close)
	who.api = who.agent.Handler()
	who.otherRun.api = who.api
	return who
}

func (p *pilotPeer) call(t *testing.T, ctx context.Context, path string, in any) (json.RawMessage, string) {
	t.Helper()
	b, err := json.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest("POST", path, bytes.NewReader(b)).WithContext(ctx)
	if strings.HasPrefix(path, "/coordinator/") {
		req.Header.Set("Authorization", "Bearer "+p.bearer)
		req.Header.Set("X-Commander-Worker", p.actor)
		req.Header.Set("X-Commander-Run", p.run)
	}
	rec := httptest.NewRecorder()
	p.api.ServeHTTP(rec, req)
	var out struct {
		OK    bool
		Data  json.RawMessage
		Error string
	}
	if json.Unmarshal(rec.Body.Bytes(), &out) != nil || out.OK != (rec.Code == 200) || (!out.OK && out.Error == "") {
		t.Fatalf("%s %s: malformed daemon reply %d %s", p.handle, path, rec.Code, rec.Body.String())
	}
	return out.Data, out.Error
}
func (p *pilotPeer) must(t *testing.T, ctx context.Context, path string, in, out any) {
	t.Helper()
	raw, why := p.call(t, ctx, path, in)
	if why != "" {
		t.Fatalf("%s %s: %s", p.handle, path, why)
	}
	if out != nil {
		if err := json.Unmarshal(raw, out); err != nil {
			t.Fatalf("%s %s: %v", p.handle, path, err)
		}
	}
}

type pilotState struct {
	Handle, Error        string
	Online, LoginPending bool
	Friends, Incoming    []struct {
		Handle string
		Online bool
	}
	Grants []trayGrant
}
type childOutcome struct {
	ID, Resource, Status string
	Result               map[string]any
}

func (p *pilotPeer) state(t *testing.T, ctx context.Context) pilotState {
	t.Helper()
	var s pilotState
	p.must(t, ctx, "/tray/status", input{}, &s)
	return s
}
func (p *pilotPeer) waitOnline(t *testing.T, ctx context.Context) {
	t.Helper()
	for {
		s := p.state(t, ctx)
		if s.Online && s.Handle == p.handle {
			return
		}
		if !s.LoginPending && s.Error != "" {
			t.Fatalf("%s login/connection failed: %s", p.handle, s.Error)
		}
		if !wait(ctx, 100*time.Millisecond) {
			t.Fatalf("%s remained offline", p.handle)
		}
	}
}
func (p *pilotPeer) completed(t *testing.T, ctx context.Context, id string, want int) map[string]childOutcome {
	t.Helper()
	for {
		var v struct {
			ID       string
			Children []childOutcome
		}
		p.must(t, ctx, "/coordinator/receipt", map[string]string{"id": id}, &v)
		if v.ID != id || len(v.Children) != want {
			t.Fatalf("incorrect operation/group size: %+v", v)
		}
		done := map[string]childOutcome{}
		for _, c := range v.Children {
			switch c.Status {
			case "pending", "processing":
				continue
			case "completed":
				if c.ID == "" || c.Result == nil {
					t.Fatalf("missing authenticated child outcome %+v", c)
				}
				done[c.Resource] = c
			default:
				t.Fatalf("unexpected child outcome %+v", c)
			}
		}
		if len(done) == want {
			return done
		}
		if !wait(ctx, 500*time.Millisecond) {
			t.Fatalf("waiting for %s: %v", id, v.Children)
		}
	}
}
func pilotGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-c", "core.hooksPath=/dev/null", "-c", "user.name=Pilot", "-c", "user.email=pilot@localhost"}, args...)...)
	cmd.Dir = dir
	cmd.Env = []string{"PATH=/usr/bin:/bin", "HOME=" + dir, "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null"}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v %s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func TestTwoDevicesCollaborateAcrossRelayEdges(t *testing.T) {
	runDevicePilot(t, nil, nil)
}

func runDevicePilot(t *testing.T, configureActions func(actions.Config) actions.Config, afterCommit func(context.Context, *pilotPeer, *pilotPeer, string, string)) {
	t.Helper()
	p := testpilot.Start(t)
	ctx, cancel := context.WithTimeout(t.Context(), 8*time.Minute)
	defer cancel()
	alice := startPeer(t, ctx, p, 0, "alice", nil)
	bob := startPeer(t, ctx, p, 1, "bob", configureActions)
	for _, who := range []*pilotPeer{alice, bob} {
		who.must(t, ctx, "/tray/login", input{Handle: who.handle}, nil)
	}
	alice.waitOnline(t, ctx)
	bob.waitOnline(t, ctx)
	t.Log("both devices signed in on different relay edges")
	var found control.User
	alice.must(t, ctx, "/tray/search", input{Handle: bob.handle}, &found)
	if found.Handle != bob.handle || found.Online {
		t.Fatalf("unexpected pre-friend discovery %+v", found)
	}
	alice.must(t, ctx, "/tray/request", input{Handle: bob.handle}, nil)
	if s := bob.state(t, ctx); len(s.Incoming) != 1 || s.Incoming[0].Handle != alice.handle {
		t.Fatalf("missing incoming request: %+v", s)
	}
	bob.must(t, ctx, "/tray/accept", input{Handle: alice.handle}, nil)
	for _, who := range []*pilotPeer{alice, bob} {
		if s := who.state(t, ctx); len(s.Friends) != 1 || !s.Friends[0].Online {
			t.Fatalf("missing online friend: %+v", s)
		}
	}

	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	pilotGit(t, dir, "init", "-b", "main")
	pilotGit(t, dir, "commit", "--allow-empty", "-qm", "initial")
	pilotGit(t, dir, "remote", "add", "origin", "https://github.com/example/fixture.git")
	base := pilotGit(t, dir, "rev-parse", "HEAD")
	for _, who := range []*pilotPeer{alice, bob} {
		who.must(t, ctx, "/tray/resource-add", input{ID: who.handle + "-agent", Name: who.handle + " assistant", Kind: "agent", Target: who.worker}, nil)
	}
	bob.must(t, ctx, "/tray/resource-add", input{ID: "bob-repo", Name: "Shared checkout", Kind: "repo", Target: dir}, nil)
	grant := func(owner, guest *pilotPeer, id, action string) {
		limit := 8
		if action == "git.head" {
			limit = 1
		}
		owner.must(t, ctx, "/tray/grant", input{Approval: "auto", Handle: guest.handle, Resource: id, Capability: action, ExpiresAt: time.Now().Add(time.Hour), MaxUses: limit}, nil)
	}
	grant(alice, bob, "alice-agent", "agent.ask")
	grant(bob, alice, "bob-agent", "agent.ask")
	grant(bob, alice, "bob-repo", "git.head")
	grant(bob, alice, "bob-repo", "git.commit")
	var catalog struct{ Resources []control.Resource }
	alice.must(t, ctx, "/coordinator/discover", struct{}{}, &catalog)
	if len(catalog.Resources) != 2 || !slices.ContainsFunc(catalog.Resources, func(r control.Resource) bool {
		return r.ID == "bob-repo" && r.Name == "Shared checkout" && r.Handle == "bob" && slices.Equal(r.Actions, []string{"git.commit", "git.head"})
	}) {
		t.Fatalf("granted resource discovery: %+v", catalog)
	}
	t.Log("both devices accepted friendship and advertised their granted resources")

	ask := json.RawMessage(`{"text":"Review the shared issue"}`)
	group := Submit{ID: "alice-first", Targets: []Target{{"bob-agent", "agent.ask", ask}, {"bob-repo", "git.head", json.RawMessage("{}")}}}
	alice.must(t, ctx, "/coordinator/submit", group, nil)
	got := alice.completed(t, ctx, group.ID, 2)
	if got["bob-agent"].Result["text"] != "answer from bob" || got["bob-repo"].Result["head"] != base {
		t.Fatalf("cross-relay result mismatch: %+v", got)
	}
	alice.must(t, ctx, "/coordinator/submit", group, nil)
	again := alice.completed(t, ctx, group.ID, 2)
	if again["bob-agent"].ID != got["bob-agent"].ID || bob.turns.Load() != 1 {
		t.Fatal("retry repeated the worker turn")
	}
	alice.otherRun.must(t, ctx, "/coordinator/discover", struct{}{}, nil)
	if _, why := alice.otherRun.call(t, ctx, "/coordinator/receipt", map[string]string{"id": group.ID}); why == "" {
		t.Fatal("another valid coordinator on the sender device could read the result")
	}

	s, err := alice.agent.getSession(ctx)
	if err != nil {
		t.Fatal(err)
	}
	records, err := filepath.Glob(filepath.Join(alice.agent.cfg.Dir, key(s.User), "submissions", "*.json"))
	if err != nil || len(records) != 1 {
		t.Fatal("expected one frozen outbound group", err)
	}
	b, err := os.ReadFile(records[0])
	var frozen sendRecord
	if err != nil || json.Unmarshal(b, &frozen) != nil || frozen.Wire.ID == "" {
		t.Fatal("cannot read frozen submission")
	}
	var wire control.Submission
	if err = alice.agent.remote(ctx, s, "GET", "/v1/submissions/"+frozen.Wire.ID, nil, &wire); err != nil {
		t.Fatal(err)
	}
	if len(wire.Children) != 2 {
		t.Fatalf("wrong relay fan-out: %d", len(wire.Children))
	}
	for _, c := range wire.Children {
		for _, raw := range []json.RawMessage{c.Envelope, c.Result} {
			var jwe string
			if json.Unmarshal(raw, &jwe) != nil || len(strings.Split(jwe, ".")) != 5 {
				t.Fatal("expected an opaque compact envelope on the relay")
			}
		}
	}

	_, why := alice.call(t, ctx, "/coordinator/submit", Submit{ID: "additional-head", Targets: []Target{{"bob-repo", "git.head", json.RawMessage("{}")}}})
	if why == "" {
		t.Fatal("an exhausted git.head grant authorized a new request")
	}

	reverse := Submit{ID: "bob-asks", Targets: []Target{{"alice-agent", "agent.ask", ask}}}
	bob.must(t, ctx, "/coordinator/submit", reverse, nil)
	if got := bob.completed(t, ctx, reverse.ID, 1); got["alice-agent"].Result["text"] != "answer from alice" || alice.turns.Load() != 1 {
		t.Fatalf("reverse grant failed: %+v", got)
	}

	content := "The cross-edge review is complete."
	change, _ := json.Marshal(map[string]any{"expectedHead": base, "message": "Record review", "files": map[string]string{"review.txt": content}})
	commit := Submit{ID: "alice-patch", Targets: []Target{{"bob-repo", "git.commit", change}}}
	alice.must(t, ctx, "/coordinator/submit", commit, nil)
	written := alice.completed(t, ctx, commit.ID, 1)["bob-repo"].Result
	revision, ok := written["head"].(string)
	if !ok || revision == base || pilotGit(t, dir, "show", revision+":review.txt") != content || pilotGit(t, dir, "rev-parse", "HEAD") != base {
		t.Fatalf("invalid collaboration commit %+v", written)
	}
	t.Log("cross-edge agent turns and Git commit returned authenticated receipts")
	if afterCommit != nil {
		afterCommit(ctx, alice, bob, revision, got["bob-repo"].Result["branch"].(string))
	}
	var gone string
	for _, g := range bob.state(t, ctx).Grants {
		if g.Resource == "bob-agent" && g.Capability == "agent.ask" {
			gone = g.ID
		}
	}
	if gone == "" {
		t.Fatal("grant missing from owner's tray")
	}
	bob.must(t, ctx, "/tray/revoke", input{ID: gone}, nil)
	alice.must(t, ctx, "/coordinator/discover", struct{}{}, &catalog)
	if len(catalog.Resources) != 1 || catalog.Resources[0].ID != "bob-repo" {
		t.Fatalf("revocation did not narrow discovery: %+v", catalog)
	}
	_, why = alice.call(t, ctx, "/coordinator/submit", Submit{ID: "after-revoke", Targets: []Target{{"bob-agent", "agent.ask", ask}}})
	if why == "" || bob.turns.Load() != 1 {
		t.Fatal("revoked capability executed")
	}
	alice.must(t, ctx, "/tray/unfriend", input{Handle: bob.handle}, nil)
	bob.must(t, ctx, "/tray/request", input{Handle: alice.handle}, nil)
	alice.must(t, ctx, "/tray/accept", input{Handle: bob.handle}, nil)
	grant(bob, alice, "bob-repo", "git.head")
	alice.must(t, ctx, "/coordinator/discover", struct{}{}, &catalog)
	if len(catalog.Resources) != 1 || catalog.Resources[0].ID != "bob-repo" || !slices.Equal(catalog.Resources[0].Actions, []string{"git.head"}) {
		t.Fatalf("friendship renewal silently restored capabilities: %+v", catalog)
	}
	for _, who := range []*pilotPeer{alice, bob} {
		who.must(t, ctx, "/tray/resource-add", input{ID: who.handle + "-inbox", Name: who.handle + " coordinator", Kind: "agent", Target: who.actor}, nil)
		who.must(t, ctx, "/tray/resource-add", input{ID: who.handle + "-other-inbox", Name: who.handle + " second coordinator", Kind: "agent", Target: who.otherRun.actor}, nil)
	}
	deliverNote := func(sender, receiver *pilotPeer, text string) {
		t.Helper()
		resource := receiver.handle + "-inbox"
		data, err := json.Marshal(map[string]string{"text": text})
		if err != nil {
			t.Fatal(err)
		}
		in := Submit{ID: sender.handle + "-note", Targets: []Target{{resource, "agent.message", data}}}
		if _, why := sender.call(t, ctx, "/coordinator/submit", in); why == "" {
			t.Fatal("peer sent a coordinator note before receiving a directional grant")
		}
		grant(receiver, sender, resource, "agent.message")
		sender.must(t, ctx, "/coordinator/submit", in, nil)
		out := sender.completed(t, ctx, in.ID, 1)[resource].Result
		messageID, ok := out["messageId"].(string)
		if !ok || messageID == "" {
			t.Fatalf("unidentified receipt: %+v", out)
		}
		var inbox struct {
			Messages []struct{ ID, Peer, Resource, Text string }
		}
		receiver.must(t, ctx, "/coordinator/inbox", struct{}{}, &inbox)
		if len(inbox.Messages) != 1 || inbox.Messages[0].ID != messageID || inbox.Messages[0].Text != text || inbox.Messages[0].Resource != resource || inbox.Messages[0].Peer == "" {
			t.Fatalf("wrong addressed inbox: %+v", inbox)
		}
		receiver.otherRun.must(t, ctx, "/coordinator/inbox", struct{}{}, &inbox)
		if len(inbox.Messages) != 0 {
			t.Fatal("unrelated live coordinator could read another coordinator's inbox")
		}
	}
	deliverNote(alice, bob, "Review is ready for your coordinator.")
	deliverNote(bob, alice, "Your review is complete.")
}

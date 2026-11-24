package main

import (
	"context"
	"encoding/json"
	"fmt"
	"maps"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"agentcommander/internal/linear"
	"agentcommander/internal/localapi"
	"agentcommander/internal/service"
	"agentcommander/internal/toolregistry"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const (
	linearTeamA = "7f6d8dee-b367-4a1f-8cbe-b0d0d6d8f250"
	linearTeamB = "33aa7d7a-a9bd-4134-b1cb-49b0d3742cf0"
	linearKeyA  = "linear-mcp-sentinel-first"
	linearKeyB  = "linear-mcp-sentinel-second"
)

type linearFixtureTransport struct {
	current  *url.URL
	base     http.RoundTripper
	attempts *atomic.Int32
}

func (t linearFixtureTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	t.attempts.Add(1)
	if req.URL.String() != "https://api.linear.app/graphql" {
		return nil, fmt.Errorf("unexpected upstream origin in Linear fixture")
	}
	forward := req.Clone(req.Context())
	forward.URL, forward.Host = t.current, t.current.Host
	return t.base.RoundTrip(forward)
}

func TestLinearLookupThroughAgentctlMCP(t *testing.T) {
	if os.Getenv("AGENT_COMMANDER_TEST_INTEGRATION") != "1" {
		t.Skip("requires disposable Unix sockets and an agentctl stdio subprocess")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 90*time.Second)
	defer cancel()
	var requests, attempts atomic.Int32
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		handleLinearFixture(t, w, r)
	}))
	defer upstream.Close()
	upstreamURL, err := url.Parse(upstream.URL + "/graphql")
	if err != nil {
		t.Fatal(err)
	}
	state, err := os.MkdirTemp("/tmp", "ac-linear-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(state) })
	binary, socket := filepath.Join(state, "agentctl"), filepath.Join(state, "s.sock")
	if out, err := exec.CommandContext(ctx, "go", "build", "-o", binary, ".").CombinedOutput(); err != nil {
		t.Fatalf("build agentctl: %v\n%s", err, out)
	}
	claudeProject := filepath.Join(t.TempDir(), "checkout")
	codexProject := filepath.Join(t.TempDir(), "checkout")
	ungranted := filepath.Join(t.TempDir(), "checkout")
	for _, project := range []string{claudeProject, codexProject, ungranted} {
		if err := os.Mkdir(project, 0700); err != nil {
			t.Fatal(err)
		}
	}
	credentials := filepath.Join(state, "linear-credentials")
	if err := os.Mkdir(credentials, 0700); err != nil {
		t.Fatal(err)
	}
	for name, key := range map[string]string{"first": linearKeyA, "second": linearKeyB} {
		if err := os.WriteFile(filepath.Join(credentials, name+".key"), []byte(key+"\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	linearGrant := func(credential, team string) map[string]any {
		return map[string]any{linear.IssueReadID: map[string]any{
			"version": 1, "settings": map[string]any{"credential": credential, "team_ids": []string{team}},
		}}
	}
	claudeTools := linearGrant("first", linearTeamA)
	claudeTools[fixtureWorkspaceReadID] = map[string]any{"version": 1, "settings": map[string]string{"label": "Fixture Alpha"}}
	grants, err := json.Marshal(map[string]any{"projects": []any{
		map[string]any{"path": claudeProject, "tools": claudeTools},
		map[string]any{"path": codexProject, "tools": linearGrant("second", linearTeamB)},
	}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(state, "tool-grants.json"), grants, 0600); err != nil {
		t.Fatal(err)
	}
	launches := make(captureLaunch, 3)
	var fixtureCalls atomic.Int32
	handler, err := service.New(state, launches, linear.IssueRead(state, linearFixtureTransport{
		current: upstreamURL, base: upstream.Client().Transport, attempts: &attempts,
	}), workspaceReadFixture(&fixtureCalls))
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	server := http.Server{Handler: handler}
	go server.Serve(listener)
	defer server.Close()
	owner := localapi.New(socket, "")
	launch := func(expectedID, expectedHarness string) service.LaunchSpec {
		t.Helper()
		select {
		case spec := <-launches:
			if spec.ID != expectedID || spec.Client != expectedHarness || spec.Token == "" {
				t.Fatal("unexpected launch identity")
			}
			return spec
		case <-ctx.Done():
			t.Fatal(ctx.Err())
			return service.LaunchSpec{}
		}
	}
	connect := func(spec service.LaunchSpec) *mcp.ClientSession {
		t.Helper()
		cmd := exec.CommandContext(ctx, binary, "mcp")
		cmd.Env = append(os.Environ(), "AGENT_COMMANDER_HOME="+state, "AGENT_COMMANDER_SOCKET="+socket,
			"AGENT_COMMANDER_RUN_ID="+spec.RunID, "AGENT_COMMANDER_WORKER_ID="+spec.ID,
			"AGENT_COMMANDER_TOKEN="+spec.Token, "AGENT_COMMANDER_ROLE=coordinator")
		assertNoLinearKey(t, strings.Join(cmd.Env, "\n"))
		client := mcp.NewClient(&mcp.Implementation{Name: "linear-cli-fixture", Version: "1"}, nil)
		session, err := client.Connect(ctx, &mcp.CommandTransport{Command: cmd}, nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { session.Close() })
		return session
	}
	coordinator := func(project, harness string) service.LaunchSpec {
		t.Helper()
		body, err := owner.Do(ctx, http.MethodPost, "/v1/runs", map[string]string{
			"path": project, "task": "Read one issue.", "client": harness,
		})
		if err != nil {
			t.Fatal(err)
		}
		var run service.Run
		if err := json.Unmarshal(body, &run); err != nil {
			t.Fatal(err)
		}
		return launch(run.CoordinatorID, harness)
	}
	lookup := func(session *mcp.ClientSession, id string) (json.RawMessage, error) {
		t.Helper()
		args, err := json.Marshal(map[string]string{"issue_id": id})
		if err != nil {
			t.Fatal(err)
		}
		return callMCP(ctx, session, "commander_call_tool", toolregistry.Invocation{
			ID: linear.IssueReadID, Version: 1, Arguments: args,
		})
	}
	list := func(session *mcp.ClientSession) []toolregistry.Descriptor {
		t.Helper()
		data, err := callMCP(ctx, session, "commander_list_tools", struct{}{})
		if err != nil {
			t.Fatal(err)
		}
		assertNoLinearKey(t, string(data))
		var discovery struct{ Tools []toolregistry.Descriptor }
		if err := json.Unmarshal(data, &discovery); err != nil {
			t.Fatal(err)
		}
		return discovery.Tools
	}
	claudeActor := coordinator(claudeProject, "claude")
	claude := connect(claudeActor)
	codex := connect(coordinator(codexProject, "codex"))
	other := connect(coordinator(ungranted, "claude"))
	if tools := list(other); len(tools) != 0 {
		t.Fatal("an ungranted project discovered a Linear tool")
	}
	for _, test := range []struct {
		session   *mcp.ClientSession
		id        string
		wantTools []string
	}{
		{claude, "eng-101", []string{fixtureWorkspaceReadID, linear.IssueReadID}},
		{codex, "APP-102", []string{linear.IssueReadID}},
	} {
		var names []string
		for _, tool := range list(test.session) {
			if tool.Version != 1 || tool.Action != toolregistry.Read {
				t.Fatalf("unexpected scoped descriptor: %+v", tool)
			}
			names = append(names, tool.ID)
		}
		if !slices.Equal(names, test.wantTools) {
			t.Fatalf("unexpected scoped discovery: %v", names)
		}
		raw, err := lookup(test.session, test.id)
		if err != nil {
			t.Fatal(err)
		}
		assertNoLinearKey(t, string(raw))
		var issue map[string]string
		id := strings.ToUpper(test.id)
		want := map[string]string{"identifier": id, "title": "Fixture issue " + id,
			"description": "Example description", "state": "In progress", "url": "https://linear.app/example/issue/" + id}
		if err := json.Unmarshal(raw, &issue); err != nil || !maps.Equal(issue, want) {
			t.Fatalf("unexpected issue projection: %s (%v)", raw, err)
		}
	}

	before := requests.Load()
	for _, test := range []struct {
		name    string
		session *mcp.ClientSession
		id      string
		code    string
	}{
		{"ungranted project", other, "ENG-101", "(403)"},
		{"invalid identifier", claude, "https://linear.app/example/issue/ENG-101", "(400)"},
	} {
		t.Run(test.name, func(t *testing.T) {
			assertLinearMCPError(t, test.code, func() (json.RawMessage, error) { return lookup(test.session, test.id) })
		})
	}
	assertLinearMCPError(t, "(400)", func() (json.RawMessage, error) {
		return callMCP(ctx, claude, "commander_call_tool", toolregistry.Invocation{
			ID: linear.IssueReadID, Version: 1, Arguments: json.RawMessage(`{"issue_id":"APP-102","team_ids":["33aa7d7a-a9bd-4134-b1cb-49b0d3742cf0"]}`),
		})
	})
	if requests.Load() != before {
		t.Fatal("denied request reached Linear")
	}
	for _, test := range []struct{ name, id, code string }{
		{"team denied with matching identifier", "ENG-403", "(404)"},
		{"missing issue", "ENG-404", "(404)"},
		{"HTTP rate limit", "ENG-429", "(429)"},
		{"GraphQL rate limit", "ENG-430", "(429)"},
		{"GraphQL partial failure", "ENG-500", "(502)"},
		{"redirect rejected", "ENG-302", "(502)"},
		{"timeout", "ENG-504", "(504)"},
	} {
		t.Run(test.name, func(t *testing.T) {
			assertLinearMCPError(t, test.code, func() (json.RawMessage, error) { return lookup(claude, test.id) })
		})
	}
	if got := requests.Load() - before; got != 7 {
		t.Fatalf("expected one request per upstream result, got %d", got)
	}
	if attempts.Load() != requests.Load() {
		t.Fatal("connector attempted a redirect outside the fixed endpoint")
	}
	before = requests.Load()
	if err := os.Remove(filepath.Join(credentials, "first.key")); err != nil {
		t.Fatal(err)
	}
	assertLinearMCPError(t, "(503)", func() (json.RawMessage, error) { return lookup(claude, "ENG-101") })
	if requests.Load() != before {
		t.Fatal("a missing credential still reached Linear")
	}

	t.Run("third_connector_registry_contract", func(t *testing.T) {
		invoke := func(session *mcp.ClientSession, args string) (json.RawMessage, error) {
			return callMCP(ctx, session, "commander_call_tool", toolregistry.Invocation{
				ID: fixtureWorkspaceReadID, Version: 1, Arguments: json.RawMessage(args),
			})
		}
		expectError := func(session *mcp.ClientSession, args, code string) {
			t.Helper()
			if data, err := invoke(session, args); err == nil || !strings.Contains(err.Error(), code) || len(data) != 0 {
				t.Fatalf("expected fixture MCP error %s, got %s (%v)", code, data, err)
			}
		}
		result, err := invoke(claude, `{"key":"label"}`)
		if err != nil || string(result) != `{"label":"Fixture Alpha"}` {
			t.Fatalf("project grant was not used: %s (%v)", result, err)
		}
		// A coordinator allowed to call Linear in the other checkout still
		// has no grant to invoke the fixture.
		expectError(codex, `{"key":"label"}`, "(403)")
		expectError(claude, `{"key":"label","label":"caller supplied"}`, "(400)")
		data, err := owner.Do(ctx, http.MethodPost, "/v1/runs/"+claudeActor.RunID+"/workers", map[string]string{
			"name": "Researcher", "task": "Check coordinator tool isolation.",
		})
		if err != nil {
			t.Fatal(err)
		}
		var worker service.Worker
		if err := json.Unmarshal(data, &worker); err != nil {
			t.Fatal(err)
		}
		// The bridge advertises coordinator tools based on its environment.
		// Only the service's authenticated actor can authorize use.
		spoofed := connect(launch(worker.ID, "claude"))
		if raw, err := callMCP(ctx, spoofed, "commander_list_tools", struct{}{}); err == nil ||
			!strings.Contains(err.Error(), "(403)") || len(raw) != 0 {
			t.Fatalf("worker spoofing its role could discover coordinator tools: %s (%v)", raw, err)
		}
		expectError(spoofed, `{"key":"label"}`, "(403)")
		if got := fixtureCalls.Load(); got != 1 {
			t.Fatalf("a denied request reached the fixture handler: %d calls", got)
		}
		expectError(claude, `{"key":"pending"}`, "(504)")
		if got := fixtureCalls.Load(); got != 2 {
			t.Fatalf("expected one additional invocation for the deadline check, got %d calls", got)
		}
		if requests.Load() != before {
			t.Fatal("fixture invocation reached the Linear adapter")
		}
	})
}

func assertNoLinearKey(t *testing.T, value string) {
	t.Helper()
	if strings.Contains(value, linearKeyA) || strings.Contains(value, linearKeyB) {
		t.Fatal("a service-held Linear credential escaped its upstream request")
	}
}

func assertLinearMCPError(t *testing.T, code string, call func() (json.RawMessage, error)) {
	t.Helper()
	result, err := call()
	if err != nil {
		assertNoLinearKey(t, err.Error())
	}
	if err == nil || !strings.Contains(err.Error(), code) || strings.Contains(err.Error(), "withheld-issue-title") || len(result) != 0 {
		t.Fatalf("expected sanitized MCP error %s", code)
	}
}

func handleLinearFixture(t *testing.T, w http.ResponseWriter, r *http.Request) {
	t.Helper()
	const query = `query CommanderReadIssue($id: ID!, $teams: [ID!]!) {
  issues(first: 2, includeArchived: true, filter: { id: { eq: $id }, team: { id: { in: $teams } } }) {
    nodes {
      identifier
      title
      description
      state { name }
      url
      team { id }
    }
  }
}`
	var request struct {
		Query     string
		Variables map[string]json.RawMessage
	}
	if r.Method != http.MethodPost || r.URL.Path != "/graphql" || r.Header.Get("Content-Type") != "application/json" ||
		json.NewDecoder(r.Body).Decode(&request) != nil || request.Query != query || len(request.Variables) != 2 {
		t.Error("connector did not send the fixed team-filtered read query")
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	var id string
	if json.Unmarshal(request.Variables["id"], &id) != nil {
		t.Error("connector did not send an issue identifier as a variable")
		return
	}
	wantKey, team := linearKeyA, linearTeamA
	if id == "APP-102" {
		wantKey, team = linearKeyB, linearTeamB
	}
	var teams []string
	if json.Unmarshal(request.Variables["teams"], &teams) != nil || len(teams) != 1 || teams[0] != team {
		t.Error("connector sent an upstream team filter from the wrong project")
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	if r.Header.Get("Authorization") != wantKey {
		t.Error("connector sent a credential from the wrong project")
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	title := "Fixture issue " + id
	switch id {
	case "ENG-101", "APP-102":
	case "ENG-403":
		team, title = linearTeamB, "withheld-issue-title"
	case "ENG-404":
		fmt.Fprint(w, `{"data":{"issues":{"nodes":[]}}}`)
		return
	case "ENG-429":
		w.WriteHeader(http.StatusTooManyRequests)
		fmt.Fprint(w, linearKeyA)
		return
	case "ENG-430":
		fmt.Fprint(w, `{"errors":[{"extensions":{"code":"RATELIMITED"}}]}`)
		return
	case "ENG-500":
		title = "withheld-issue-title"
	case "ENG-302":
		http.Redirect(w, r, "/redirected", http.StatusTemporaryRedirect)
		return
	case "ENG-504":
		<-r.Context().Done()
		return
	default:
		t.Errorf("unexpected Linear issue identifier %q", id)
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	node := map[string]any{
		"identifier": id, "title": title, "description": "Example description", "url": "https://linear.app/example/issue/" + id,
		"state": map[string]string{"name": "In progress"}, "team": map[string]string{"id": team},
		"internal": "must stay upstream",
	}
	result := map[string]any{"data": map[string]any{
		"issues": map[string]any{"nodes": []any{node}},
	}}
	if id == "ENG-500" {
		result["errors"] = []map[string]string{{"message": linearKeyA}}
	}
	_ = json.NewEncoder(w).Encode(result)
}

package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"agentcommander/internal/localapi"
	"agentcommander/internal/service"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestHostedCommandsRejectHTTP2DebugLogging(t *testing.T) {
	missingConfig := filepath.Join(t.TempDir(), "hosted.json")
	t.Setenv("AGENT_COMMANDER_HOSTED_CONFIG", missingConfig)
	for _, debug := range []string{"http2debug=1", "http2debug=0,http2debug=2"} {
		t.Setenv("GODEBUG", debug)
		_, hostedErr := prepareHosted(t.TempDir(), http.NotFoundHandler())
		relayErr := run([]string{"relay", missingConfig})
		checkErr := run([]string{"relay", "--check", missingConfig})
		for _, err := range []error{hostedErr, relayErr, checkErr} {
			if err == nil || !strings.Contains(err.Error(), "Go HTTP/2 debug logging disabled") {
				t.Fatalf("hosted startup with %s returned %v", debug, err)
			}
		}
	}
	t.Setenv("AGENT_COMMANDER_HOSTED_CONFIG", "")
	if _, err := prepareHosted(t.TempDir(), http.NotFoundHandler()); err != nil {
		t.Fatalf("socket-only service rejected runtime debugging: %v", err)
	}
	t.Setenv("GODEBUG", "http2debug=0")
	if err := run([]string{"relay", missingConfig}); !os.IsNotExist(err) {
		t.Fatalf("disabled tracing prevented relay config loading: %v", err)
	}
}

func TestRelayConfigurationCheck(t *testing.T) {
	dir := t.TempDir()
	public := httptest.NewTLSServer(http.NotFoundHandler())
	defer public.Close()
	cert := public.TLS.Certificates[0]
	key, err := x509.MarshalPKCS8PrivateKey(cert.PrivateKey)
	if err != nil {
		t.Fatal(err)
	}
	certPath, keyPath := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	for _, file := range []struct {
		path  string
		block pem.Block
	}{
		{certPath, pem.Block{Type: "CERTIFICATE", Bytes: cert.Certificate[0]}},
		{keyPath, pem.Block{Type: "PRIVATE KEY", Bytes: key}},
	} {
		if err := os.WriteFile(file.path, pem.EncodeToMemory(&file.block), 0600); err != nil {
			t.Fatal(err)
		}
	}

	configPath := filepath.Join(dir, "relay.json")
	check := func(changes map[string]any) error {
		t.Helper()
		config := map[string]any{
			"listen": public.Listener.Addr().String(), "tunnel_listen": "127.0.0.1:0", "metrics_listen": "[::1]:0",
			"certificate": certPath, "private_key": keyPath, "tunnel_certificate": certPath, "tunnel_private_key": keyPath,
			"instances": []any{},
		}
		for name, value := range changes {
			config[name] = value
		}
		payload, err := json.Marshal(config)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(configPath, payload, 0600); err != nil {
			t.Fatal(err)
		}
		return run([]string{"relay", "--check", configPath})
	}
	if err := check(nil); err != nil {
		t.Fatalf("validation must succeed without binding the occupied address: %v", err)
	}
	for _, test := range []struct {
		field string
		value any
		error string
	}{
		{"tunnel_listen", public.Listener.Addr().String(), "must be distinct"},
		{"listen", "127.0.0.1", "relay public address"},
		{"metrics_listen", "0.0.0.0:9109", "must use a loopback IP"},
		{"tunnel_private_key", certPath, "relay connector TLS key pair"},
		{"instances", nil, "configure an explicit array"},
	} {
		if err := check(map[string]any{test.field: test.value}); err == nil || !strings.Contains(err.Error(), test.error) {
			t.Errorf("%s: expected %q, got %v", test.field, test.error, err)
		}
	}
}

// Each managed actor gets a fresh instance of the actual agentctl MCP entry point.
// Exit before the Go test harness can write its PASS banner to the JSON-RPC pipe.
func TestMCPSubprocess(t *testing.T) {
	if os.Getenv("AGENT_COMMANDER_TEST_MCP_CHILD") != "1" {
		t.Skip("MCP test subprocess")
	}
	if err := run([]string{"mcp"}); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Exit(0)
}

type captureLaunch chan service.LaunchSpec

func (c captureLaunch) Launch(_ context.Context, spec service.LaunchSpec) error {
	c <- spec
	return nil
}
func (captureLaunch) Stop(context.Context, string) error { return nil }

func callMCP(ctx context.Context, session *mcp.ClientSession, name string, args any) (json.RawMessage, error) {
	reply, err := session.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		return nil, err
	}
	if len(reply.Content) != 1 {
		return nil, fmt.Errorf("%s returned %d content items", name, len(reply.Content))
	}
	text, ok := reply.Content[0].(*mcp.TextContent)
	if !ok || reply.IsError {
		return nil, fmt.Errorf("%s tool error: %v", name, reply.Content[0])
	}
	return json.RawMessage(text.Text), nil
}

func TestLocalMCPPlanningRun(t *testing.T) {
	if os.Getenv("AGENT_COMMANDER_TEST_INTEGRATION") != "1" {
		t.Skip("set AGENT_COMMANDER_TEST_INTEGRATION=1 for the Unix socket and stdio integration")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
	defer cancel()

	// Short path for the macOS sockaddr_un limit.
	dir, err := os.MkdirTemp("/tmp", "ac-mcp-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socket := filepath.Join(dir, "s.sock")
	launched := make(captureLaunch, 3)
	handler, err := service.New(dir, launched)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	pendingRead := make(chan struct{})
	var observed sync.Once
	var loseFrontendPoll atomic.Bool
	server := http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "GET" && strings.Contains(r.URL.Path, "/frontend-tools/calls/") && loseFrontendPoll.CompareAndSwap(true, false) {
			http.Error(w, "test transport unavailable", http.StatusServiceUnavailable)
			return
		}
		handler.ServeHTTP(w, r)
		if r.Method == "GET" && strings.Contains(r.URL.Path, "/questions/") {
			observed.Do(func() { close(pendingRead) })
		}
	})}
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })
	human := localapi.New(socket, "")

	humanCall := func(method, path string, in, out any) {
		t.Helper()
		data, err := human.Do(ctx, method, path, in)
		if err != nil {
			t.Fatal(err)
		}
		if out != nil {
			if err := json.Unmarshal(data, out); err != nil {
				t.Fatal(err)
			}
		}
	}
	credentials := make(map[string]string)
	connectActor := func(expectedID string) *mcp.ClientSession {
		t.Helper()
		var spec service.LaunchSpec
		select {
		case spec = <-launched:
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
		if spec.ID != expectedID || spec.Token == "" {
			t.Fatalf("missing binding for %s (got %s)", expectedID, spec.ID)
		}
		credentials[spec.ID] = spec.Token
		exe, err := os.Executable()
		if err != nil {
			t.Fatal(err)
		}
		cmd := exec.CommandContext(ctx, exe, "-test.run=^TestMCPSubprocess$")
		cmd.Env = append(os.Environ(), "AGENT_COMMANDER_TEST_MCP_CHILD=1", "AGENT_COMMANDER_HOME="+dir, "AGENT_COMMANDER_SOCKET="+socket,
			"AGENT_COMMANDER_WORKER_ID="+spec.ID, "AGENT_COMMANDER_RUN_ID="+spec.RunID, "AGENT_COMMANDER_TOKEN="+spec.Token)
		client := mcp.NewClient(&mcp.Implementation{Name: "commander-flow-test", Version: "1"}, nil)
		session, err := client.Connect(ctx, &mcp.CommandTransport{Command: cmd}, nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { session.Close() })
		return session
	}
	tool := func(actor *mcp.ClientSession, name string, args any, out any) {
		t.Helper()
		raw, err := callMCP(ctx, actor, name, args)
		if err != nil {
			t.Fatal(err)
		}
		if out != nil {
			if err := json.Unmarshal(raw, out); err != nil {
				t.Fatal(err)
			}
		}
	}

	var runInfo service.Run
	humanCall("POST", "/v1/runs", map[string]string{"task": "Plan a terminal feature", "path": dir, "client": "claude"}, &runInfo)
	coordinator := connectActor(runInfo.CoordinatorID)
	delegate := func(name string) (string, *mcp.ClientSession) {
		t.Helper()
		var worker service.Worker
		tool(coordinator, "commander_delegate", map[string]string{"name": name, "task": "Review " + name}, &worker)
		if worker.ParentID != runInfo.CoordinatorID {
			t.Fatalf("incorrect parent for %s", name)
		}
		return worker.ID, connectActor(worker.ID)
	}
	idA, workerA := delegate("Protocol")
	idB, workerB := delegate("Display")
	var questionA, questionB service.Question
	tool(workerA, "commander_ask", map[string]string{"question": "What literal input should we preserve?"}, &questionA)
	tool(workerB, "commander_ask", map[string]string{"question": "What terminal width?"}, &questionB)
	if questionA.WorkerID != idA || questionB.WorkerID != idB || questionA.ID == questionB.ID {
		t.Fatal("each question must be bound to its original worker")
	}

	type waitResult struct {
		data json.RawMessage
		err  error
	}
	waited := make(chan waitResult, 1)
	go func() {
		b, e := callMCP(ctx, workerA, "commander_wait", map[string]any{"request_id": questionA.ID, "timeout_seconds": 5})
		waited <- waitResult{b, e}
	}()
	select {
	case <-pendingRead:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	const literal = "Keep $HOME and 'quotes'\non two lines, including \"double quotes\"."
	humanCall("POST", "/v1/requests/"+questionA.ID+"/reply", map[string]string{"answer": literal}, nil)
	var received service.Question
	select {
	case result := <-waited:
		if result.err != nil {
			t.Fatal(result.err)
		}
		if err := json.Unmarshal(result.data, &received); err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	if received.ID != questionA.ID || received.WorkerID != idA || received.Status != "answered" || received.Answer != literal {
		t.Fatalf("wrong receipt: %+v", received)
	}

	finding := "Preserve this literal input: " + received.Answer
	tool(workerA, "commander_result", map[string]string{"result": finding}, nil)
	var status service.Run
	tool(coordinator, "commander_status", map[string]any{}, &status)
	if !slices.ContainsFunc(status.Workers, func(w *service.Worker) bool { return w.ID == idA && w.Result == finding }) {
		t.Fatal("coordinator did not receive the worker's finding")
	}
	if !slices.ContainsFunc(status.Requests, func(q *service.Question) bool {
		return q.ID == questionB.ID && q.WorkerID == idB && q.Status == "pending" && q.Answer == ""
	}) {
		t.Fatal("answering one question changed its sibling")
	}

	workerPath := "/v1/workers/" + idA
	workerAPI := localapi.New(socket, credentials[idA])
	for _, step := range []struct {
		path string
		body any
	}{
		{"/state", map[string]string{"state": "working"}},
		{"/control/ready", struct{}{}},
		{"/control/finish", map[string]string{"state": "completed"}},
	} {
		if _, err := workerAPI.Do(ctx, "POST", workerPath+step.path, step.body); err != nil {
			t.Fatal(err)
		}
	}
	humanCall("POST", workerPath+"/control", map[string]any{"held": true, "generation": 1}, nil)
	workerRunPath := "/v1/ag-ui/workers/" + idA
	body, err := json.Marshal(map[string]any{
		"threadId": idA, "runId": "frontend-test",
		"messages":       []any{map[string]string{"role": "user", "content": "Ask the app to pick a document"}},
		"forwardedProps": map[string]int{"generation": 2},
		"tools": []any{map[string]any{"name": "select_document", "description": "Select a document",
			"parameters": map[string]string{"type": "object"}}},
	})
	if err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequestWithContext(ctx, "POST", "http://localhost"+workerRunPath+"/run", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	httpClient := &http.Client{Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socket)
	}}}
	stream, err := httpClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Body.Close()
	if stream.StatusCode != 200 {
		t.Fatalf("frontend tool turn was not accepted: %s", stream.Status)
	}
	reader := bufio.NewScanner(stream.Body)
	await := func(eventType string) map[string]any {
		t.Helper()
		for reader.Scan() {
			data, ok := strings.CutPrefix(reader.Text(), "data: ")
			if !ok {
				continue
			}
			var event map[string]any
			if err := json.Unmarshal([]byte(data), &event); err != nil {
				t.Fatal(err)
			}
			if event["type"] == eventType {
				return event
			}
		}
		t.Fatalf("missing %s: %v", eventType, reader.Err())
		return nil
	}
	snapshot := await("STATE_SNAPSHOT")["snapshot"].(map[string]any)
	operation := snapshot["operationId"].(string)
	if _, err := workerAPI.Do(ctx, "POST", workerPath+"/messages/"+operation+"/claim", struct{}{}); err != nil {
		t.Fatal(err)
	}
	var definitions []struct{ Name string }
	tool(workerA, "commander_frontend_tools", struct{}{}, &definitions)
	if len(definitions) != 1 || definitions[0].Name != "select_document" {
		t.Fatalf("wrong frontend tools: %+v", definitions)
	}
	completed := make(chan waitResult, 1)
	go func() {
		out, err := callMCP(ctx, workerA, "commander_call_frontend", map[string]any{
			"name": "select_document", "arguments": map[string]any{"folder": "plans", "document": int64(9007199254740993)},
		})
		completed <- waitResult{out, err}
	}()
	arguments := await("TOOL_CALL_ARGS")["delta"].(string)
	var offered struct{ Document int64 }
	if err := json.Unmarshal([]byte(arguments), &offered); err != nil || offered.Document != 9007199254740993 {
		t.Fatalf("frontend tool did not preserve the exact document number: %s (%v)", arguments, err)
	}
	id := await("TOOL_CALL_END")["toolCallId"].(string)
	humanCall("POST", workerRunPath+"/operations/"+operation+"/tools/"+id+"/result", map[string]string{
		"id": "app-result", "role": "tool", "toolCallId": id, "content": "Selected plans.md",
	}, nil)
	select {
	case result := <-completed:
		if result.err != nil || string(result.data) != "Selected plans.md" {
			t.Fatalf("incorrect MCP result %q: %v", result.data, result.err)
		}
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	if event := await("TOOL_CALL_RESULT"); event["toolCallId"] != id || event["content"] != "Selected plans.md" {
		t.Fatalf("incorrect AG-UI tool result: %+v", event)
	}

	startPicker := func(callCtx context.Context) string {
		go func() {
			_, err := callMCP(callCtx, workerA, "commander_call_frontend", map[string]any{
				"name": "select_document", "arguments": map[string]string{"folder": "review"},
			})
			completed <- waitResult{err: err}
		}()
		return await("TOOL_CALL_END")["toolCallId"].(string)
	}
	pickerCtx, cancelPicker := context.WithCancel(ctx)
	defer cancelPicker()
	cancelledID := startPicker(pickerCtx)
	cancelPicker()
	select {
	case result := <-completed:
		if !errors.Is(result.err, context.Canceled) {
			t.Fatalf("MCP cancellation returned %v", result.err)
		}
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	if event := await("TOOL_CALL_RESULT"); event["toolCallId"] != cancelledID ||
		!strings.Contains(fmt.Sprint(event["error"]), "cancelled its wait") {
		t.Fatalf("missing cancellation for the awaiting call: %+v", event)
	}
	resultPath := workerRunPath + "/operations/" + operation + "/tools/"
	_, err = human.Do(ctx, "POST", resultPath+cancelledID+"/result", map[string]string{
		"id": "late-result", "role": "tool", "toolCallId": cancelledID, "content": "Late selection",
	})
	var refusal *localapi.ResponseError
	if !errors.As(err, &refusal) || refusal.StatusCode != http.StatusConflict {
		t.Fatalf("cancelled picker accepted a late result: %v", err)
	}

	loseFrontendPoll.Store(true)
	disconnectedID := startPicker(ctx)
	select {
	case result := <-completed:
		if result.err == nil || !strings.Contains(result.err.Error(), "result delivery is unconfirmed") {
			t.Fatalf("ambiguous poll failure reported %v", result.err)
		}
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	humanCall("POST", resultPath+disconnectedID+"/result", map[string]string{
		"id": "confirmed-result", "role": "tool", "toolCallId": disconnectedID, "content": "Confirmed by original app",
	}, nil)
	if event := await("TOOL_CALL_RESULT"); event["toolCallId"] != disconnectedID || event["content"] != "Confirmed by original app" {
		t.Fatalf("a poll failure lost the original app's evidence: %+v", event)
	}
	if os.Getenv("AGENT_COMMANDER_TEST_COPILOTKIT") == "1" {
		// Hand the real stream to two successive AG-UI client instances.
		_ = stream.Body.Close()
		cmd := exec.CommandContext(ctx, "node", "../../poc/agui-console/testdata/frontend-recovery.mjs", socket, idA, "frontend-test")
		firstDispatch, err := cmd.StdoutPipe()
		if err != nil {
			t.Fatal(err)
		}
		var diagnostics bytes.Buffer
		cmd.Stderr = &diagnostics
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		child := bufio.NewScanner(firstDispatch)
		if !child.Scan() || child.Text() != "ready" {
			_ = cmd.Wait()
			t.Fatalf("client did not attach: %s", diagnostics.String())
		}
		chosen, err := callMCP(ctx, workerA, "commander_call_frontend", map[string]any{
			"name": "select_document", "arguments": map[string]string{"folder": "reconnect"},
		})
		if err != nil || string(chosen) != "reconciled selection" {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
			t.Fatalf("MCP missed the original app result: %s, %v, %s", chosen, err, diagnostics.String())
		}
		if _, err := workerAPI.Do(ctx, "POST", workerPath+"/control/finish", map[string]string{"state": "completed", "message_id": operation}); err != nil {
			t.Fatal(err)
		}
		if err := cmd.Wait(); err != nil {
			t.Fatalf("AG-UI client recovery failed: %v, %s", err, diagnostics.String())
		}
	}
}

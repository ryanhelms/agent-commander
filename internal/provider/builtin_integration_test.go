package provider

import (
	"bytes"
	"context"
	"encoding/base64"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	agentacp "agent-acp.local/sdks/go"
	"agent-acp.local/sdks/go/conformance"
	pb "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"
	"agentcommander/harness"
	"agentcommander/internal/localapi"
	"agentcommander/internal/service"
	"google.golang.org/protobuf/encoding/protojson"
)

func TestRegisteredGoAdapterPassesSDKConformance(t *testing.T) {
	cwd := t.TempDir()
	if err := os.WriteFile(filepath.Join(cwd, "receipt.txt"), []byte(readerScenario.ToolResultMarker), 0600); err != nil {
		t.Fatal(err)
	}
	adapter, ok := harness.Lookup("fixture-reader")
	if !ok {
		t.Fatal("compiled adapter is missing from the registry")
	}
	if adapter.Instance() != compiledFixtureInstance {
		t.Fatalf("unexpected durable identity %q", adapter.Instance())
	}
	rt, err := adapter.Open(runtime.Config{HarnessInstance: adapter.Instance(), WorkingDirectory: cwd})
	if err != nil {
		t.Fatal(err)
	}
	defer rt.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	if err := conformance.Check(ctx, rt, conformance.Target{HarnessInstance: adapter.Instance(), WorkingDirectory: cwd}, readerScenario); err != nil {
		t.Fatal(err)
	}
}

func TestUnsupportedSDKAnswerDoesNotOpenACommanderRequest(t *testing.T) {
	cwd := t.TempDir()
	rt, err := compiledFixture.Open(runtime.Config{HarnessInstance: compiledFixtureInstance, WorkingDirectory: cwd})
	if err != nil {
		t.Fatal(err)
	}
	defer rt.Close()
	client := agentacp.New(rt)
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	session, err := client.Open(ctx, &pb.OpenRequest{HarnessInstance: compiledFixtureInstance, WorkingDirectory: cwd})
	if err != nil {
		t.Fatal(err)
	}
	request := &pb.SendRequest{Session: session.Session.Ref, OperationId: "only-observe", Text: readerScenario.Prompt}
	// This provider emits a permission despite explicitly advertising no way
	// to deliver answers. No Commander API is needed to surface the error.
	source := newACPSourcePublisher()
	watchCtx, stopWatch := context.WithCancel(ctx)
	updates, done, _ := workerObservations(watchCtx, client, request.Session, source, &screen{})
	defer func() { stopWatch(); <-done }()
	state, _, err := runACPTurn(ctx, client, request, source, nil, &screen{}, "", false, &pb.Capabilities{}, updates)
	if state != "failed" || err == nil || !strings.Contains(err.Error(), "without advertising support for answers") {
		t.Fatalf("unsupported provider input returned %s, %v", state, err)
	}
}

func TestCompiledGoAdapterWorkerAndColdHistory(t *testing.T) {
	if os.Getenv("AGENT_COMMANDER_TEST_TMUX") != "1" {
		t.Skip("set AGENT_COMMANDER_TEST_TMUX=1 to run the compiled adapter in isolated tmux")
	}
	if _, err := executablePath("tmux", "AGENT_COMMANDER_TMUX"); err != nil {
		t.Skip(err)
	}
	dir, err := os.MkdirTemp("/tmp", "ac-builtin-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	t.Setenv("TMUX_TMPDIR", dir)
	cwd := t.TempDir()
	if err := os.WriteFile(filepath.Join(cwd, "receipt.txt"), []byte(readerScenario.ToolResultMarker), 0600); err != nil {
		t.Fatal(err)
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(dir, "s.sock")
	open := func() (*Local, http.Handler) {
		t.Helper()
		local, err := New(dir, socket, exe)
		if err != nil {
			t.Fatal(err)
		}
		handler, err := service.New(dir, local)
		if err != nil {
			t.Fatal(err)
		}
		return local, handler
	}
	local, handler := open()
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: handler}
	go server.Serve(listener)
	t.Cleanup(func() { _ = server.Close() })
	client := &api{localapi.New(socket, "")}
	request := func(method, path string, body, out any) {
		t.Helper()
		if err := client.request(method, path, body, out); err != nil {
			t.Fatal(err)
		}
	}
	const selector = "builtin:fixture-reader"
	var run service.Run
	request("POST", "/v1/runs", map[string]string{"path": cwd, "task": readerScenario.Prompt, "client": selector}, &run)
	t.Cleanup(func() { _ = local.Stop(context.Background(), run.CoordinatorID) })
	path := "/v1/runs/" + run.ID
	var worker service.Worker
	request("POST", path+"/workers", map[string]string{"name": "Compiled file reader", "task": readerScenario.Prompt, "client": selector}, &worker)
	t.Cleanup(func() { _ = local.Stop(context.Background(), worker.ID) })
	await := func(id string, accept func(*service.Worker) bool) *service.Worker {
		t.Helper()
		for deadline := time.Now().Add(8 * time.Second); time.Now().Before(deadline); time.Sleep(25 * time.Millisecond) {
			request("GET", path, nil, &run)
			for _, w := range run.Workers {
				if w.State == "failed" {
					t.Fatalf("worker %s failed: %s\n%s", w.Name, w.Error, w.Output)
				}
				if w.ID == id && accept(w) {
					return w
				}
			}
		}
		t.Fatalf("timed out waiting for worker %s", id)
		return nil
	}
	reply := func(id string) {
		t.Helper()
		var questionID string
		await(id, func(_ *service.Worker) bool {
			for _, q := range run.Requests {
				if q.WorkerID == id && q.Status == "pending" && strings.HasPrefix(q.Question, readerScenario.PermissionPrompt) {
					questionID = q.ID
					return true
				}
			}
			return false
		})
		request("POST", "/v1/requests/"+questionID+"/reply", map[string]string{"answer": "once"}, nil)
	}

	reply(worker.ID)
	first := await(worker.ID, func(w *service.Worker) bool {
		return w.State == "completed" && w.Control != nil && w.NativeSession != nil
	})
	ref := *first.NativeSession
	if ref.HarnessInstance != compiledFixtureInstance || ref.SessionID == "" {
		t.Fatalf("wrong compiled runtime binding: %+v", ref)
	}
	var info struct{ SessionCapabilities *service.SessionCapabilities }
	request("GET", "/v1/ag-ui/workers/"+worker.ID, nil, &info)
	if info.SessionCapabilities == nil || !info.SessionCapabilities.CanInterrupt || !info.SessionCapabilities.CanAnswer || !info.SessionCapabilities.CanReadHistory || info.SessionCapabilities.CanResume {
		t.Fatalf("compiled adapter's negotiated operations were lost: %+v", info.SessionCapabilities)
	}
	control := "/v1/workers/" + worker.ID + "/control"
	var lease service.WorkerControl
	request("POST", control, map[string]any{"held": true, "generation": first.Control.Generation}, &lease)
	reply(run.CoordinatorID)
	coordinator := await(run.CoordinatorID, func(w *service.Worker) bool { return w.State == "completed" })
	otherSession := coordinator.NativeSession.SessionID
	var followup service.WorkerFollowUp
	const literal = "  Read again\nwith $HOME and quotes.  "
	request("POST", "/v1/workers/"+worker.ID+"/messages", map[string]any{"text": literal, "generation": lease.Generation}, &followup)
	reply(worker.ID)
	result := await(worker.ID, func(w *service.Worker) bool {
		return w.State == "completed" && slices.ContainsFunc(w.Console, func(event service.ConsoleEvent) bool {
			return event.Kind == "tool_result" && event.ToolID == "read-"+followup.ID && strings.Contains(event.Text, readerScenario.ToolResultMarker)
		})
	})
	if *result.NativeSession != ref || !result.Control.Held || !slices.ContainsFunc(result.Console, func(e service.ConsoleEvent) bool { return e.Kind == "user" && e.Text == literal }) {
		t.Fatalf("held follow-up lost its native session, owner or literal input: %+v", result)
	}
	assertCompiledLiveSource(t, client, result, followup.ID, literal)
	request("POST", control, map[string]any{"held": false, "generation": lease.Generation}, nil)
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}

	// A new service and provider read the adapter's own on-disk artifact using
	// only the persisted worker binding, after the old HTTP server is gone.
	_, restored := open()
	history := httptest.NewRecorder()
	restored.ServeHTTP(history, httptest.NewRequest("GET", "/v1/workers/"+worker.ID+"/history?limit=1", nil))
	var page pb.ReadHistoryResponse
	if history.Code != http.StatusOK || protojson.Unmarshal(history.Body.Bytes(), &page) != nil || len(page.Observations) != 1 {
		t.Fatalf("invalid cold history: %d %s", history.Code, history.Body.String())
	}
	record := page.Observations[0]
	if record.GetSession().GetHarnessInstance() != ref.HarnessInstance || record.GetSession().GetSessionId() != ref.SessionID ||
		record.TurnId != followup.ID || record.GetTool().GetCallId() != "read-"+followup.ID || record.GetTool().GetSummary() != readerScenario.ToolResultMarker {
		t.Fatalf("history did not restore this worker's actual receipt: %v", record)
	}

	// Simulate a provider lookup bug. Its record for the coordinator must
	// never be delivered through the worker's otherwise valid history grant.
	foreign, err := os.ReadFile(filepath.Join(cwd, otherSession+".pb"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cwd, ref.SessionID+".pb"), foreign, 0600); err != nil {
		t.Fatal(err)
	}
	crossed := httptest.NewRecorder()
	restored.ServeHTTP(crossed, httptest.NewRequest("GET", "/v1/workers/"+worker.ID+"/history", nil))
	if crossed.Code != http.StatusServiceUnavailable || strings.Contains(crossed.Body.String(), otherSession) || strings.Contains(crossed.Body.String(), readerScenario.ToolResultMarker) {
		t.Fatalf("crossed provider history did not fail closed: %d %s", crossed.Code, crossed.Body.String())
	}
}

func assertCompiledLiveSource(t *testing.T, client *api, worker *service.Worker, operation, prompt string) {
	t.Helper()
	var toolCursor, mediaCursor string
	for _, event := range worker.Console {
		if event.ACP == nil || event.ACP.Source != "live" || event.ACP.Kind != service.LiveObservationKind || event.ACP.TurnID != operation {
			continue
		}
		if event.ToolID == "read-"+operation && event.Kind == "tool_result" {
			toolCursor = event.ACP.Cursor
		}
		if strings.Contains(event.Text, readerScenario.ExtensionType) {
			mediaCursor = event.ACP.Cursor
		}
	}
	if toolCursor == "" || mediaCursor == "" || strings.Contains(worker.Output, base64.StdEncoding.EncodeToString(readerMedia[:84])) {
		t.Fatal("tool or opaque event lost its scoped source link, or the payload escaped into the shared console")
	}
	path := "/v1/workers/" + worker.ID + "/history?source=live&turnId=" + operation
	for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); time.Sleep(25 * time.Millisecond) {
		raw, err := client.client.Do(t.Context(), "GET", path, nil)
		if err != nil {
			t.Fatal(err)
		}
		var page pb.ReadHistoryResponse
		if err := protojson.Unmarshal(raw, &page); err != nil {
			t.Fatal(err)
		}
		var foundText, foundTool, foundMedia bool
		for _, item := range page.Observations {
			ext := item.GetExtension()
			if ext.GetType() != service.LiveObservationKind {
				continue
			}
			if ext.MediaType != "application/json" || item.TurnId != operation {
				t.Fatalf("invalid scoped source envelope: %s %q", ext.MediaType, item.TurnId)
			}
			var original pb.Observation
			if err := protojson.Unmarshal(ext.Data, &original); err != nil {
				t.Fatal(err)
			}
			if original.GetSession().GetHarnessInstance() != worker.NativeSession.HarnessInstance || original.GetSession().GetSessionId() != worker.NativeSession.SessionID || original.TurnId != operation || original.Cursor == "" {
				t.Fatal("portable source did not retain the worker, native cursor and turn identity")
			}
			foundText = foundText || (original.GetText().GetSpeaker() == pb.Speaker_SPEAKER_USER && original.GetText().GetText() == prompt)
			foundTool = foundTool || (item.Cursor == toolCursor && original.GetTool().GetCallId() == "read-"+operation && original.GetTool().GetSummary() == readerScenario.ToolResultMarker)
			media := original.GetExtension()
			foundMedia = foundMedia || (item.Cursor == mediaCursor && media.GetType() == readerScenario.ExtensionType && media.GetMediaType() == "application/octet-stream" && bytes.Equal(media.GetData(), readerMedia))
		}
		if foundText && foundTool && foundMedia {
			return
		}
	}
	t.Fatal("scoped SDK source lost the literal prompt, linked tool result or exact opaque bytes")
}

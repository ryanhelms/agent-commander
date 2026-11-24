package service

import (
	"bufio"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"agentcommander/internal/acpprocessor"
)

func TestFoldedToolKeepsEverySourceReference(t *testing.T) {
	call := acpprocessor.Reference("live", "1", "tool_call", "")
	progress := acpprocessor.Reference("live", "2", "tool_call_update", "")
	result := acpprocessor.Reference("live", "3", "tool_call_update", "")
	more := acpprocessor.Reference("provider", "3", "tool_call_update", "")
	messages := aguiMessages("w", []ConsoleEvent{
		{Kind: "tool_call", ToolID: "t", Name: "Read", ACP: call},
		{Kind: "tool_update", ToolID: "t", ACP: progress},
		{Kind: "tool_result", ToolID: "t", Text: "first", ACP: result},
		{Kind: "tool_result", ToolID: "t", Text: "second", ACP: more},
		{Kind: "tool_update", ToolID: "t", ACP: progress},
		{Kind: "text", Text: "done", ACP: call},
	})
	if len(messages) != 3 || !reflect.DeepEqual(messages[0].Metadata, &aguiMessageMetadata{
		ACP: progress, ACPSources: []*acpprocessor.Activity{call, progress},
	}) || !reflect.DeepEqual(messages[1].Metadata, &aguiMessageMetadata{
		ACP: more, ACPSources: []*acpprocessor.Activity{result, more},
	}) || !reflect.DeepEqual(messages[2].Metadata, &aguiMessageMetadata{ACP: call}) {
		t.Fatalf("incorrect source references for folded tool calls and results: %#v", messages)
	}
}

func TestAGUIWorkspaceStream(t *testing.T) {
	f := newFixture(t)
	coordinator := f.run()
	worker := f.delegate(coordinator, "review")
	const streamPath = "/v1/ag-ui/events"
	f.call("GET", streamPath, worker.Token, nil, 403, "")

	server := httptest.NewServer(f.api)
	defer server.Close()
	client := http.Client{Timeout: 5 * time.Second}
	open := func() *http.Response {
		t.Helper()
		response, err := client.Get(server.URL + streamPath)
		if err != nil {
			t.Fatal(err)
		}
		if response.StatusCode != 200 || response.Header.Get("Content-Type") != "text/event-stream" {
			_ = response.Body.Close()
			t.Fatalf("unexpected stream response: %v", response.Status)
		}
		return response
	}
	type update struct {
		Type     string
		Snapshot *aguiWorkspace
		Delta    []struct {
			Op, Path string
			Value    json.RawMessage
		}
	}
	reader := func(body io.Reader) func() update {
		scanner := bufio.NewScanner(body)
		scanner.Buffer(make([]byte, 16<<10), 4<<20)
		return func() update {
			t.Helper()
			for scanner.Scan() {
				raw, ok := strings.CutPrefix(scanner.Text(), "data: ")
				if !ok {
					continue
				}
				var event update
				if err := json.Unmarshal([]byte(raw), &event); err != nil {
					t.Fatal(err)
				}
				return event
			}
			t.Fatalf("stream ended before next event: %v", scanner.Err())
			return update{}
		}
	}
	decodeRun := func(raw json.RawMessage) aguiRun {
		t.Helper()
		var run aguiRun
		if err := json.Unmarshal(raw, &run); err != nil {
			t.Fatal(err)
		}
		return run
	}

	first := open()
	defer first.Body.Close()
	next := reader(first.Body)
	initial := next()
	if initial.Type != "STATE_SNAPSHOT" || initial.Snapshot == nil || len(initial.Snapshot.Runs) != 1 {
		t.Fatalf("wrong initial event: %+v", initial)
	}
	starting := decodeRun(initial.Snapshot.Runs[0])
	if len(starting.Workers) != 2 || starting.Workers[0].ID != coordinator.ID ||
		starting.Workers[1].ID != worker.ID || len(starting.Workers[1].Messages) != 0 {
		t.Fatalf("wrong initial worker state: %+v", starting.Workers)
	}
	changedRun := func() aguiRun {
		t.Helper()
		event := next()
		if event.Type != "STATE_DELTA" || len(event.Delta) != 1 || event.Delta[0].Op != "replace" ||
			event.Delta[0].Path != "/runs/0" {
			t.Fatalf("wrong patch: %+v", event)
		}
		return decodeRun(event.Delta[0].Value)
	}

	path := "/v1/workers/" + worker.ID
	f.call("POST", path+"/output", worker.Token, map[string]any{"text": "Reading console.md\n", "events": []ConsoleEvent{
		{Kind: "text", Text: "Reading console.md"},
		{Kind: "tool_result", ToolID: "missing-call", Text: "out of window"},
		{Kind: "tool_call", ToolID: "read-1", Name: "Read", Text: "console.md"},
		{Kind: "tool_result", ToolID: "read-1", Text: "Fictional label"},
		{Kind: "output", Text: "[Provider stderr] sample diagnostic"},
	}}, 200, "")
	output := changedRun()
	messages := output.Workers[1].Messages
	if len(output.Workers[0].Messages) != 0 || len(output.Workers[1].Console) != 0 ||
		len(messages) != 5 || messages[0].Role != "assistant" || messages[3].Role != "tool" ||
		messages[4].Role != "system" || messages[4].Content == nil || *messages[4].Content != "[Provider stderr] sample diagnostic" {
		t.Fatalf("unexpected projection: %+v", output.Workers)
	}
	if messages[1].Role != "tool" || messages[1].ToolCallID != worker.ID+":missing-call" || messages[1].Content == nil ||
		*messages[1].Content != "out of window" {
		t.Fatalf("lost orphan result: %+v", messages)
	}
	if len(messages[2].ToolCalls) != 1 || messages[3].Content == nil {
		t.Fatalf("missing tool call or result: %+v", messages)
	}
	call := messages[2].ToolCalls[0]
	if messages[0].ID != worker.ID+":1" || call.Function.Arguments != "{\"detail\":\"console.md\"}" ||
		messages[3].ToolCallID != call.ID || *messages[3].Content != "Fictional label" {
		t.Fatalf("lost tool correlation: %+v", messages)
	}
	runPath := "/v1/runs/" + coordinator.RunID
	polled := decodeRun(f.call("GET", runPath+"?view=ag-ui", "", nil, 200, ""))
	if len(polled.Workers[1].Console) != 0 || !reflect.DeepEqual(polled.Workers[1].Messages, messages) {
		t.Fatalf("polled AG-UI view diverged from live projection: %+v", polled.Workers[1])
	}
	ordinary := decodeRun(f.call("GET", runPath, "", nil, 200, ""))
	if len(ordinary.Workers[1].Console) != 5 || len(ordinary.Workers[1].Messages) != 0 {
		t.Fatal("ordinary run endpoint stopped returning the original console records")
	}

	var question Question
	if err := json.Unmarshal(f.call("POST", path+"/questions", worker.Token,
		map[string]string{"question": "What is the label?"}, 201, ""), &question); err != nil {
		t.Fatal(err)
	}
	waiting := changedRun()
	if len(waiting.Requests) != 1 || waiting.Requests[0].ID != question.ID || waiting.Requests[0].Status != "pending" {
		t.Fatalf("unexpected pending requests: %+v", waiting.Requests)
	}
	answer := "Nacre $7 \"Dusk\"\nlane beta"
	f.call("POST", "/v1/requests/"+question.ID+"/reply", "", map[string]string{"answer": answer}, 200, "reply-1")
	resolved := changedRun()
	if resolved.Requests[0].Status != "answered" || resolved.Requests[0].Answer != answer {
		t.Fatalf("unexpected answer: %+v", resolved.Requests[0])
	}

	another := f.run()
	added := next()
	if added.Type != "STATE_DELTA" || len(added.Delta) != 1 || added.Delta[0].Path != "/runs" {
		t.Fatalf("run creation did not replace the list: %+v", added)
	}
	reconnected := open()
	defer reconnected.Body.Close()
	snapshot := reader(reconnected.Body)()
	if snapshot.Type != "STATE_SNAPSHOT" || snapshot.Snapshot == nil || len(snapshot.Snapshot.Runs) != 2 ||
		decodeRun(snapshot.Snapshot.Runs[0]).Requests[0].Answer != answer ||
		decodeRun(snapshot.Snapshot.Runs[1]).ID != another.RunID {
		t.Fatalf("reconnect lost committed updates: %+v", snapshot)
	}
}

func TestAGUITranscriptFixturePreservesProgressAndResultIdentity(t *testing.T) {
	data, err := os.ReadFile("../../design/verification/transcript-coverage/console-events.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture []ConsoleEvent
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	first := aguiMessages("first-worker", fixture)
	second := aguiMessages("second-worker", fixture)
	if len(first) != 7 || len(second) != len(first) {
		t.Fatalf("wrong message count: %d, %d", len(first), len(second))
	}
	if *first[0].Content != *first[1].Content || first[0].ID == first[1].ID {
		t.Fatal("repeated text did not retain its separate identities")
	}
	if first[2].ToolCallID != "first-worker:orphan" || *first[2].Content != "Result whose call left the preview." {
		t.Fatalf("orphan result was lost: %+v", first[2])
	}
	call := first[3].ToolCalls[0]
	var arguments struct {
		Detail string `json:"detail"`
	}
	if err := json.Unmarshal([]byte(call.Function.Arguments), &arguments); err != nil {
		t.Fatal(err)
	}
	if call.ID == second[3].ToolCalls[0].ID || call.Function.Name != "Read file" ||
		arguments.Detail != "sample.txt\nRead first chunk.\nRead next chunk." {
		t.Fatalf("tool progress or worker identity was lost: %+v", call)
	}
	if fixture[3].TerminalText() != "→ Read fixture [pending]\nsample.txt" ||
		fixture[4].TerminalText() != "Tool read-1 [in_progress]\nRead first chunk." {
		t.Fatal("chronological console lost the original tool phases")
	}
	result := first[4]
	if result.ToolCallID != call.ID || result.Error != "Tool failed." ||
		*result.Content != "Part one\nTool failed.\nPart two: fixture://plan" {
		t.Fatalf("tool result was incomplete: %+v", result)
	}
	if !strings.Contains(*first[5].Content, "AAE=") || *first[6].Content != "Retained conversation source expired." {
		t.Fatal("opaque content or explicit gap was lost")
	}
}

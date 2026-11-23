package service

import (
	"bufio"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

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
	}}, 200, "")
	output := changedRun()
	messages := output.Workers[1].Messages
	if len(output.Workers[0].Messages) != 0 || len(output.Workers[1].Console) != 0 ||
		len(messages) != 3 || messages[0].Role != "assistant" || messages[2].Role != "tool" {
		t.Fatalf("unexpected projection: %+v", output.Workers)
	}
	if len(messages[1].ToolCalls) != 1 || messages[2].Content == nil {
		t.Fatalf("missing tool call or result: %+v", messages)
	}
	call := messages[1].ToolCalls[0]
	if messages[0].ID != worker.ID+":1" || call.Function.Arguments != "{\"detail\":\"console.md\"}" ||
		messages[2].ToolCallID != call.ID || *messages[2].Content != "Fictional label" {
		t.Fatalf("lost tool correlation: %+v", messages)
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

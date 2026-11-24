package service

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"

	"agentcommander/internal/acpprocessor"
)

func TestOperationFramesBoundRollingTextAndRebaseCorrections(t *testing.T) {
	p := operationMessageStream{}
	messages := func(start, stop int) []aguiMessage {
		rows := make([]aguiMessage, 0, stop-start)
		for i := start; i < stop; i++ {
			text := fmt.Sprintf("chunk:%d", i)
			rows = append(rows, aguiMessage{sequence: i, ID: fmt.Sprintf("w:%d", i), Role: "assistant", Content: &text,
				Metadata: &aguiMessageMetadata{ACP: acpprocessor.Reference("live", fmt.Sprint(i), "agent_message_chunk", "")}})
		}
		return rows
	}
	window := messages(1, consoleEventWindow+1)
	frame := func(rows []aguiMessage, active bool) []byte {
		t.Helper()
		wire, err := p.frame(rows, true, active)
		if err != nil {
			t.Fatal(err)
		}
		return wire
	}
	checkSnapshot := func(wire []byte, rows []aguiMessage) {
		t.Helper()
		var event struct {
			Type     string
			Messages []aguiMessage
		}
		payload := bytes.TrimSpace(bytes.TrimPrefix(wire, []byte("data: ")))
		if err := json.Unmarshal(payload, &event); err != nil || event.Type != "MESSAGES_SNAPSHOT" ||
			!slices.EqualFunc(rows, event.Messages, equalMessage) {
			t.Fatalf("snapshot did not match %d canonical messages: %v", len(rows), err)
		}
	}
	checkSnapshot(frame(window, true), window)
	for n := 1; n <= consoleEventWindow+1; n++ {
		window = messages(1+n, consoleEventWindow+1+n)
		wire := frame(window, true)
		if n == consoleEventWindow+1 {
			checkSnapshot(wire, window)
		} else if bytes.Count(wire, []byte("data: ")) != 3 || !bytes.Contains(wire, []byte("TEXT_MESSAGE_START")) ||
			!bytes.Contains(wire, []byte(*window[len(window)-1].Content)) {
			t.Fatal("rolling text did not emit the newly observed message")
		}
	}
	window = messages(consoleEventWindow+3, 2*consoleEventWindow+3)
	frame(window, true)
	if wire := frame(window, true); len(wire) != 0 {
		t.Fatal("unmodified window was retransmitted")
	}
	checkSnapshot(frame(window, false), window)
	correction := "corrected provider text"
	window = slices.Clone(window)
	window[0].Content = &correction
	checkSnapshot(frame(window, true), window)
	ordinary := aguiMessage{ID: "ordinary", Role: "assistant", ToolCalls: []aguiToolCall{{ID: "read", Type: "function", Function: aguiFunction{Name: "Read", Arguments: "{}"}}}}
	window = append(window, ordinary)
	checkSnapshot(frame(window, true), window)
}

func TestOperationConsoleDetectsSkippedAndReplacedSource(t *testing.T) {
	p := operationConsole{}
	initial := []ConsoleEvent{{Sequence: 10, Kind: "text", Text: "a"}, {Sequence: 11, Kind: "text", Text: "b"}}
	p.checkContinuity(initial)
	p.project("w", initial)
	if !strings.Contains(p.notice, "Earlier output") {
		t.Fatal("opening an evicted preview hid its gap")
	}
	window := []ConsoleEvent{{Sequence: 15, Kind: "text", Text: "later"}}
	p.checkContinuity(window)
	view := p.project("w", window)
	if !strings.Contains(p.notice, "12 through 14") || len(view) != 1 || *view[0].Content != "later" {
		t.Fatal("missing live interval or wrong view")
	}
	replaced := []ConsoleEvent{{Sequence: 15, Kind: "text", Text: "restored"}}
	view = p.project("w", replaced)
	if *view[0].Content != "restored" {
		t.Fatal("reused stale text after provider history replaced the same sequence")
	}
}

func TestOperationQuestionDeltaKeepsUnchangedRequests(t *testing.T) {
	a := Question{ID: "first", Status: "pending"}
	b := Question{ID: "second", Status: "pending", Question: "unchanged"}
	answered := a
	answered.Status, answered.Answer = "answered", "decision"
	old := aguiRunState{Status: "waiting", PendingRequests: []Question{a, b}, Requests: []Question{a, b}}
	next := aguiRunState{Status: "working", PendingRequests: []Question{b}, Requests: []Question{answered, b}}
	ops := operationStateDelta(old, next)
	data, err := json.Marshal(ops)
	if err != nil || len(ops) != 3 || ops[0].Path != "/status" || ops[1].Op != "remove" || ops[1].Path != "/pendingRequests/0" ||
		ops[2].Op != "replace" || ops[2].Path != "/requests/0" || bytes.Contains(data, []byte("unchanged")) {
		t.Fatalf("unexpected reply patches: %s (%v)", data, err)
	}
}

type steppedWorkerStream struct {
	*httptest.ResponseRecorder
	advance func(string)
}

func (w *steppedWorkerStream) Flush() {
	w.ResponseRecorder.Flush()
	w.advance(w.Body.String())
}

func TestSlowOperationObserverReportsExactMissedInterval(t *testing.T) {
	f := newFixture(t)
	worker := f.delegate(f.run(), "busy")
	path := "/v1/workers/" + worker.ID
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", path+"/control/ready", worker.Token, struct{}{}, 200, "")
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed"}, 200, "")
	f.call("POST", path+"/control", "", map[string]any{"held": true, "generation": 1}, 200, "")
	f.call("POST", path+"/output", worker.Token, map[string]any{"events": []ConsoleEvent{{Kind: "text", Text: "first"}}}, 200, "")
	stream := &steppedWorkerStream{ResponseRecorder: httptest.NewRecorder()}
	var advanced bool
	stream.advance = func(wire string) {
		if advanced || !strings.Contains(wire, "MESSAGES_SNAPSHOT") {
			return
		}
		advanced = true
		var feed workerControlFeed
		if err := json.Unmarshal(f.call("GET", path+"/control", worker.Token, nil, 200, ""), &feed); err != nil || feed.NextMessageID == "" {
			t.Fatalf("missing queued operation: %v", err)
		}
		f.call("POST", path+"/messages/"+feed.NextMessageID+"/claim", worker.Token, struct{}{}, 200, "")
		// Freeze the consumer while the producer traverses the retention window.
		for batch := 0; batch < 7; batch++ {
			events := make([]ConsoleEvent, 20)
			for i := range events {
				events[i] = ConsoleEvent{Kind: "text", Text: fmt.Sprintf("sample-%03d", 2+batch*20+i)}
			}
			f.call("POST", path+"/output", worker.Token, map[string]any{"events": events}, 200, "")
		}
		f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed", "message_id": feed.NextMessageID}, 200, "")
	}
	input, err := json.Marshal(map[string]any{"threadId": worker.ID, "runId": "slow", "messages": []any{map[string]string{"role": "user", "content": "go"}}, "forwardedProps": map[string]int{"generation": 2}})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	req := httptest.NewRequestWithContext(ctx, "POST", "/v1/ag-ui/workers/"+worker.ID+"/run?projection=incremental", bytes.NewReader(input))
	f.api.ServeHTTP(stream, req)
	wire := stream.Body.String()
	if !strings.Contains(wire, "live console skipped events 2 through 13") || !strings.Contains(wire, "sample-014") ||
		!strings.Contains(wire, "sample-141") || strings.Contains(wire, "sample-013") || !strings.Contains(wire, "RUN_FINISHED") {
		t.Fatal("slow observer missed its diagnostic, retained boundary or terminal event")
	}
}

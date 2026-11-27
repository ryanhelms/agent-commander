package provider

import (
	"strings"
	"testing"

	"agentcommander/internal/service"
)

func collectScreen(t *testing.T, run func(*screen)) outputBatch {
	t.Helper()
	s := &screen{batches: make(chan outputBatch, 32)}
	run(s)
	s.mu.Lock()
	s.queueLocked(nil)
	s.mu.Unlock()
	close(s.batches)
	var all outputBatch
	for batch := range s.batches {
		all.Events = append(all.Events, batch.Events...)
		all.Details = append(all.Details, batch.Details...)
	}
	return all
}

func TestClaudeStreamKeepsDetailsBesideAnUnchangedConsole(t *testing.T) {
	stream := strings.Join([]string{
		`{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"look first"},{"type":"tool_use","id":"s1","name":"mcp__commander__commander_status","input":{"wait_seconds":30}},{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"ls","description":"List files"}}]}}`,
		`{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b1","content":"a.go"}]}}`,
		`{"type":"result","subtype":"success","result":""}`,
	}, "\n")
	got := collectScreen(t, func(s *screen) {
		if err := render(strings.NewReader(stream), s); err != nil {
			t.Fatal(err)
		}
	})
	if len(got.Events) != 2 || got.Events[0].Kind != "tool_call" || got.Events[1].Kind != "tool_result" {
		t.Fatalf("console changed: %+v", got.Events)
	}
	byName := map[string]service.ToolDetail{}
	var thought, result service.ToolDetail
	for _, d := range got.Details {
		switch {
		case d.Kind == "thought":
			thought = d
		case d.Result != "":
			result = d
		default:
			byName[d.Name] = d
		}
	}
	if thought.Result != "look first" || thought.StartedAt != "" || *thought.Event != -1 {
		t.Fatalf("thought: %+v", thought)
	}
	if status := byName["commander_status"]; status.Key != "s1" || status.Input != `{"wait_seconds":30}` {
		t.Fatalf("status call: %+v", status)
	}
	if bash := byName["Bash"]; !strings.Contains(bash.Input, `"description":"List files"`) || bash.StartedAt == "" || *bash.Event != 0 {
		t.Fatalf("shell call: %+v", bash)
	}
	if result.Key != "b1" || result.Result != "a.go" || result.EndedAt == "" || *result.Event != 1 {
		t.Fatalf("result: %+v", result)
	}
}

func TestWireToolDetailKeepsFullValues(t *testing.T) {
	long := strings.Repeat("z", 40<<10)
	d := wireToolDetail([]byte(`{"sessionUpdate":"tool_call","toolCallId":"c","title":"Run","kind":"execute","rawInput":{"command":"` + long + `"},"content":[]}`))
	if d == nil || d.Key != "c" || d.ToolKind != "execute" || !strings.Contains(d.Input, long) || d.Content != "" {
		t.Fatalf("detail: %+v", d)
	}
	if wireToolDetail([]byte(`{"sessionUpdate":"agent_message_chunk"}`)) != nil {
		t.Fatal("a message chunk is not a tool call")
	}
}

func TestLargeDetailsSplitBatches(t *testing.T) {
	s := &screen{batches: make(chan outputBatch, 8)}
	value := strings.Repeat("a", service.MaxToolDetailField+10)
	for range 3 {
		s.recordDetail(service.ToolDetail{Kind: "tool", Key: "k", Input: value, Result: value})
	}
	if len(s.batches) != 2 || len(s.details) != 1 || len(s.details[0].Input) != service.MaxToolDetailField || len(s.details[0].Truncated) != 2 {
		t.Fatalf("batches %d, pending %d", len(s.batches), len(s.details))
	}
}

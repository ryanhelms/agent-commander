package provider

import (
	"os"
	"strings"
	"testing"

	model "agent-acp.local/sdks/go/model"
)

func TestConsoleToolShowsFailureWithoutInlineLargeStructuredPayload(t *testing.T) {
	payload := `{"type":"image","data":"` + strings.Repeat("AAEA", maxConsoleEventBytes/2) + `"}`
	for _, summary := range []string{payload, "[" + payload + "]"} {
		event := consoleTool(&model.ToolActivity{CallId: "read-1", Phase: "failed", Summary: summary})
		if event.Kind != "tool_result" || event.ToolID != "read-1" || event.Phase != "failed" ||
			!strings.Contains(event.Text, "Large tool payload omitted") || strings.Contains(event.Text, "AAEAAAEA") {
			t.Fatal("tool preview lost its failure, identity or attachment boundary")
		}
	}
}

func TestClaudeStdoutFixtureKeepsMultipartToolError(t *testing.T) {
	input, err := os.Open("../../design/verification/transcript-coverage/claude-stdout.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	defer input.Close()
	s := &screen{}
	if err := render(input, s); err != nil {
		t.Fatal(err)
	}
	const want = "Tool failed.\nPart one\nPart two\n[Claude image] image/png"
	if !strings.Contains(string(s.pending), "Visible partial text") ||
		!strings.Contains(string(s.pending), want) || strings.Contains(string(s.pending), "AAE=") {
		t.Fatalf("unexpected terminal preview: %s", s.pending)
	}
	for _, event := range s.events {
		if event.Kind == "tool_result" && event.ToolID == "read-1" && event.Phase == "failed" && event.Text == want {
			return
		}
	}
	t.Fatalf("structured console lost multipart tool output: %+v", s.events)
}

func TestClaudePartialTextUsesCompleteEnvelopeOrRecoversMissingText(t *testing.T) {
	stream := strings.Join([]string{
		`{"type":"stream_event","session_id":"s","event":{"type":"message_start"}}`,
		`{"type":"stream_event","session_id":"s","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}`,
		`{"type":"stream_event","session_id":"s","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Same "}}}`,
		`{"type":"stream_event","session_id":"s","parent_tool_use_id":"child","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Child "}}}`,
		`{"type":"stream_event","session_id":"s","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"words."}}}`,
		`{"type":"assistant","session_id":"s","message":{"content":[{"type":"text","text":"Same words."}]}}`,
		`{"type":"stream_event","session_id":"s","event":{"type":"content_block_stop","index":0}}`,
		`{"type":"stream_event","session_id":"s","event":{"type":"message_stop"}}`,
		`{"type":"stream_event","session_id":"s","parent_tool_use_id":"child","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"fragment."}}}`,
		`{"type":"stream_event","session_id":"s","parent_tool_use_id":"child","event":{"type":"message_stop"}}`,
		`{"type":"assistant","session_id":"s","message":{"content":[{"type":"text","text":"Same words."}]}}`,
		`{"type":"result","subtype":"success","result":"Same words."}`,
	}, "\n")
	s := &screen{}
	if err := render(strings.NewReader(stream), s); err != nil {
		t.Fatal(err)
	}
	const want = "Same words.\nChild fragment.\nSame words.\n"
	if got := string(s.pending); got != want || len(s.events) != 3 {
		t.Fatalf("unexpected terminal output or structured events: %q, %+v", got, s.events)
	}
}

func TestClaudePartialTextSurvivesAnIncompleteStream(t *testing.T) {
	s := &screen{}
	err := render(strings.NewReader(`{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Before disconnect."}}}`), s)
	if err == nil || string(s.pending) != "Before disconnect.\n" || len(s.events) != 1 {
		t.Fatalf("missing incomplete stream evidence: %q, %+v, %v", s.pending, s.events, err)
	}
}

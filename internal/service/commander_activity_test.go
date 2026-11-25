package service

import (
	"encoding/json"
	"strings"
	"testing"
)

const activityQID = "q-0123456789abcdef0123456789abcdef"

func TestCommanderActivityProjection(t *testing.T) {
	pending := `{"id":"` + activityQID + `","status":"pending"}`
	answered := strings.Replace(pending, "pending", "answered", 1)
	wrapped := func(text string) string {
		encoded, _ := json.Marshal(text)
		return `{"structuredContent":null,"content":[{"type":"text","text":` + string(encoded) + `}]}`
	}
	events := []ConsoleEvent{
		{Sequence: 1, Kind: "tool_call", ToolID: "ask", Name: "mcp__commander__commander_ask", Text: `{"question":"Which code?"}`},
		{Sequence: 2, Kind: "tool_result", ToolID: "ask", Text: wrapped(pending)},
		{Sequence: 3, Kind: "tool_call", ToolID: "poll1", Name: "commander_wait", Text: `{"request_id":"` + activityQID + `"}`},
		{Sequence: 4, Kind: "tool_result", ToolID: "poll1", Text: wrapped(pending)},
		{Sequence: 5, Kind: "tool_call", ToolID: "poll2", Name: "mcp.commander.commander_wait", Text: `{"request_id":"` + activityQID + `"}`},
		{Sequence: 6, Kind: "tool_result", ToolID: "poll2", Text: `{"structuredContent":` + answered + `}`},
		{Sequence: 7, Kind: "tool_call", ToolID: "unrelated", Name: "mcp__other__commander_wait", Text: `{"request_id":"` + activityQID + `"}`},
		{Sequence: 8, Kind: "tool_result", ToolID: "unrelated", Text: answered},
	}
	messages := aguiMessages("worker", events)
	expected := []*commanderActivity{
		{RequestID: activityQID, RequestStatus: "pending"},
		{RequestID: activityQID, RequestStatus: "pending"},
		{RequestID: activityQID, RequestStatus: "answered"},
		nil,
	}
	for i, want := range expected {
		call := messages[2*i].ToolCalls[0]
		var args struct {
			Detail    string
			Commander *commanderActivity
		}
		if err := json.Unmarshal([]byte(call.Function.Arguments), &args); err != nil {
			t.Fatal(err)
		}
		if args.Detail != events[2*i].Text {
			t.Errorf("call %d lost original arguments", i)
		}
		if (args.Commander == nil) != (want == nil) || want != nil && *args.Commander != *want {
			t.Errorf("call %d correlation: got %+v, want %+v", i, args.Commander, want)
		}
		if result := messages[2*i+1]; result.ToolCallID != call.ID || *result.Content != events[2*i+1].Text {
			t.Errorf("call %d result lost original content or call identity", i)
		}
	}
}

func TestCommanderActivityDoesNotApplyAnUnrelatedOrFailedReply(t *testing.T) {
	input := `{"request_id":"` + activityQID + `"}`
	different := `{"id":"q-fedcba9876543210fedcba9876543210","status":"answered"}`
	got := correlateCommanderTool("commander_wait", input, different, false)
	if got == nil || got.RequestID != activityQID || got.RequestStatus != "" {
		t.Fatalf("mismatched result overrode the target: %+v", got)
	}
	failed := correlateCommanderTool("commander_ask", "", `{"id":"`+activityQID+`","status":"pending"}`, true)
	if failed != nil {
		t.Fatalf("failed ask established a request: %+v", failed)
	}
}

func TestCommanderActivityKeepsTypedOperationIdentity(t *testing.T) {
	network := correlateCommanderTool("commander_network_submit", `{"id":"receipt-2"}`, "", false)
	if network == nil || network.OperationID != "receipt-2" {
		t.Fatalf("network operation ID missing: %+v", network)
	}
	integrate := correlateCommanderTool("commander_integrate", "", `{"id":"i-0123456789abcdef0123456789abcdef","candidate":{"status":"queued"}}`, false)
	if integrate == nil || integrate.OperationStatus != "queued" {
		t.Fatalf("integration queue state missing: %+v", integrate)
	}
}

func TestCommanderNetworkReceiptProgress(t *testing.T) {
	input := `{"id":"operation-1"}`
	for _, test := range []struct{ children, status string }{
		{`[{"status":"completed"},{"status":"processing"}]`, "processing"},
		{`[{"status":"declined"},{"status":"pending"}]`, "pending"},
		{`[{"status":"completed"},{"status":"expired"}]`, "partial"},
		{`[{"status":"completed"},{"status":"completed"}]`, "completed"},
		{`[{"status":"uncertain"}]`, "uncertain"},
		{`[{"status":"declined"},{"status":"denied"}]`, "declined"},
		{`[{"status":"declined"},{"status":"expired"}]`, "partial"},
		{`[{"status":"new status"}]`, ""},
	} {
		output := `{"id":"operation-1","children":` + test.children + `}`
		activity := correlateCommanderTool("commander_network_receipt", input, output, false)
		if activity == nil || activity.OperationID != "operation-1" || activity.OperationStatus != test.status {
			t.Errorf("receipt %s: got %+v, want %q", test.children, activity, test.status)
		}
	}
}

func TestCommanderCorrelationUsesOriginalInputDuringProgress(t *testing.T) {
	input := `{"request_id":"` + activityQID + `"}`
	events := []ConsoleEvent{
		{Sequence: 1, Kind: "tool_call", ToolID: "poll", Name: "commander_wait", Text: input},
		{Sequence: 2, Kind: "tool_update", ToolID: "poll", Text: "Still waiting"},
		{Sequence: 3, Kind: "tool_result", ToolID: "poll", Text: `{"id":"` + activityQID + `","status":"answered"}`},
	}
	messages := aguiMessages("worker", events)
	var args struct {
		Detail    string
		Commander *commanderActivity
	}
	if err := json.Unmarshal([]byte(messages[0].ToolCalls[0].Function.Arguments), &args); err != nil {
		t.Fatal(err)
	}
	if args.Detail != input+"\nStill waiting" || args.Commander == nil ||
		args.Commander.RequestID != activityQID || args.Commander.RequestStatus != "answered" {
		t.Fatalf("progress obscured the original correlation: %+v", args)
	}
}

func TestRunningCommanderPollCanUseScopedIDWithoutVisibleArguments(t *testing.T) {
	event := ConsoleEvent{Sequence: 1, Kind: "tool_call", ToolID: "poll", Name: "commander_wait", Text: "other",
		CommanderInput: `{"request_id":"` + activityQID + `"}`}
	messages := aguiMessages("worker", []ConsoleEvent{event})
	var args struct {
		Detail    string
		Commander *commanderActivity
	}
	if err := json.Unmarshal([]byte(messages[0].ToolCalls[0].Function.Arguments), &args); err != nil {
		t.Fatal(err)
	}
	if args.Detail != event.Text || args.Commander == nil || args.Commander.RequestID != activityQID {
		t.Fatalf("the active poll lacks its request ID: %+v", args)
	}
}

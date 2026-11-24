package acpprocessor

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"

	acp "github.com/coder/acp-go-sdk"
)

// Keep the dispatch contract synchronized with every discriminator in the
// pinned generated union, including variants a peer may send only by agreement.
func TestSessionUpdateUnionCoverage(t *testing.T) {
	for _, tc := range []struct{ kind, field, members string }{
		{"user_message_chunk", "UserMessageChunk", `"content":{"type":"text","text":"hello"}`},
		{"agent_message_chunk", "AgentMessageChunk", `"messageId":"m1","content":{"type":"text","text":"hi"}`},
		{"agent_thought_chunk", "AgentThoughtChunk", `"content":{"type":"text","text":"working"}`},
		{"tool_call", "ToolCall", `"toolCallId":"t","title":"Display title","name":"tool","rawInput":{"file":"x"}`},
		{"tool_call_update", "ToolCallUpdate", `"toolCallId":"t","content":[],"rawOutput":null`},
		{"plan", "Plan", `"entries":[{"content":"Check","priority":"high","status":"pending"}]`},
		{"plan_update", "PlanUpdate", `"plan":{"type":"markdown","planId":"p","title":"Work","content":"Check"}`},
		{"plan_removed", "PlanRemoved", `"planId":"p"`},
		{"available_commands_update", "AvailableCommandsUpdate", `"availableCommands":[{"name":"help","description":"Help"}]`},
		{"current_mode_update", "CurrentModeUpdate", `"currentModeId":"plan"`},
		{"config_option_update", "ConfigOptionUpdate", `"configOptions":[]`},
		{"session_info_update", "SessionInfoUpdate", `"title":null`},
		{"usage_update", "UsageUpdate", `"used":100,"size":1000,"cost":{"amount":1.25,"currency":"USD"}`},
		{"notice", "Notice", `"title":"Retry","severity":"warning"`},
		{"compaction_update", "CompactionUpdate", `"compactionId":"c","status":"completed"`},
		{"compaction_summary_chunk", "CompactionSummaryChunk", `"compactionId":"c","content":{"type":"text","text":"Summary"}`},
		{"prompt_suggestions_update", "PromptSuggestionsUpdate", `"suggestions":[]`},
		{"subagent_update", "SubagentUpdate", `"sessionId":"child"`},
		{"session_message", "SessionMessage", `"messageId":"m","content":[]`},
		{"session_message_chunk", "SessionMessageChunk", `"messageId":"m","content":{"type":"text","text":"chunk"}`},
	} {
		t.Run(tc.field, func(t *testing.T) {
			raw := []byte(fmt.Sprintf(`{"sessionUpdate":%q,%s,"vendorExtra":{"number":9007199254740993}}`, tc.kind, tc.members))
			got := Decode(raw)
			if got.Disposition != "decoded" || !bytes.Equal(raw, got.Raw) {
				t.Fatalf("disposition %q, retained %q", got.Disposition, got.Raw)
			}
			u := reflect.ValueOf(got.Value)
			for i := 0; i < u.NumField(); i++ {
				if isSet := !u.Field(i).IsNil(); isSet != (u.Type().Field(i).Name == tc.field) {
					t.Errorf("wrong union member %s", u.Type().Field(i).Name)
				}
			}
			view := got.Activity("live", "c")
			if view.Kind != tc.kind || !view.Valid() {
				t.Fatalf("bad activity %+v", view)
			}
		})
	}
	if fields := reflect.TypeOf(acp.SessionUpdate{}).NumField(); fields != 20 {
		t.Fatalf("pinned session-update union changed to %d members: add coverage and dispatch", fields)
	}
}

func TestLosslessSourceAndBoundedProjection(t *testing.T) {
	raw := []byte(`{"sessionUpdate":"agent_message_chunk","messageId":"m-123","content":{"type":"image","mimeType":"image/png","data":"SECRET","_meta":{"extension":"KEEP"}},"vendor":9007199254740993}`)
	got := Decode(raw)
	if got.Value.AgentMessageChunk.Content.Image.Data != "SECRET" {
		t.Fatal("expected a typed image")
	}
	activity := got.Activity("live", "c1")
	if activity.MessageID != "m-123" || activity.ContentType != "image" || activity.MIMEType != "image/png" {
		t.Fatal(activity)
	}
	public, err := json.Marshal(activity)
	if err != nil || bytes.Contains(public, []byte("SECRET")) || bytes.Contains(public, []byte("KEEP")) {
		t.Fatalf("invalid shared projection %s: %v", public, err)
	}
	page := fmt.Sprintf(`{"observations":[{"session":{"harnessInstance":"local","sessionId":"s"},"turnId":"t","cursor":"c1","extension":{"type":"acp.session_update","mediaType":"application/json","data":%q}},{"cursor":"c2","gap":{"reason":"expired"}}],"nextCursor":"page-2"}`, base64.StdEncoding.EncodeToString(raw))
	out, err := HistoryView([]byte(page))
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Records []struct {
			Update, Observation         json.RawMessage
			Disposition, Cursor, TurnID string
		}
		NextCursor string
	}
	if err := json.Unmarshal(out, &result); err != nil || len(result.Records) != 2 {
		t.Fatalf("history %s: %v", out, err)
	}
	row := result.Records[0]
	if row.Disposition != "decoded" || row.Cursor != "c1" || row.TurnID != "t" || len(row.Observation) != 0 ||
		!bytes.Equal(raw, row.Update) || result.Records[1].Disposition != "portable" || result.NextCursor != "page-2" {
		t.Fatalf("source view changed properties, precision, or pagination: %s", out)
	}
}

func TestExplicitDiscriminatorAndPatchPresence(t *testing.T) {
	for _, tc := range []struct{ body, want string }{
		{`{"sessionUpdate":"unknown","toolCallId":"familiar","title":"do not infer"}`, "unrecognized"},
		{`{"sessionUpdate":"usage_update","size":"wrong"}`, "undecodable"},
		{`{"sessionUpdate":`, "undecodable"},
	} {
		if got := Decode([]byte(tc.body)); got.Disposition != tc.want || string(got.Raw) != tc.body {
			t.Fatalf("bad update %+v", got)
		}
	}
	update := Decode([]byte(`{"sessionUpdate":"tool_call_update","toolCallId":"t","content":[],"rawOutput":null}`))
	tool := update.Value.ToolCallUpdate
	if tool == nil || !tool.RawInput.IsUnset() || !tool.RawOutput.IsNull() || tool.Content.Ptr() == nil || len(*tool.Content.Ptr()) != 0 {
		t.Fatal("tool patch lost field presence")
	}
	u := Decode([]byte(`{"sessionUpdate":"usage_update","used":42,"size":500,"cost":{"amount":1.25,"currency":"USD"}}`))
	usage := u.Activity("live", "id").Usage
	if usage == nil || usage.Used != 42 || usage.Size != 500 || usage.Cost == nil || usage.Cost.Amount != 1.25 {
		t.Fatal(usage)
	}
	if a := Reference("live", "c", "tool_call", strings.Repeat("x", 300)); !a.Valid() || a.MessageID != "" {
		t.Fatal(a)
	}
}

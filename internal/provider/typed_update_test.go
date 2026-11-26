package provider

import (
	"encoding/json"
	"testing"

	model "agent-acp.local/sdks/go/model"
	"agentcommander/internal/acpprocessor"
)

// Each typed SDK observation must render the same console row as the ACP
// update it was normalized from.
func TestTypedObservationsMatchOriginalRows(t *testing.T) {
	title := "Port"
	size := int64(12)
	for _, tc := range []struct {
		name, raw string
		obs       *model.Observation
	}{
		{"thought", `{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"considering"}}`,
			&model.Observation{Event: &model.Observation_Content{Content: &model.MessageContent{
				Speaker: model.Speaker_SPEAKER_ASSISTANT, Thought: true, Kind: "text", Text: "considering"}}}},
		{"image", `{"sessionUpdate":"user_message_chunk","content":{"type":"image","mimeType":"image/png","data":"AAH/","uri":"file:///a.png"}}`,
			&model.Observation{Event: &model.Observation_Content{Content: &model.MessageContent{
				Speaker: model.Speaker_SPEAKER_USER, Kind: "image", MimeType: "image/png", Uri: "file:///a.png"}}}},
		{"link", `{"sessionUpdate":"agent_message_chunk","content":{"type":"resource_link","uri":"https://x","name":"x","size":12}}`,
			&model.Observation{Event: &model.Observation_Content{Content: &model.MessageContent{
				Speaker: model.Speaker_SPEAKER_ASSISTANT, Kind: "resource_link", Uri: "https://x", Name: "x", Size: &size}}}},
		{"plan", `{"sessionUpdate":"plan","entries":[{"content":"a","priority":"high","status":"pending"},{"content":"b","priority":"low","status":"completed"}]}`,
			&model.Observation{Event: &model.Observation_SessionUpdate{SessionUpdate: &model.SessionUpdate{Change: &model.SessionUpdate_Plan{Plan: &model.PlanSnapshot{
				Entries: []*model.PlanSnapshot_Entry{{Content: "a", Priority: "high", Status: "pending"}, {Content: "b", Priority: "low", Status: "completed"}}}}}}}},
		{"commands", `{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"review","description":"Review"}]}`,
			&model.Observation{Event: &model.Observation_SessionUpdate{SessionUpdate: &model.SessionUpdate{Change: &model.SessionUpdate_Commands{Commands: &model.AvailableCommands{
				Commands: []*model.AvailableCommands_Command{{Name: "review", Description: "Review"}}}}}}}},
		{"mode", `{"sessionUpdate":"current_mode_update","currentModeId":"plan"}`,
			&model.Observation{Event: &model.Observation_SessionUpdate{SessionUpdate: &model.SessionUpdate{Change: &model.SessionUpdate_Mode{Mode: &model.ModeChanged{ModeId: "plan"}}}}}},
		{"config", `{"sessionUpdate":"config_option_update","configOptions":[{"type":"select","id":"model","name":"Model","currentValue":"opus","options":[{"value":"opus","name":"Opus"}]}]}`,
			&model.Observation{Event: &model.Observation_SessionUpdate{SessionUpdate: &model.SessionUpdate{Change: &model.SessionUpdate_Configuration{Configuration: &model.ConfigurationSnapshot{
				Options: []*model.ConfigurationSnapshot_Option{{Id: "model", Name: "Model", Kind: "select",
					CurrentValue: &model.ConfigurationSnapshot_Option_Selected{Selected: "opus"},
					Choices:      []*model.ConfigurationSnapshot_Choice{{Value: "opus", Name: "Opus"}}}}}}}}}},
		{"info", `{"sessionUpdate":"session_info_update","title":"Port"}`,
			&model.Observation{Event: &model.Observation_SessionUpdate{SessionUpdate: &model.SessionUpdate{Change: &model.SessionUpdate_Info{Info: &model.SessionInfoChanged{Title: &title}}}}}},
		{"usage", `{"sessionUpdate":"usage_update","used":10,"size":200}`,
			&model.Observation{Event: &model.Observation_SessionUpdate{SessionUpdate: &model.SessionUpdate{Change: &model.SessionUpdate_Usage{Usage: &model.UsageChanged{Used: 10, Size: 200}}}}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tc.obs.Cursor = "c1"
			original := acpprocessor.Decode(json.RawMessage(tc.raw))
			if original.Disposition != "decoded" {
				t.Fatalf("fixture did not decode: %s", original.Disposition)
			}
			want := acpActivityEvent(&original, "live", "c1")
			got := acpExtensionEvent(tc.obs, "live")
			if got.Kind != want.Kind || got.Text != want.Text || got.ACP.Kind != want.ACP.Kind ||
				got.ACP.ContentType != want.ACP.ContentType || got.ACP.MIMEType != want.ACP.MIMEType {
				t.Fatalf("typed row %+v %+v, want %+v %+v", got, got.ACP, want, want.ACP)
			}
		})
	}
}

func TestTypedThoughtReportsThinking(t *testing.T) {
	obs := &model.Observation{Event: &model.Observation_Content{Content: &model.MessageContent{Thought: true, Kind: "text", Text: "x"}}}
	if phase := claudeProgressPhase(obs); phase != "thinking" {
		t.Fatalf("phase %q", phase)
	}
	image := &model.Observation{Event: &model.Observation_Content{Content: &model.MessageContent{Kind: "image"}}}
	if phase := claudeProgressPhase(image); phase != "" {
		t.Fatalf("image phase %q", phase)
	}
}

func TestIdleTypedObservationRendersActivity(t *testing.T) {
	obs := &model.Observation{Cursor: "c", Event: &model.Observation_SessionUpdate{SessionUpdate: &model.SessionUpdate{
		Change: &model.SessionUpdate_Mode{Mode: &model.ModeChanged{ModeId: "plan"}}}}}
	e := idleSourcedEvent(obs, &acpprocessor.Activity{Cursor: "ref", TurnID: "t"})
	if e.Text != "[ACP current_mode_update] plan" || e.ACP.Cursor != "ref" || e.ACP.TurnID != "t" {
		t.Fatalf("idle row %+v %+v", e, e.ACP)
	}
}

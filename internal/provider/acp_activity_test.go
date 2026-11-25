package provider

import (
	"encoding/json"
	"strings"
	"testing"

	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"
	"agentcommander/internal/acpprocessor"
	"agentcommander/internal/service"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

func TestLiveWireRetentionAccountsForEnvelopeAndOriginalIndependently(t *testing.T) {
	peerError := []byte(`{"code":-32603,"vendor":"original"}`)
	for _, tc := range []struct {
		name, extras string
		payload      []byte
		omitPayload  bool
	}{
		{"large envelope", strings.Repeat("x", 1200), peerError, false},
		{"large payload", `{"peer":1}`, []byte(strings.Repeat("x", 1200)), true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			obs := &model.Observation{Session: &model.SessionRef{SessionId: "s"}, Cursor: "c", TurnId: "turn",
				SourceCursor: proto.String("c"), SourceRecord: &model.Extension{Type: "acp.prompt_error", MediaType: "application/json", Data: tc.payload},
				Event: &model.Observation_TurnEnded{TurnEnded: &model.TurnEnded{Reason: "failed"}},
				WireProvenance: &model.WireProvenance{Method: "session/prompt", IdJson: proto.String("2e+0"),
					Kind: model.WireMessageKind_WIRE_MESSAGE_KIND_ERROR, AdditionalFieldsJson: tc.extras}}
			raw, err := encodeLiveObservation(obs, 1024)
			var got model.Observation
			if err != nil || len(raw) > 1024 || protojson.Unmarshal(raw, &got) != nil || got.WireProvenance.GetIdJson() != "2e+0" {
				t.Fatalf("lost selected peer identity under retention limit: %v %s", err, raw)
			}
			if tc.omitPayload {
				if got.WireProvenance.AdditionalFieldsJson != tc.extras || got.SourceRecord.GetType() != "acp.source_omitted" || !strings.Contains(string(got.SourceRecord.Data), `"byteCount":1200`) {
					t.Fatalf("missing payload omission or wire extras: %s", raw)
				}
			} else if got.WireProvenance.OmittedAdditionalFieldsBytes != uint64(len(tc.extras)) || string(got.GetSourceRecord().GetData()) != string(peerError) {
				t.Fatalf("lost peer error or envelope byte count: %s", raw)
			}
			if obs.WireProvenance.AdditionalFieldsJson != tc.extras || obs.SourceRecord.Type != "acp.prompt_error" {
				t.Fatal("encoding mutated the SDK observation")
			}
		})
	}
}

func TestPermissionSourceIsPassiveAndKeepsItsNativeCursor(t *testing.T) {
	p := newACPSourcePublisher()
	obs := &model.Observation{
		Session: &model.SessionRef{HarnessInstance: "adapter", SessionId: "selected"},
		Cursor:  "c1", TurnId: "turn", SourceCursor: proto.String("c1"),
		Event: &model.Observation_Extension{Extension: &model.Extension{
			Type: "acp.permission_request", MediaType: "application/json", Data: []byte(`{"options":[{"kind":"allow_always"}],"toolCall":{"rawInput":"private-path"}}`),
		}},
	}
	ref := p.captureObservation(t.Context(), obs)
	update := p.queue.get(nil)[0]
	var original model.Observation
	if ref == nil || ref.Cursor != obs.Cursor || ref.TurnID != obs.TurnId || ref.Kind != obs.GetExtension().Type ||
		update.Kind != service.LiveSourcedObservationKind || len(update.Body) != 0 || protojson.Unmarshal(update.Observation, &original) != nil ||
		!proto.Equal(obs, &original) {
		t.Fatalf("passive permission did not preserve its sourced SDK observation")
	}
	preview := acpExtensionEvent(obs, "live")
	if preview.Kind != "output" || strings.Contains(preview.Text, "private-path") || strings.Contains(preview.Text, "allow_always") {
		t.Fatal("unavailable choice or private arguments escaped into the global preview")
	}
}

func TestACPSourceDescriptorsAndHistory(t *testing.T) {
	ref := &model.SessionRef{HarnessInstance: "local-fixture", SessionId: "s"}
	p := newACPSourcePublisher()
	for _, raw := range []string{
		`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello\n"}}`,
		`{"content":{"text":"hello","type":"text"},"sessionUpdate":"agent_message_chunk"}`,
	} {
		p.capture(runtime.ACPUpdate{Session: ref, TurnID: "t", Cursor: "1", Body: json.RawMessage(raw)})
		if n := p.queue.count; n != 0 {
			t.Fatalf("ordinary text entered supplemental source: %d", n)
		}
	}
	for i, raw := range []string{
		`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello","extra":"private"}}`,
		`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"},"messageId":"m"}`,
		`{"sessionUpdate":"tool_call","name":"read_file","title":"Display name","toolCallId":"tool1","rawInput":{"key":"private"}}`,
	} {
		p.capture(runtime.ACPUpdate{Session: ref, TurnID: "t", Cursor: "2", Body: json.RawMessage(raw)})
		original := p.queue.get(nil)[0]
		desc := p.take("2")
		if string(original.Body) != raw || desc == nil || desc.Cursor != "2" || desc.TurnID != "t" || i == 1 && desc.MessageID != "m" {
			t.Fatalf("source link %+v", desc)
		}
		if p.take("2") != nil {
			t.Fatal("reference consumed twice")
		}
		b, _ := json.Marshal(desc)
		if strings.Contains(string(b), "private") {
			t.Fatalf("scoped payload entered descriptor: %s", b)
		}
	}
	tool := acpprocessor.Decode([]byte(`{"sessionUpdate":"tool_call_update","toolCallId":"tool1","content":[]}`))
	prior := service.ConsoleEvent{Kind: "tool_result", ToolID: "tool1"}
	if !linkReplaySource(&prior, &tool, "original-cursor") || prior.ACP.Cursor != "original-cursor" {
		t.Fatal(prior)
	}
	prior.ToolID = "different-tool"
	if linkReplaySource(&prior, &tool, "wrong") {
		t.Fatal("matched unrelated source")
	}
}

func TestACPActivityProjection(t *testing.T) {
	raw := []byte(`{"sessionUpdate":"usage_update","used":13,"size":50,"_meta":{"fixture":"secret"}}`)
	obs := &model.Observation{Cursor: "from-sdk", Event: &model.Observation_Extension{Extension: &model.Extension{Type: "usage_update", MediaType: "application/json", Data: raw}}}
	for _, source := range []string{"live", "provider"} {
		got := acpExtensionEvent(obs, source)
		if got.Kind != "output" || got.ACP == nil || got.ACP.Source != source || got.ACP.Usage.Used != 13 || got.ACP.Cursor != "from-sdk" || !strings.Contains(got.Text, "13 / 50") || strings.Contains(got.Text, "secret") {
			t.Fatal(got)
		}
	}
}

func TestACPIdleContentUsesSpeakerAndScopedMedia(t *testing.T) {
	for _, tc := range []struct{ raw, kind, text string }{
		{`{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"retained"}}`, "user", "retained"},
		{`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"retained"}}`, "text", "retained"},
		{`{"sessionUpdate":"agent_message_chunk","content":{"type":"resource_link","uri":"fixture://plan","name":"Plan"}}`, "output", "[ACP resource_link] fixture://plan"},
		{`{"sessionUpdate":"agent_message_chunk","content":{"type":"image","mimeType":"image/png","data":"AA==","uri":"data:image/png;base64,AA=="}}`, "output", "[ACP image] image/png"},
	} {
		u := acpprocessor.Decode([]byte(tc.raw))
		event := acpActivityEvent(&u, "live", "cursor")
		if event.Kind != tc.kind || event.Text != tc.text {
			t.Fatalf("%s: %+v", tc.raw, event)
		}
	}
}

func TestCommanderInputIsScopedAndKeepsOnlyTheRequestID(t *testing.T) {
	const id = "q-0123456789abcdef0123456789abcdef"
	const raw = `{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"poll","rawInput":{"request_id":"` + id + `","other":"private original field"}}}`
	obs := &model.Observation{
		Session:      &model.SessionRef{SessionId: "s"},
		SourceRecord: &model.Extension{Type: runtime.ACPUpdateParamsSource, Data: []byte(raw)},
		Event:        &model.Observation_Tool{Tool: &model.ToolActivity{CallId: "poll", Name: "mcp__commander__commander_wait"}},
	}
	if got := commanderInputFromACP(obs, obs.GetTool().Name); got != `{"request_id":"`+id+`"}` {
		t.Fatalf("expected only the scoped request ID, got %s", got)
	}
	if got := commanderInputFromACP(obs, "mcp__other__commander_wait"); got != "" {
		t.Fatalf("non-Commander record contributed correlation: %s", got)
	}
	obs.Session.SessionId = "other"
	if got := commanderInputFromACP(obs, obs.GetTool().Name); got != "" {
		t.Fatalf("record from another session contributed correlation: %s", got)
	}
}

func TestCommanderInputIsLinkedFromTheNativeACPWire(t *testing.T) {
	const id = "q-0123456789abcdef0123456789abcdef"
	const raw = `{"sessionUpdate":"tool_call","toolCallId":"poll","title":"mcp__commander__commander_wait","rawInput":{"request_id":"` + id + `","other":"private original field"}}`
	p := newACPSourcePublisher()
	p.capture(runtime.ACPUpdate{Session: &model.SessionRef{HarnessInstance: "fixture", SessionId: "s"},
		TurnID: "t", Cursor: "cursor", Body: json.RawMessage(raw)})
	wire := p.takeWire("cursor")
	if wire.Activity == nil || wire.toolCallID != "poll" || wire.commanderInput != `{"request_id":"`+id+`"}` {
		t.Fatalf("wire correlation was not retained: %+v", wire)
	}
	if p.takeWire("cursor").Activity != nil {
		t.Fatal("wire reference was consumed twice")
	}
}

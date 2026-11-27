package provider

import (
	"testing"

	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"
	"agentcommander/internal/acpprocessor"
)

func TestACPPrettyTurnEnd(t *testing.T) {
	screen := &screen{}
	for _, tc := range []struct {
		turn, reason, source string
		observe, keep        bool
	}{
		{"first", "end_turn", "acp.prompt_result", true, true},
		{"second", "max_tokens", runtime.ACPV2TurnResultSource, true, true},
		{"third", "refusal", "acp.prompt_result", true, true},
		{"fourth", "max_turn_requests", runtime.ACPV2TurnResultSource, true, true},
		{"fifth", "cancelled", runtime.ACPV2TurnResultSource, true, true},
		{"transport", "adapter disconnected", "acp.prompt_result", true, false},
		{"synthetic", "cancelled", "", false, false},
		{"", "cancelled", "acp.prompt_result", true, false},
	} {
		event := &model.Observation{
			TurnId:       tc.turn,
			SourceRecord: &model.Extension{Type: tc.source},
			Event:        &model.Observation_TurnEnded{TurnEnded: &model.TurnEnded{Reason: tc.reason}},
		}
		before := len(screen.details)
		if observed := recordACPTurnEnd(screen, event, &acpprocessor.Activity{Kind: "turn_end"}); observed != tc.observe {
			t.Fatalf("%s: observed = %t, want %t", tc.turn, observed, tc.observe)
		}
		if got := len(screen.details) - before; (got == 1) != tc.keep {
			t.Fatalf("%s: stored %d detail records, want record = %t", tc.turn, got, tc.keep)
		}
		if tc.keep {
			detail := screen.details[before]
			if detail.Kind != "turn_end" || detail.Key != "turn-end-"+tc.turn ||
				detail.StopReason != tc.reason || detail.DurationMS != nil ||
				detail.Event == nil || *detail.Event != len(screen.events)-1 {
				t.Fatalf("%s: wrong detail: %+v", tc.turn, detail)
			}
		}
	}
	if len(screen.events) != 8 || screen.events[0].Text != "[Provider event: Turn ended]" {
		t.Fatalf("turn detail changed existing console events: %+v", screen.events)
	}
}

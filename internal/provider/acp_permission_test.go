package provider

import (
	"strings"
	"testing"

	model "agent-acp.local/sdks/go/model"
)

func TestACPPermissionUsesItsOwnToolCallID(t *testing.T) {
	const kind = "acp.permission_request"
	long := strings.Repeat("id", 129)
	for _, tc := range []struct {
		name, kind, data, want string
		v2                     bool
	}{
		{name: "v1 tool", kind: kind, data: `{"toolCall":{"toolCallId":"alpha","title":"ExitPlanMode"}}`, want: "alpha"},
		{name: "v2 subject", kind: kind, data: `{"toolCall":{"toolCallId":"old"},"subject":{"type":"tool_call","toolCall":{"toolCallId":"bravo"}}}`, want: "bravo", v2: true},
		{name: "v2 non-tool subject", kind: kind, data: `{"toolCall":{"toolCallId":"old"},"subject":{"type":"other","toolCall":{"toolCallId":"bravo"}}}`, v2: true},
		{name: "no identity", kind: kind, data: `{"toolCall":{"title":"ExitPlanMode"}}`},
		{name: "malformed", kind: kind, data: `{"toolCall":{"toolCallId":42}}`},
		{name: "other source", kind: "acp.update", data: `{"toolCall":{"toolCallId":"unrelated"}}`},
		{name: "bounded console ID", kind: kind, data: `{"toolCall":{"toolCallId":"` + long + `"}}`, want: consoleToolID(long)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			observation := &model.Observation{SourceRecord: &model.Extension{Type: tc.kind, Data: []byte(tc.data)}}
			if got := acpPermissionToolCallID(observation, tc.v2); got != tc.want {
				t.Fatalf("tool call ID = %q, want %q", got, tc.want)
			}
		})
	}
}

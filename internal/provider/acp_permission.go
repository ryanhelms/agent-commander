package provider

import (
	"encoding/json"

	model "agent-acp.local/sdks/go/model"
)

// The scoped permission's own ACP source supplies its subject. The portable
// input request carries choices and a request ID independently of the tool.
func acpPermissionToolCallID(event *model.Observation, v2 bool) string {
	source := event.GetSourceRecord()
	if source.GetType() != "acp.permission_request" {
		return ""
	}
	type toolCall struct {
		ID string `json:"toolCallId"`
	}
	var request struct {
		ToolCall toolCall
		Subject  struct {
			Type     string
			ToolCall toolCall
		}
	}
	if json.Unmarshal(source.GetData(), &request) != nil {
		return ""
	}
	if !v2 {
		return consoleToolID(request.ToolCall.ID)
	}
	if request.Subject.Type == "tool_call" {
		return consoleToolID(request.Subject.ToolCall.ID)
	}
	return ""
}

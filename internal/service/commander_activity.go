package service

import (
	"encoding/hex"
	"encoding/json"
	"regexp"
	"strings"
)

// commanderActivity is the subset of a Commander tool exchange that can link
// it to another call or to the current workspace state. It is supplemental to
// the original tool record and never drives a Commander operation.
type commanderActivity struct {
	RequestID       string `json:"requestId,omitempty"`
	RequestStatus   string `json:"requestStatus,omitempty"`
	OperationID     string `json:"operationId,omitempty"`
	OperationStatus string `json:"operationStatus,omitempty"`
	WorkerID        string `json:"workerId,omitempty"`
}

type commanderPayload map[string]json.RawMessage

func (p commanderPayload) text(key string) string {
	var value string
	_ = json.Unmarshal(p[key], &value)
	return value
}

func (p commanderPayload) object(key string) commanderPayload {
	var value commanderPayload
	_ = json.Unmarshal(p[key], &value)
	return value
}

// Claude history may wrap MCP text in content blocks and Codex history can
// retain the MCP result object. Decode known single-payload envelopes. Multiple
// blocks, clipped text and arbitrary nested values cannot establish a link.
func decodeCommanderPayload(data string) commanderPayload {
	for depth := 0; depth < 5; depth++ {
		data = strings.TrimSpace(data)
		if data == "" {
			return nil
		}
		switch data[0] {
		case '"':
			var text string
			if json.Unmarshal([]byte(data), &text) != nil {
				return nil
			}
			data = text
		case '[':
			var blocks []commanderPayload
			if json.Unmarshal([]byte(data), &blocks) != nil || len(blocks) != 1 || blocks[0].text("type") != "text" {
				return nil
			}
			data = blocks[0].text("text")
		case '{':
			var object commanderPayload
			if json.Unmarshal([]byte(data), &object) != nil {
				return nil
			}
			if result := object.object("result"); result != nil && (result["content"] != nil || result["structuredContent"] != nil) {
				object = result
			}
			if structured := object.object("structuredContent"); structured != nil {
				return structured
			}
			if object["id"] == nil && object["request_id"] == nil && object["content"] != nil {
				data = string(object["content"])
				continue
			}
			return object
		default:
			return nil
		}
	}
	return nil
}

func localCommanderID(value, prefix string) string {
	id, ok := strings.CutPrefix(value, prefix)
	if !ok || len(id) != 32 {
		return ""
	}
	if _, err := hex.DecodeString(id); err != nil {
		return ""
	}
	return value
}

var networkCommanderID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`)

func commanderToolName(name string) string {
	for _, prefix := range [...]string{"mcp__commander__", "mcp.commander.", "commander/"} {
		if base, found := strings.CutPrefix(name, prefix); found {
			return base
		}
	}
	return name
}

// CommanderToolInput retains only a validated correlation ID from ACP's raw
// inputs. The original update, including full arguments, is read through the
// scoped source.
func CommanderToolInput(name string, raw json.RawMessage) string {
	var key string
	switch commanderToolName(name) {
	case "commander_wait", "commander_reply", "commander_reconcile_reply":
		key = "request_id"
	case "commander_network_submit", "commander_network_receipt":
		key = "id"
	default:
		return ""
	}
	value := decodeCommanderPayload(string(raw)).text(key)
	if key == "request_id" && localCommanderID(value, "q-") == "" ||
		key == "id" && !networkCommanderID.MatchString(value) {
		return ""
	}
	rendered, _ := json.Marshal(map[string]string{key: value})
	return string(rendered)
}

func correlateCommanderTool(name, detail, output string, failed bool) *commanderActivity {
	name = commanderToolName(name)
	var activity commanderActivity
	var in, out commanderPayload
	switch name {
	case "commander_ask", "commander_wait", "commander_reply", "commander_reconcile_reply",
		"commander_delegate", "commander_send", "commander_integrate", "commander_result",
		"commander_interrupt", "commander_stop_worker", "commander_network_submit", "commander_network_receipt":
		in = decodeCommanderPayload(detail)
		if !failed {
			out = decodeCommanderPayload(strings.TrimPrefix(output, "[Structured MCP result]\n"))
		}
	default:
		return nil
	}
	switch name {
	case "commander_ask", "commander_wait", "commander_reply", "commander_reconcile_reply":
		inputID := localCommanderID(in.text("request_id"), "q-")
		outputID := localCommanderID(out.text("id"), "q-")
		activity.RequestID = inputID
		if inputID == "" {
			activity.RequestID = outputID
		}
		if outputID != "" && outputID == activity.RequestID {
			switch status := out.text("status"); status {
			case "pending", "answered", "cancelled":
				activity.RequestStatus = status
			}
		}
	case "commander_delegate", "commander_result":
		activity.WorkerID = localCommanderID(out.text("id"), "w-")
	case "commander_stop_worker", "commander_interrupt":
		activity.WorkerID = localCommanderID(in.text("worker_id"), "w-")
	case "commander_send":
		activity.WorkerID = localCommanderID(in.text("worker_id"), "w-")
		activity.OperationID = localCommanderID(out.text("id"), "m-")
		if activity.OperationID != "" {
			switch status := out.text("status"); status {
			case "queued", "processing", "completed", "failed", "cancelled", "interrupted", "delivery_unknown":
				activity.OperationStatus = status
			}
		}
	case "commander_integrate":
		activity.OperationID = localCommanderID(out.text("id"), "i-")
		if activity.OperationID != "" {
			switch status := out.object("candidate").text("status"); status {
			case "queued", "testing", "advancing", "tested", "integrated", "missing_tests",
				"invalid_candidate", "preparation_failed", "merge_failed", "conflict", "tests_failed",
				"candidate_changed", "target_changed", "target_dirty":
				activity.OperationStatus = status
			}
		}
	case "commander_network_submit", "commander_network_receipt":
		id := in.text("id")
		if id == "" {
			id = out.text("id")
		}
		if networkCommanderID.MatchString(id) {
			activity.OperationID = id
			if out.text("id") == id {
				activity.OperationStatus = networkActivityStatus(out["children"])
			}
		}
	}
	if activity == (commanderActivity{}) {
		return nil
	}
	return &activity
}

// A receipt is complete only when every recipient has completed. Preserve a
// terminal mixed outcome even when the MCP receipt lookup itself succeeded.
func networkActivityStatus(raw json.RawMessage) string {
	var children []struct{ Status string }
	if json.Unmarshal(raw, &children) != nil || len(children) == 0 {
		return ""
	}
	pending, processing := false, false
	terminal := ""
	for _, child := range children {
		status := child.Status
		switch status {
		case "pending":
			pending = true
			continue
		case "processing":
			processing = true
			continue
		case "denied":
			status = "declined"
		case "completed", "declined", "expired", "uncertain":
		default:
			return ""
		}
		if terminal == "" {
			terminal = status
		} else if terminal != status {
			terminal = "partial"
		}
	}
	switch {
	case processing:
		return "processing"
	case pending:
		return "pending"
	default:
		return terminal
	}
}

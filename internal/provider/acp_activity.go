package provider

import (
	"agent-acp.local/sdks/go/runtime"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	model "agent-acp.local/sdks/go/model"
	"agentcommander/internal/acpprocessor"
	"agentcommander/internal/service"
)

func configureACPActivity(config *runtime.Config) {
	enabled := os.Getenv("AGENT_COMMANDER_ACP_SESSION_ACTIVITY") == "on"
	config.ChildSessions = enabled
	config.NoticeUpdates = enabled
	config.CompactionUpdates = enabled
}

// The public preview can carry bounded activity facts. Complete typed update
// properties and open values are addressable in the worker's scoped history.
func acpActivityEvent(update *acpprocessor.Update, source, cursor string) service.ConsoleEvent {
	a := update.Activity(source, cursor)
	value := "[ACP " + a.Kind + "]"
	kind := "output"
	v := &update.Value
	block, _ := update.MessageContent()
	switch {
	case update.Disposition != "decoded":
		value += " " + update.Disposition + " update; see the scoped source."
	case block != nil && block.Text != nil:
		switch {
		case v.AgentMessageChunk != nil:
			kind, value = "text", block.Text.Text
		case v.UserMessageChunk != nil:
			kind, value = "user", block.Text.Text
		case v.AgentThoughtChunk != nil:
			kind, value = "thinking", block.Text.Text
		default:
			value += " " + block.Text.Text
		}
	case block != nil && a.ContentType != "":
		value = strings.TrimSpace("[ACP " + a.ContentType + "] " + a.MIMEType)
		var uri string
		switch {
		case block.Image != nil && block.Image.Uri != nil:
			uri = *block.Image.Uri
		case block.ResourceLink != nil:
			uri = block.ResourceLink.Uri
		case block.Resource != nil && block.Resource.Resource.TextResourceContents != nil:
			uri = block.Resource.Resource.TextResourceContents.Uri
		case block.Resource != nil && block.Resource.Resource.BlobResourceContents != nil:
			uri = block.Resource.Resource.BlobResourceContents.Uri
		}
		if uri != "" && len(uri) <= 512 && !strings.HasPrefix(strings.ToLower(uri), "data:") {
			value += " " + uri
		}
	case a.ItemCount != nil:
		value += fmt.Sprintf(" %d items", *a.ItemCount)
	case a.ModeID != "":
		value += " " + a.ModeID
	case a.Usage != nil:
		value += fmt.Sprintf(" %d / %d tokens", a.Usage.Used, a.Usage.Size)
	case v.SessionInfoUpdate != nil && v.SessionInfoUpdate.Title.Ptr() != nil:
		value += " " + *v.SessionInfoUpdate.Title.Ptr()
	case v.Notice != nil:
		value += " " + v.Notice.Title
	case v.SubagentUpdate != nil:
		value = "Provider child session"
		if title := v.SubagentUpdate.Title.Ptr(); title != nil {
			value += " · " + previewPrefix(consoleText(*title), 256)
		}
	}
	return service.ConsoleEvent{Kind: kind, Text: previewText(value), ACP: a}
}

// typedUpdate returns the ACP update behind an SDK SessionUpdate or
// MessageContent observation. It prefers the attached original and otherwise
// rebuilds the update from the typed fields.
func typedUpdate(obs *model.Observation) (acpprocessor.Update, bool) {
	if obs.GetSessionUpdate() == nil && obs.GetContent() == nil {
		return acpprocessor.Update{}, false
	}
	if source := paramsSource(obs); source.GetType() == runtime.ACPUpdateParamsSource {
		if update, ok := acpprocessor.ExtensionUpdate(source); ok && update.Disposition == "decoded" {
			return update, true
		}
	}
	return acpprocessor.TypedUpdate(obs)
}

func typedObservation(obs *model.Observation) bool {
	return obs.GetSessionUpdate() != nil || obs.GetContent() != nil
}

// acpExtensionEvent renders an extension or a typed ACP session observation.
func acpExtensionEvent(obs *model.Observation, source string) service.ConsoleEvent {
	if update, ok := typedUpdate(obs); ok {
		return acpActivityEvent(&update, source, obs.Cursor)
	}
	ext := obs.GetExtension()
	if event, ok := acpScopedActivity(obs, source); ok {
		return event
	}
	if source == "provider" && ext.GetType() == "codex.history.thread" {
		// Workspace paths and other thread properties belong in the selected
		// worker's source inspector. The shared conversation carries its link.
		return service.ConsoleEvent{Kind: "output", Text: "Codex thread details"}
	}
	// A permission with no actionable choice is a passive source record. Its
	// original options and tool arguments are only for the worker's inspector.
	if ext.GetType() == "acp.source_omitted" {
		return service.ConsoleEvent{Kind: "output", Text: "[Provider source exceeded its retention limit]"}
	}
	if ext.GetType() == "acp.permission_request" {
		return service.ConsoleEvent{Kind: "output", Text: "[Provider event: Permission request without an available choice]"}
	}
	if update, ok := acpprocessor.ExtensionUpdate(ext); ok {
		return acpActivityEvent(&update, source, obs.Cursor)
	}
	if source == "provider" && (promptMediaExtension(ext.GetType()) || (ext.GetMediaType() != "" &&
		ext.GetMediaType() != "application/json" && !strings.HasPrefix(ext.GetMediaType(), "text/"))) {
		return service.ConsoleEvent{Kind: "output", Text: historyAttachmentLabel}
	}
	if source == "provider" && len(ext.GetData()) <= maxConsoleEventBytes {
		if cleaned, ok := historyMediaPreview(ext.GetData()); ok {
			return service.ConsoleEvent{Kind: "output", Text: cleaned}
		}
	}
	return service.ConsoleEvent{Kind: "output", Text: extensionText(ext)}
}

// Private summaries, child transcripts and declined tool requests stay behind
// the original cursor. Repeated compaction snapshots update one timeline row.
func acpScopedActivity(obs *model.Observation, source string) (service.ConsoleEvent, bool) {
	ext := obs.GetExtension()
	event := service.ConsoleEvent{Kind: "output"}
	switch ext.GetType() {
	case runtime.ACPChildUpdateSource:
		event.Text = "Provider child session activity"
		event.ACP = acpprocessor.Reference(source, obs.GetCursor(), "subagent_update", "")
	case runtime.ACPChildPermissionSource:
		event.Text = "Provider child permission declined by Commander policy"
		event.ACP = acpprocessor.Reference(source, obs.GetCursor(), "child_permission", "")
	case runtime.ACPCompactionStateSource:
		var snapshot struct{ CompactionID, Status string }
		if json.Unmarshal(ext.GetData(), &snapshot) != nil || snapshot.CompactionID == "" {
			return service.ConsoleEvent{Kind: "output", Text: "Provider context compaction"}, true
		}
		event.Text = "Provider context compaction"
		switch snapshot.Status {
		case "in_progress":
			event.Text += " in progress"
		case "completed", "failed", "cancelled":
			event.Text += " " + snapshot.Status
		}
		id := sha256.Sum256([]byte(snapshot.CompactionID))
		event.ACP = acpprocessor.Reference(source, obs.GetCursor(), "compaction_update", hex.EncodeToString(id[:]))
		event.ACP.MessageOp = "replace"
	default:
		return service.ConsoleEvent{}, false
	}
	return event, true
}

func paramsSource(obs *model.Observation) *model.Extension {
	ext := obs.GetSourceRecord()
	if ext == nil {
		ext = obs.GetExtension()
	}
	switch ext.GetType() {
	case runtime.ACPUpdateParamsSource:
		return ext
	case "acp.source_omitted":
		var marker struct{ SourceType string }
		if json.Unmarshal(ext.Data, &marker) == nil && marker.SourceType == runtime.ACPUpdateParamsSource {
			return ext
		}
	}
	return nil
}

// observedToolDetail covers adapters without a wire peer.
func observedToolDetail(obs *model.Observation) *service.ToolDetail {
	ext := paramsSource(obs)
	if ext.GetType() != runtime.ACPUpdateParamsSource {
		return nil
	}
	inner, err := acpprocessor.ScopedUpdate(ext.Data, obs.GetSession().GetSessionId())
	if err != nil {
		return nil
	}
	d := wireToolDetail(inner)
	if d == nil || d.Key != obs.GetTool().GetCallId() {
		return nil
	}
	return d
}

// planDetail keeps a plan's entries; the console event only counts them.
func planDetail(obs *model.Observation) *service.ToolDetail {
	update, ok := typedUpdate(obs)
	if !ok || update.Value.Plan == nil {
		return nil
	}
	entries, err := json.Marshal(update.Value.Plan.Entries)
	if err != nil {
		return nil
	}
	return &service.ToolDetail{Kind: "plan", Plan: entries}
}

// The SDK's readable preview can omit rawInput. Retain the one safe ID needed
// to link an in-flight Commander call while its MCP result is still pending.
func commanderInputFromACP(obs *model.Observation, name string) string {
	if !strings.Contains(name, "commander_") {
		return ""
	}
	ext := paramsSource(obs)
	if ext.GetType() != runtime.ACPUpdateParamsSource {
		return ""
	}
	inner, err := acpprocessor.ScopedUpdate(ext.Data, obs.GetSession().GetSessionId())
	if err != nil {
		return ""
	}
	var update struct {
		SessionUpdate string
		ToolCallID    string
		RawInput      json.RawMessage
	}
	if json.Unmarshal(inner, &update) != nil || (update.SessionUpdate != "tool_call" && update.SessionUpdate != "tool_call_update") ||
		update.ToolCallID == "" || update.ToolCallID != obs.GetTool().GetCallId() {
		return ""
	}
	return service.CommanderToolInput(name, update.RawInput)
}

func idleSourcedEvent(obs *model.Observation, ref *acpprocessor.Activity) service.ConsoleEvent {
	var e service.ConsoleEvent
	switch {
	case obs.GetText() != nil:
		kind := "output"
		switch obs.GetText().Speaker {
		case model.Speaker_SPEAKER_USER:
			kind = "user"
		case model.Speaker_SPEAKER_ASSISTANT:
			kind = "text"
		}
		e = service.ConsoleEvent{Kind: kind, Text: previewText(obs.GetText().Text)}
	case obs.GetTool() != nil:
		e = consoleTool(obs.GetTool())
	case obs.GetInput() != nil:
		e = service.ConsoleEvent{Kind: "output", Text: "[Provider input request outside an active turn]"}
	case typedObservation(obs):
		e = acpExtensionEvent(obs, "live")
	case obs.GetExtension() != nil:
		ext := obs.GetExtension()
		if activity, ok := acpScopedActivity(obs, "live"); ok {
			e = activity
		} else if decoded, ok := acpprocessor.ExtensionUpdate(ext); ok {
			e = acpActivityEvent(&decoded, "live", obs.Cursor)
		} else if ext.Type == "acp.source_omitted" || ext.Type == "acp.permission_request" {
			e = acpExtensionEvent(obs, "live")
		} else {
			e = service.ConsoleEvent{Kind: "output", Text: "[Provider event: " + previewText(ext.Type) + "]"}
		}
	default:
		e = service.ConsoleEvent{Kind: "output", Text: "[Provider session activity]"}
	}
	if e.ACP != nil {
		e.ACP.Cursor, e.ACP.TurnID = ref.Cursor, ref.TurnID
	} else {
		e.ACP = ref
	}
	return e
}

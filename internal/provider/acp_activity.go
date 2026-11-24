package provider

import (
	"agent-acp.local/sdks/go/runtime"
	"encoding/json"
	"fmt"
	"strings"

	model "agent-acp.local/sdks/go/model"
	"agentcommander/internal/acpprocessor"
	"agentcommander/internal/service"
)

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
	}
	return service.ConsoleEvent{Kind: kind, Text: previewText(value), ACP: a}
}

func acpExtensionEvent(obs *model.Observation, source string) service.ConsoleEvent {
	ext := obs.GetExtension()
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
	case obs.GetExtension() != nil:
		ext := obs.GetExtension()
		if decoded, ok := acpprocessor.ExtensionUpdate(ext); ok {
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

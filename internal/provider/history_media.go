package provider

import (
	"encoding/json"
	"strings"

	model "agent-acp.local/sdks/go/model"
	wirejson "github.com/segmentio/encoding/json"

	"agentcommander/internal/acpprocessor"
	"agentcommander/internal/service"
)

// Parse only named provider fields. In particular, an opaque "Text" sibling
// must never override the public "text". Borrow the immutable SDK bytes while
// reading and copy only bounded display values into the workspace.
const historyJSON = wirejson.ZeroCopy | wirejson.DontMatchCaseInsensitiveStructFields

type promptBlock struct {
	Type   string `json:"type"`
	Text   string `json:"text"`
	URL    string `json:"url"`
	Source struct {
		MIME string `json:"media_type"`
	} `json:"source"`
}

func (b promptBlock) media(provider string) (kind, mime string) {
	switch b.Type {
	case "image", "audio":
		kind = b.Type
	case "localImage":
		if provider == "codex.history.item" {
			kind = "image"
		}
	}
	if kind == "" {
		return "", ""
	}
	if provider == "claude.history.message" {
		mime = b.Source.MIME
	} else if len(b.URL) >= 5 && strings.EqualFold(b.URL[:5], "data:") {
		// Only examine a short header. Never copy a data URL into the feed.
		header := b.URL[5:min(len(b.URL), 135)]
		if i := strings.IndexAny(header, ";,"); i >= 0 {
			mime = header[:i]
		}
	}
	if len(mime) > 128 || !strings.HasPrefix(mime, kind+"/") ||
		strings.ContainsAny(mime, " \t\r\n,;") || strings.IndexFunc(mime, func(r rune) bool { return r < 33 || r > 126 }) >= 0 {
		mime = ""
	}
	return kind, mime
}

// A single provider original can project many SDK observations, across pages.
// Only user text and media siblings are represented by the one prompt row.
// Tool calls, replies and other extensions keep their own source links.
type historyPrompt struct {
	source  string
	preview service.ConsoleEvent
	emitted bool
}

func (p *historyPrompt) observe(obs *model.Observation, pageCursor string) (service.ConsoleEvent, bool) {
	cursor := obs.GetSourceCursor()
	if p.source != cursor {
		*p = historyPrompt{source: cursor}
	}
	if cursor != "" && obs.Cursor == cursor {
		p.preview = retainedPrompt(obs, pageCursor)
	}
	if p.preview.ACP == nil || (obs.GetText().GetSpeaker() != model.Speaker_SPEAKER_USER && !promptMediaExtension(obs.GetExtension().GetType())) {
		return service.ConsoleEvent{}, false
	}
	if p.emitted {
		return service.ConsoleEvent{}, true
	}
	p.emitted = true
	return p.preview, true
}

func promptMediaExtension(name string) bool {
	switch name {
	case "claude.image", "claude.audio", "codex.user.image", "codex.user.localImage", "codex.user.audio":
		return true
	}
	return false
}

func retainedPrompt(obs *model.Observation, pageCursor string) service.ConsoleEvent {
	source := obs.GetSourceRecord()
	switch source.GetType() {
	case "claude.history.message", "codex.history.item":
	default:
		return service.ConsoleEvent{}
	}
	var record struct {
		Type    string          `json:"type"`
		Content json.RawMessage `json:"content"`
		Message struct {
			Content json.RawMessage `json:"content"`
		} `json:"message"`
	}
	if _, err := wirejson.Parse(source.Data, &record, historyJSON); err != nil {
		return service.ConsoleEvent{}
	}
	content := record.Content
	if source.Type == "claude.history.message" && record.Type == "user" {
		content = record.Message.Content
	} else if source.Type != "codex.history.item" || record.Type != "userMessage" {
		return service.ConsoleEvent{}
	}
	var blocks []promptBlock
	if len(content) == 0 || content[0] != '[' {
		return service.ConsoleEvent{}
	}
	if _, err := wirejson.Parse(content, &blocks, historyJSON); err != nil {
		return service.ConsoleEvent{}
	}
	var count int
	var kind, mime string
	for _, b := range blocks {
		k, m := b.media(source.Type)
		if k == "" {
			continue
		}
		if count == 0 {
			kind, mime = k, m
		} else {
			if k != kind {
				kind = "mixed"
			}
			if m != mime {
				mime = ""
			}
		}
		count++
	}
	if count == 0 {
		return service.ConsoleEvent{}
	}
	ref := acpprocessor.Reference("provider", obs.Cursor, "provider_prompt_media", "")
	ref.PageCursor, ref.TurnID = pageCursor, obs.GetTurnId()
	ref.ContentType, ref.MIMEType, ref.ItemCount = kind, strings.Clone(mime), &count
	var text strings.Builder
	for _, b := range blocks {
		if b.Type == "text" && text.Len() <= maxConsoleEventBytes {
			text.WriteString(previewPrefix(b.Text, maxConsoleEventBytes+1-text.Len()))
		}
	}
	if text.Len() == 0 {
		text.WriteString("[Attachment]")
	}
	return service.ConsoleEvent{Kind: "user", Text: text.String(), ACP: ref}
}

// Keep binary content on the selected source while retaining surrounding
// tool text, error fields and call identity in the shared preview.
const historyAttachmentLabel = "[Attachment in provider source]"

func dataURL(s string) bool {
	return len(s) >= 5 && strings.EqualFold(s[:5], "data:") && strings.Contains(s[5:min(len(s), 140)], ",")
}

func redactHistoryValue(value any, mediaContainer bool) (any, bool) {
	changed := false
	switch v := value.(type) {
	case map[string]any:
		kind, _ := v["type"].(string)
		switch kind {
		case "image", "localImage", "audio", "image_url", "input_audio", "base64":
			return historyAttachmentLabel, true
		}
		// A future or differently cased block can still explicitly describe
		// a media container. Keep its title and other inspectable text intact.
		lower := strings.ToLower(kind)
		mediaContainer = mediaContainer || strings.Contains(lower, "attachment") ||
			strings.Contains(lower, "image") || strings.Contains(lower, "audio") || lower == "base64"
		for _, key := range []string{"media_type", "mimeType"} {
			if m, ok := v[key].(string); ok && (strings.HasPrefix(m, "image/") || strings.HasPrefix(m, "audio/")) {
				if _, ok = v["data"].(string); ok {
					v["data"], changed = historyAttachmentLabel, true
				}
			}
		}
		for key, part := range v {
			if key == "blob" || key == "base64" || (mediaContainer && key == "data") {
				if _, ok := part.(string); ok {
					v[key], changed = historyAttachmentLabel, true
					continue
				}
			}
			if clean, replaced := redactHistoryValue(part, mediaContainer); replaced {
				v[key], changed = clean, true
			}
		}
	case []any:
		for i, part := range v {
			if clean, replaced := redactHistoryValue(part, mediaContainer); replaced {
				v[i], changed = clean, true
			}
		}
	case string:
		if dataURL(v) {
			return historyAttachmentLabel, true
		}
	}
	return value, changed
}

// When the vendor supplied a large structured result, keep the bounded human
// text in content order without re-encoding its entire non-media metadata.
func retainedToolText(value any, dst *strings.Builder) {
	if dst.Len() >= maxConsoleEventBytes {
		return
	}
	switch v := value.(type) {
	case []any:
		for _, item := range v {
			retainedToolText(item, dst)
		}
	case map[string]any:
		for _, key := range []string{"result", "error", "content", "output", "message", "text"} {
			if child, ok := v[key]; ok {
				retainedToolText(child, dst)
			}
		}
	case string:
		if v != "" && v != historyAttachmentLabel {
			if dst.Len() > 0 {
				dst.WriteByte('\n')
			}
			dst.WriteString(previewPrefix(v, maxConsoleEventBytes-dst.Len()))
		}
	}
}

func historyMediaPreview(raw []byte) (string, bool) {
	var value any
	if _, err := wirejson.Parse(raw, &value, historyJSON|wirejson.UseNumber); err != nil {
		return "", false
	}
	clean, changed := redactHistoryValue(value, false)
	if !changed {
		return "", false
	}
	if len(raw) <= maxConsoleEventBytes {
		encoded, err := json.Marshal(clean)
		if err == nil {
			return string(encoded), true
		}
	}
	var text strings.Builder
	retainedToolText(clean, &text)
	if text.Len() > 0 {
		text.WriteByte('\n')
	}
	text.WriteString(historyAttachmentLabel)
	return text.String(), true
}

func historyToolSummary(summary string) string {
	trimmed := strings.TrimSpace(summary)
	if dataURL(trimmed) {
		return historyAttachmentLabel
	}
	if len(trimmed) > 0 && (trimmed[0] == '{' || trimmed[0] == '[') {
		if cleaned, ok := historyMediaPreview([]byte(trimmed)); ok {
			return cleaned
		}
	}
	return summary
}

func retainedToolEvent(tool *model.ToolActivity) service.ConsoleEvent {
	summary := historyToolSummary(tool.Summary)
	if summary == tool.Summary {
		return consoleTool(tool)
	}
	return consoleTool(&model.ToolActivity{CallId: tool.CallId, Name: tool.Name, Phase: tool.Phase, Summary: summary})
}

// Package acpprocessor decodes ACP session notifications for authorized source
// views and projects bounded activity descriptors into the shared workspace.
package acpprocessor

import (
	"encoding/json"
	"math"
	"strings"
	"unicode"

	acp "github.com/coder/acp-go-sdk"
)

// Update holds the upstream generated discriminated union beside its exact
// supplied fields. Unknown members, JSON numbers and field presence survive
// forwarding even when the selected SDK cannot represent them.
type Update struct {
	Kind        string
	Value       acp.SessionUpdate
	Disposition string
	Raw         json.RawMessage
}

// decodeVariant dispatches on the explicit discriminator. In particular a new
// variant with familiar-looking fields must never be inferred to be a tool.
func decodeVariant[T any](raw json.RawMessage, member **T) error {
	var value T
	if err := json.Unmarshal(raw, &value); err != nil {
		return err
	}
	*member = &value
	return nil
}

func Decode(raw json.RawMessage) Update {
	var header struct{ SessionUpdate string }
	update := Update{Raw: raw, Disposition: "undecodable"}
	if json.Unmarshal(raw, &header) != nil || header.SessionUpdate == "" {
		return update
	}
	update.Kind = header.SessionUpdate
	u := &update.Value
	var err error
	switch update.Kind {
	case "user_message_chunk":
		err = decodeVariant(raw, &u.UserMessageChunk)
	case "agent_message_chunk":
		err = decodeVariant(raw, &u.AgentMessageChunk)
	case "agent_thought_chunk":
		err = decodeVariant(raw, &u.AgentThoughtChunk)
	case "tool_call":
		err = decodeVariant(raw, &u.ToolCall)
	case "tool_call_update":
		err = decodeVariant(raw, &u.ToolCallUpdate)
	case "plan":
		err = decodeVariant(raw, &u.Plan)
	case "plan_update":
		err = decodeVariant(raw, &u.PlanUpdate)
	case "plan_removed":
		err = decodeVariant(raw, &u.PlanRemoved)
	case "available_commands_update":
		err = decodeVariant(raw, &u.AvailableCommandsUpdate)
	case "current_mode_update":
		err = decodeVariant(raw, &u.CurrentModeUpdate)
	case "config_option_update":
		err = decodeVariant(raw, &u.ConfigOptionUpdate)
	case "session_info_update":
		err = decodeVariant(raw, &u.SessionInfoUpdate)
	case "usage_update":
		err = decodeVariant(raw, &u.UsageUpdate)
	case "notice":
		err = decodeVariant(raw, &u.Notice)
	case "compaction_update":
		err = decodeVariant(raw, &u.CompactionUpdate)
	case "compaction_summary_chunk":
		err = decodeVariant(raw, &u.CompactionSummaryChunk)
	case "prompt_suggestions_update":
		err = decodeVariant(raw, &u.PromptSuggestionsUpdate)
	case "subagent_update":
		err = decodeVariant(raw, &u.SubagentUpdate)
	case "session_message":
		err = decodeVariant(raw, &u.SessionMessage)
	case "session_message_chunk":
		err = decodeVariant(raw, &u.SessionMessageChunk)
	default:
		update.Disposition = "unrecognized"
		return update
	}
	if err == nil {
		update.Disposition = "decoded"
	}
	return update
}

// Activity links the bounded AG-UI projection to the worker-scoped source.
// Cursor is the observation's identity within that source, not a page token.
type Activity struct {
	Source string `json:"source"`
	Cursor string `json:"cursor,omitempty"`
	// PageCursor is the SDK page containing a selected provider original.
	// Its absence addresses the first page. Cursor still identifies the record.
	PageCursor  string      `json:"pageCursor,omitempty"`
	TurnID      string      `json:"turnId,omitempty"`
	Kind        string      `json:"kind"`
	MessageID   string      `json:"messageId,omitempty"`
	MessageOp   string      `json:"messageOp,omitempty"`
	ContentType string      `json:"contentType,omitempty"`
	MIMEType    string      `json:"mimeType,omitempty"`
	ModeID      string      `json:"modeId,omitempty"`
	ItemCount   *int        `json:"itemCount,omitempty"`
	Usage       *Usage      `json:"usage,omitempty"`
	TurnTokens  *TokenUsage `json:"turnTokens,omitempty"`
}

// TokenUsage is the last prompt result's optional usage snapshot. Preserve
// omission and zero independently and do not accumulate reported counts.
type TokenUsage struct {
	InputTokens       *int64 `json:"inputTokens,omitempty"`
	OutputTokens      *int64 `json:"outputTokens,omitempty"`
	ThoughtTokens     *int64 `json:"thoughtTokens,omitempty"`
	CachedReadTokens  *int64 `json:"cachedReadTokens,omitempty"`
	CachedWriteTokens *int64 `json:"cachedWriteTokens,omitempty"`
	TotalTokens       *int64 `json:"totalTokens,omitempty"`
}

func (u TokenUsage) reportable() bool {
	present := false
	for _, value := range []*int64{u.InputTokens, u.OutputTokens, u.ThoughtTokens, u.CachedReadTokens, u.CachedWriteTokens, u.TotalTokens} {
		if value != nil {
			if *value < 0 {
				return false
			}
			present = true
		}
	}
	return present
}

func PromptResultTokens(data []byte) *TokenUsage {
	var result struct {
		Usage *TokenUsage `json:"usage"`
	}
	if json.Unmarshal(data, &result) != nil || result.Usage == nil || !result.Usage.reportable() {
		return nil
	}
	return result.Usage
}

type Usage struct {
	Used int64 `json:"used"`
	Size int64 `json:"size"`
	Cost *Cost `json:"cost,omitempty"`
}

type Cost struct {
	Amount   float64 `json:"amount"`
	Currency string  `json:"currency"`
}

func bounded(value string, limit int) string {
	if len(value) > limit || strings.IndexFunc(value, unicode.IsControl) >= 0 {
		return ""
	}
	return value
}

func (a *Activity) Valid() bool {
	if a == nil {
		return true
	}
	if a.Source != "live" && a.Source != "provider" || a.Kind == "" ||
		bounded(a.Kind, 128) != a.Kind || bounded(a.Cursor, cursorLimit(a.Source)) != a.Cursor || bounded(a.TurnID, 256) != a.TurnID ||
		a.PageCursor != "" && (a.Source != "provider" || bounded(a.PageCursor, ProviderCursorLimit) != a.PageCursor) ||
		bounded(a.MessageID, 256) != a.MessageID ||
		a.MessageOp != "" && (a.MessageID == "" || (a.MessageOp != "append" && a.MessageOp != "replace")) || bounded(a.ContentType, 32) != a.ContentType ||
		bounded(a.MIMEType, 128) != a.MIMEType || bounded(a.ModeID, 128) != a.ModeID ||
		a.ItemCount != nil && *a.ItemCount < 0 {
		return false
	}
	if a.Usage != nil && a.Usage.Cost != nil {
		c := a.Usage.Cost
		if bounded(c.Currency, 16) != c.Currency || math.IsNaN(c.Amount) || math.IsInf(c.Amount, 0) {
			return false
		}
	}
	return a.TurnTokens == nil || a.TurnTokens.reportable()
}

const ProviderCursorLimit = 8192

func cursorLimit(source string) int {
	if source == "provider" {
		return ProviderCursorLimit
	}
	return 512
}

// Reference identifies a raw record whose text/tool facts already arrived
// through a typed portable SDK observation.
func Reference(source, cursor, kind, messageID string) *Activity {
	kind = bounded(kind, 128)
	if kind == "" {
		kind = "unrecognized"
	}
	return &Activity{Source: source, Cursor: bounded(cursor, cursorLimit(source)), Kind: kind, MessageID: bounded(messageID, 256)}
}

// MessageContent selects the single ACP content block and any message identity
// supplied by the peer; compaction chunks may have no message ID.
func (u *Update) MessageContent() (*acp.ContentBlock, *acp.MessageId) {
	v := &u.Value
	switch {
	case v.UserMessageChunk != nil:
		return &v.UserMessageChunk.Content, v.UserMessageChunk.MessageId
	case v.AgentMessageChunk != nil:
		return &v.AgentMessageChunk.Content, v.AgentMessageChunk.MessageId
	case v.AgentThoughtChunk != nil:
		return &v.AgentThoughtChunk.Content, v.AgentThoughtChunk.MessageId
	case v.SessionMessageChunk != nil:
		return &v.SessionMessageChunk.Content, &v.SessionMessageChunk.MessageId
	case v.CompactionSummaryChunk != nil:
		return &v.CompactionSummaryChunk.Content, nil
	default:
		return nil, nil
	}
}

func (u *Update) Activity(source, cursor string) *Activity {
	a := Reference(source, cursor, u.Kind, "")
	v := &u.Value
	count := func(n int) { a.ItemCount = &n }
	if block, id := u.MessageContent(); block != nil {
		a.message(id, block)
	} else if v.SessionMessage != nil {
		a.MessageID = bounded(string(v.SessionMessage.MessageId), 256)
	}
	switch {
	case v.Plan != nil:
		count(len(v.Plan.Entries))
	case v.AvailableCommandsUpdate != nil:
		count(len(v.AvailableCommandsUpdate.AvailableCommands))
	case v.ConfigOptionUpdate != nil:
		count(len(v.ConfigOptionUpdate.ConfigOptions))
	case v.PromptSuggestionsUpdate != nil:
		count(len(v.PromptSuggestionsUpdate.Suggestions))
	case v.CurrentModeUpdate != nil:
		a.ModeID = bounded(string(v.CurrentModeUpdate.CurrentModeId), 128)
	case v.UsageUpdate != nil:
		usage := v.UsageUpdate
		a.Usage = &Usage{Used: usage.Used, Size: usage.Size}
		if usage.Cost != nil {
			a.Usage.Cost = &Cost{Amount: usage.Cost.Amount, Currency: bounded(usage.Cost.Currency, 16)}
		}
	}
	return a
}

func (a *Activity) message(id *acp.MessageId, block *acp.ContentBlock) {
	if id != nil {
		a.MessageID = bounded(string(*id), 256)
	}
	switch {
	case block.Text != nil:
		a.ContentType = "text"
	case block.Image != nil:
		a.ContentType, a.MIMEType = "image", bounded(block.Image.MimeType, 128)
	case block.Audio != nil:
		a.ContentType, a.MIMEType = "audio", bounded(block.Audio.MimeType, 128)
	case block.Resource != nil:
		a.ContentType = "resource"
	case block.ResourceLink != nil:
		a.ContentType = "resource_link"
		if block.ResourceLink.MimeType != nil {
			a.MIMEType = bounded(*block.ResourceLink.MimeType, 128)
		}
	}
}

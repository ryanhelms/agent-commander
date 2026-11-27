package provider

// Runner side of the tool details the local app reads; see
// service/tool_details.go. Nothing here changes a console event.

import (
	"encoding/json"
	"slices"
	"time"
	"unicode/utf8"

	"agentcommander/internal/service"
)

// A batch holds a few large values at most, so that even heavily escaped text
// stays below the output endpoint's request limit.
const (
	detailBatchBytes   = 1 << 20
	detailBatchRecords = 100
)

func detailNow() string { return time.Now().UTC().Format(time.RFC3339Nano) }

// eventTiming starts the detail for a tool call or thought event.
func eventTiming(event service.ConsoleEvent) *service.ToolDetail {
	switch event.Kind {
	case "tool_call", "tool_update":
		if event.ToolID != "" {
			return &service.ToolDetail{Kind: "tool", Key: event.ToolID, Name: event.Name, StartedAt: detailNow()}
		}
	case "tool_result":
		if event.ToolID != "" {
			return &service.ToolDetail{Kind: "tool", Key: event.ToolID, Name: event.Name, EndedAt: detailNow()}
		}
	case "thinking":
		d := &service.ToolDetail{Kind: "thought", StartedAt: detailNow()}
		d.EndedAt = d.StartedAt
		if event.ACP != nil {
			d.Key = event.ACP.MessageID
		}
		if len(d.Key) > 256 {
			d.Key = ""
		}
		return d
	}
	return nil
}

// addDetailLocked queues a detail beside the latest event of the pending batch.
func (s *screen) addDetailLocked(d service.ToolDetail) {
	for _, field := range []struct {
		value *string
		name  string
	}{{&d.Input, "input"}, {&d.Result, "result"}, {&d.Content, "content"}} {
		if len(*field.value) <= service.MaxToolDetailField {
			continue
		}
		end := service.MaxToolDetailField
		for end > 0 && !utf8.RuneStart((*field.value)[end]) {
			end--
		}
		*field.value = (*field.value)[:end]
		if !slices.Contains(d.Truncated, field.name) {
			d.Truncated = append(d.Truncated, field.name)
		}
	}
	size := d.Size()
	if s.batches != nil && len(s.details) != 0 && (s.detailBytes+size > detailBatchBytes || len(s.details) >= detailBatchRecords) {
		s.queueLocked(nil)
	}
	index := len(s.events) - 1
	d.Event = &index
	s.details = append(s.details, d)
	s.detailBytes += size
}

// recordDetail keeps a detail that has no console event of its own.
func (s *screen) recordDetail(d service.ToolDetail) {
	if d.Key != "" {
		d.Key = consoleToolID(d.Key)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.closed {
		s.addDetailLocked(d)
	}
}

// jsonValue returns a JSON string's text, or any other JSON value as written.
func jsonValue(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return text
	}
	return string(raw)
}

// wireToolDetail reads the full values of an ACP tool_call or tool_call_update.
func wireToolDetail(body []byte) *service.ToolDetail {
	var update struct {
		SessionUpdate, ToolCallID, Title, Kind  string
		RawInput, RawOutput, Content, Locations json.RawMessage
	}
	if json.Unmarshal(body, &update) != nil || update.ToolCallID == "" ||
		(update.SessionUpdate != "tool_call" && update.SessionUpdate != "tool_call_update") {
		return nil
	}
	d := &service.ToolDetail{Kind: "tool", Key: update.ToolCallID, Title: update.Title, ToolKind: update.Kind,
		Input: jsonValue(update.RawInput), Result: jsonValue(update.RawOutput)}
	if content := jsonValue(update.Content); content != "[]" {
		d.Content = content
	}
	if update.Locations != nil {
		var locations []service.ToolLocation
		d.Location = &service.ToolLocation{}
		if json.Unmarshal(update.Locations, &locations) == nil && len(locations) == 1 && locations[0].Valid() {
			d.Location = &locations[0]
		}
	}
	return d
}

// merge adds the provider's values to the timing started for the same event.
func mergeDetail(timing, values *service.ToolDetail) *service.ToolDetail {
	if values == nil {
		return timing
	}
	if timing == nil {
		return values
	}
	merged := *values
	merged.Kind, merged.Key = timing.Kind, timing.Key
	merged.StartedAt, merged.EndedAt = timing.StartedAt, timing.EndedAt
	if merged.Name == "" {
		merged.Name = timing.Name
	}
	return &merged
}

package service

import (
	"bytes"
	"encoding/json"
	"fmt"
	"slices"
	"strconv"
)

// Each worker keeps this many chronological console events in its live preview.
const consoleEventWindow = 128

func operationStateDelta(old, next aguiRunState) []aguiPatch {
	// The worker and operation IDs are fixed for the lifetime of a subscription.
	var changes []aguiPatch
	if old.Status != next.Status {
		changes = append(changes, aguiPatch{"replace", "/status", next.Status})
	}
	if old.OperationStatus != next.OperationStatus {
		changes = append(changes, aguiPatch{"replace", "/operationStatus", next.OperationStatus})
	}
	if len(old.UnconfirmedToolCalls) > 0 && len(next.UnconfirmedToolCalls) == 0 {
		changes = append(changes, aguiPatch{"remove", "/unconfirmedToolCalls", nil})
	} else if !slices.EqualFunc(old.UnconfirmedToolCalls, next.UnconfirmedToolCalls, func(a, b unconfirmedToolCall) bool {
		return a.ID == b.ID && a.Name == b.Name && bytes.Equal(a.Arguments, b.Arguments)
	}) {
		// RFC 6902 add can introduce or replace the bounded list.
		changes = append(changes, aguiPatch{"add", "/unconfirmedToolCalls", next.UnconfirmedToolCalls})
	}
	changes = questionChanges(changes, "/pendingRequests", old.PendingRequests, next.PendingRequests)
	return questionChanges(changes, "/requests", old.Requests, next.Requests)
}

func equalQuestion(a, b Question) bool {
	return a.ID == b.ID && a.WorkerID == b.WorkerID && a.Question == b.Question && a.Status == b.Status &&
		a.Answer == b.Answer && a.Delivery == b.Delivery && slices.Equal(a.Choices, b.Choices)
}

func questionChanges(changes []aguiPatch, path string, old, next []Question) []aguiPatch {
	i := 0
	for i < min(len(old), len(next)) && equalQuestion(old[i], next[i]) {
		i++
	}
	a, b := len(old), len(next)
	for a > i && b > i && equalQuestion(old[a-1], next[b-1]) {
		a--
		b--
	}
	for ; i < min(a, b); i++ {
		if !equalQuestion(old[i], next[i]) {
			changes = append(changes, aguiPatch{"replace", path + "/" + strconv.Itoa(i), next[i]})
		}
	}
	for j := i; j < a; j++ {
		changes = append(changes, aguiPatch{"remove", path + "/" + strconv.Itoa(i), nil})
	}
	for ; i < b; i++ {
		changes = append(changes, aguiPatch{"add", path + "/" + strconv.Itoa(i), next[i]})
	}
	return changes
}

// A reader owns its projection. Console records are immutable once published.
// A history refresh can replace records with the same sequence, so compare the
// overlap before reusing messages. A tool update can change an earlier row.
type operationConsole struct {
	events   []ConsoleEvent
	messages []aguiMessage
	notice   string
}

// A blocked reader may fall behind the entire retention window. The next
// snapshot must distinguish that interval from a worker that simply went quiet.
func (p *operationConsole) checkContinuity(events []ConsoleEvent) {
	if len(events) == 0 {
		return
	}
	first := events[0].Sequence
	if len(p.events) == 0 {
		if first > 1 {
			p.notice = "Earlier output is outside the retained console preview. Open the worker's history for its available transcript."
		}
		return
	}
	last := p.events[len(p.events)-1].Sequence
	if first > last+1 {
		p.notice = fmt.Sprintf("The live console skipped events %d through %d. Open the worker's history for its available transcript.", last+1, first-1)
	}
}

func (p *operationConsole) project(worker string, events []ConsoleEvent) []aguiMessage {
	if slices.Equal(p.events, events) {
		return p.messages
	}
	old := p.events
	p.events = events
	start := 0
	for start < len(old) && len(events) > 0 && old[start].Sequence < events[0].Sequence {
		start++
	}
	overlap := old[start:]
	if len(overlap) > 0 && len(overlap) <= len(events) && slices.Equal(overlap, events[:len(overlap)]) &&
		plainConsole(old[:start]) && plainConsole(events[len(overlap):]) {
		keep := 0
		for keep < len(p.messages) && p.messages[keep].sequence < events[0].Sequence {
			keep++
		}
		p.messages = append(p.messages[keep:], aguiMessages(worker, events[len(overlap):])...)
	} else {
		p.messages = aguiMessages(worker, events)
	}
	return p.messages
}

type operationMessageStream struct {
	started  bool
	previous []aguiMessage
	// Number of ordinary text rows seen on this connection before the current
	// server window. A snapshot prunes these together at a bounded checkpoint.
	retired int
	cache   map[string]encodedOperationMessage
}

type encodedOperationMessage struct {
	message aguiMessage
	raw     []byte
}

type operationTextEvent struct {
	Type      string               `json:"type"`
	MessageID string               `json:"messageId"`
	Role      string               `json:"role,omitempty"`
	Metadata  *aguiMessageMetadata `json:"metadata,omitempty"`
	Delta     *string              `json:"delta,omitempty"`
}

func streamableText(m aguiMessage) bool {
	return (m.Role == "assistant" || m.Role == "user" || m.Role == "system") &&
		m.Content != nil && len(m.ToolCalls) == 0 && m.ToolCallID == "" && m.Error == ""
}

func appendOperationText(frame []byte, m aguiMessage) ([]byte, error) {
	events := [...]operationTextEvent{
		{Type: "TEXT_MESSAGE_START", MessageID: m.ID, Role: m.Role, Metadata: m.Metadata},
		{Type: "TEXT_MESSAGE_CONTENT", MessageID: m.ID, Delta: m.Content},
		{Type: "TEXT_MESSAGE_END", MessageID: m.ID},
	}
	for _, event := range events {
		payload, err := json.Marshal(event)
		if err != nil {
			return nil, err
		}
		frame = append(frame, "data: "...)
		frame = append(frame, payload...)
		frame = append(frame, '\n', '\n')
	}
	return frame, nil
}

func (p *operationMessageStream) frame(next []aguiMessage, incremental, active bool) ([]byte, error) {
	old := p.previous
	if p.started && (active || p.retired == 0) && slices.EqualFunc(old, next, equalMessage) {
		return nil, nil
	}
	if p.started && incremental && len(next) > 0 {
		// A gap from an earlier interval stays at the head of the view.
		window := next
		if len(old) > 0 && old[0].sequence == 0 && equalMessage(old[0], next[0]) {
			old, window = old[1:], next[1:]
		}
		start := 0
		// Ordinary text already delivered can stay visible until the next
		// checkpoint. Never retain a retired tool, a diagnostic gap or a
		// frontend call under a changed authority.
		for active && start < len(old) && len(window) > 0 && old[start].sequence > 0 &&
			old[start].sequence < window[0].sequence && streamableText(old[start]) {
			start++
		}
		overlap := old[start:]
		if (start == 0 || len(overlap) > 0) && p.retired+start <= consoleEventWindow && (active || p.retired == 0) &&
			len(overlap) < len(window) && slices.EqualFunc(overlap, window[:len(overlap)], equalMessage) {
			added := window[len(overlap):]
			if !slices.ContainsFunc(added, func(m aguiMessage) bool { return !streamableText(m) }) {
				var frame []byte
				for _, m := range added {
					var err error
					frame, err = appendOperationText(frame, m)
					if err != nil {
						return nil, err
					}
				}
				p.previous, p.retired = next, p.retired+start
				return frame, nil
			}
		}
	}
	// AG-UI requires an authoritative message snapshot for arbitrary edits
	// and ordinary tool calls. Reuse unchanged rows' JSON in that snapshot.
	cache := make(map[string]encodedOperationMessage, len(next))
	size := len("data: {\"type\":\"MESSAGES_SNAPSHOT\",\"messages\":[]}\n\n") + len(next)
	for _, m := range next {
		entry, ok := p.cache[m.ID]
		if !ok || !equalMessage(entry.message, m) {
			raw, err := json.Marshal(m)
			if err != nil {
				return nil, err
			}
			entry = encodedOperationMessage{m, raw}
		}
		cache[m.ID] = entry
		size += len(entry.raw)
	}
	frame := make([]byte, 0, size)
	frame = append(frame, `data: {"type":"MESSAGES_SNAPSHOT","messages":[`...)
	for i, m := range next {
		if i > 0 {
			frame = append(frame, ',')
		}
		frame = append(frame, cache[m.ID].raw...)
	}
	p.started, p.retired, p.previous, p.cache = true, 0, next, cache
	return append(frame, ']', '}', '\n', '\n'), nil
}

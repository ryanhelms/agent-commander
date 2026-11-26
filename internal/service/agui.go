package service

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"agentcommander/internal/acpprocessor"
)

// Commander multiplexes a workspace through AG-UI state events. Each worker
// carries its own list of protocol messages and its original console fallback.
type aguiMessageMetadata struct {
	ACP        *acpprocessor.Activity   `json:"acp"`
	ACPSources []*acpprocessor.Activity `json:"acpSources,omitempty"`
}

// Folded tool progress and results can each point at different source records.
// Keep their order while preserving the latest-reference field for older clients.
func (m *aguiMessage) recordSource(source *acpprocessor.Activity) {
	if source == nil {
		return
	}
	if m.Metadata == nil {
		m.Metadata = &aguiMessageMetadata{ACP: source}
		return
	}
	meta := m.Metadata
	previous := meta.ACP
	meta.ACP = source
	sameRecord := func(other *acpprocessor.Activity) bool {
		return other == source || (source.Cursor != "" && other.Source == source.Source && other.Cursor == source.Cursor)
	}
	if len(meta.ACPSources) == 0 {
		if !sameRecord(previous) {
			meta.ACPSources = []*acpprocessor.Activity{previous, source}
		}
		return
	}
	for i, ref := range meta.ACPSources {
		if sameRecord(ref) {
			meta.ACPSources[i] = source
			return
		}
	}
	meta.ACPSources = append(meta.ACPSources, source)
}

type aguiMessage struct {
	sequence   int
	Metadata   *aguiMessageMetadata `json:"metadata,omitempty"`
	ID         string               `json:"id"`
	Role       string               `json:"role"`
	Content    *string              `json:"content,omitempty"`
	ToolCalls  []aguiToolCall       `json:"toolCalls,omitempty"`
	ToolCallID string               `json:"toolCallId,omitempty"`
	Error      string               `json:"error,omitempty"`
}

type aguiToolCall struct {
	ID       string       `json:"id"`
	Type     string       `json:"type"`
	Function aguiFunction `json:"function"`
}

type aguiFunction struct {
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}

type aguiWorker struct {
	Worker
	Messages []aguiMessage `json:"messages,omitempty"`
}

func (worker *aguiWorker) projectMessages() {
	worker.Messages = aguiMessages(worker.ID, worker.Console)
	worker.Console = nil
}

type aguiRun struct {
	Run
	Workers []aguiWorker `json:"workers"`
}

type aguiWorkspace struct {
	Runs []json.RawMessage `json:"runs"`
}

type aguiPatch struct {
	Op    string `json:"op"`
	Path  string `json:"path"`
	Value any    `json:"value,omitempty"`
}

type aguiStateEvent struct {
	Type     string         `json:"type"`
	Snapshot *aguiWorkspace `json:"snapshot,omitempty"`
	Delta    []aguiPatch    `json:"delta,omitempty"`
}

func aguiMessages(workerID string, events []ConsoleEvent) []aguiMessage {
	var messages []aguiMessage
	type toolProjection struct {
		call, result      int
		detail, text      strings.Builder
		arguments, output string
	}
	tools := make(map[string]*toolProjection)
	type messageIdentity struct{ role, kind, id string }
	addressed := make(map[messageIdentity]int)
	for _, item := range events {
		message := aguiMessage{sequence: item.Sequence, ID: fmt.Sprintf("%s:%d", workerID, item.Sequence), Role: "assistant"}
		if activity := item.ACP; activity != nil && activity.MessageOp != "" && activity.MessageID != "" {
			switch item.Kind {
			case "user":
				message.Role = "user"
			case "output", "thinking":
				message.Role = "system"
			}
			identity := messageIdentity{message.Role, activity.Kind, activity.MessageID}
			if index, exists := addressed[identity]; exists {
				previous := &messages[index]
				content := item.Text
				if activity.MessageOp == "append" && previous.Content != nil {
					content = *previous.Content + content
				}
				previous.Content = &content
				previous.recordSource(activity)
			} else {
				message.Content = &item.Text
				message.recordSource(activity)
				addressed[identity] = len(messages)
				messages = append(messages, message)
			}
			continue
		}
		var tool *toolProjection
		var callID string
		if item.ToolID != "" && (item.Kind == "tool_call" || item.Kind == "tool_update" || item.Kind == "tool_result") {
			callID = workerID + ":" + item.ToolID
			tool = tools[callID]
			if tool == nil {
				tool = &toolProjection{call: -1, result: -1}
				tools[callID] = tool
			}
		}
		switch item.Kind {
		case "text":
			if item.Text == "" {
				continue
			}
			message.Content = &item.Text
		case "user":
			message.Role, message.Content = "user", &item.Text
		case "output", "thinking":
			message.Role, message.Content = "system", &item.Text
		case "tool_call", "tool_update":
			if tool == nil || (tool.call < 0 && item.Name == "") {
				text := item.TerminalText()
				message.Role, message.Content = "system", &text
				break
			}
			// Keep each progress message as detail. The result controls the
			// row's status, and the chronological console keeps the phases.
			if item.CommanderInput != "" {
				tool.arguments = item.CommanderInput
			} else if tool.arguments == "" && item.Name != "" {
				tool.arguments = item.Text
			}
			appendToolText(&tool.detail, item.Text)
			if tool.call >= 0 {
				messages[tool.call].recordSource(item.ACP)
				if item.Name != "" {
					messages[tool.call].ToolCalls[0].Function.Name = item.Name
				}
				continue
			}
			tool.call = len(messages)
			message.ToolCalls = []aguiToolCall{{ID: callID, Type: "function", Function: aguiFunction{Name: item.Name}}}
		case "tool_result":
			// A retained result can outlive its call. Carry the reference so
			// clients can still display the result and correlate it if possible.
			if tool == nil {
				message.Role, message.Content = "system", &item.Text
				break
			}
			appendToolText(&tool.text, item.TerminalText())
			if item.Text != "" {
				tool.output = item.Text
			}
			if tool.result >= 0 {
				messages[tool.result].recordSource(item.ACP)
				if failure := item.ToolFailure(); failure != "" {
					messages[tool.result].Error = failure
				}
				continue
			}
			tool.result = len(messages)
			message.Role, message.ToolCallID = "tool", callID
			message.Error = item.ToolFailure()
		default:
			continue
		}
		message.recordSource(item.ACP)
		messages = append(messages, message)
	}
	for _, tool := range tools {
		if tool.call >= 0 {
			function := &messages[tool.call].ToolCalls[0].Function
			detail := tool.detail.String()
			failed := tool.result >= 0 && messages[tool.result].Error != ""
			args, _ := json.Marshal(struct {
				Detail    string             `json:"detail,omitempty"`
				Commander *commanderActivity `json:"commander,omitempty"`
			}{detail, correlateCommanderTool(function.Name, tool.arguments, tool.output, failed)})
			function.Arguments = string(args)
		}
		if tool.result >= 0 {
			text := tool.text.String()
			messages[tool.result].Content = &text
		}
	}
	return messages
}

func appendToolText(out *strings.Builder, text string) {
	if text == "" {
		return
	}
	if out.Len() > 0 {
		out.WriteByte('\n')
	}
	out.WriteString(text)
}

func (s *service) streamConsole(w http.ResponseWriter, r *http.Request) {
	if _, supplied := r.Header["Authorization"]; supplied {
		respondError(w, denied())
		return
	}
	incremental := r.URL.Query().Get("projection") == "incremental"
	notify := make(chan struct{}, 1)
	s.mu.Lock()
	if s.consoleObservers == nil {
		s.consoleObservers = make(map[chan struct{}]struct{})
	}
	s.consoleObservers[notify] = struct{}{}
	if s.workspace == nil {
		s.workspace = &workspaceProjection{}
		s.workspace.rebuild(s.state.Runs)
	}
	feed := s.workspace
	feed.readers++
	if incremental {
		feed.incrementalReaders++
	}
	cursor := feed.revision
	initial, err := feed.snapshot(incremental, false)
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.consoleObservers, notify)
		feed.readers--
		if incremental {
			feed.incrementalReaders--
			if feed.incrementalReaders == 0 {
				feed.frames = nil
				feed.frameBytes = 0
			}
		}
		if feed.readers == 0 {
			s.workspace = nil
		}
		s.mu.Unlock()
	}()
	if err != nil {
		respondError(w, err)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	controller := http.NewResponseController(w)
	write := func(raw []byte) error {
		_ = controller.SetWriteDeadline(time.Now().Add(8 * time.Second))
		if _, err := w.Write(raw); err != nil {
			return err
		}
		return controller.Flush()
	}
	if write(initial) != nil {
		return
	}
	go s.restoreNativeHistories(context.WithoutCancel(r.Context()))
	heartbeat := time.NewTicker(5 * time.Second)
	defer heartbeat.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-heartbeat.C:
			if write([]byte(": heartbeat\n\n")) != nil {
				return
			}
		case <-notify:
			for {
				s.mu.Lock()
				frame, next, err := feed.next(cursor, incremental)
				s.mu.Unlock()
				if err != nil {
					return
				}
				if next == cursor {
					break
				}
				cursor = next
				if len(frame) > 0 && write(frame) != nil {
					return
				}
			}
		}
	}
}

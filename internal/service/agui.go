package service

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// Commander multiplexes a workspace through AG-UI state events. Each worker
// carries its own list of protocol messages and its original console fallback.
type aguiMessage struct {
	ID         string         `json:"id"`
	Role       string         `json:"role"`
	Content    *string        `json:"content,omitempty"`
	ToolCalls  []aguiToolCall `json:"toolCalls,omitempty"`
	ToolCallID string         `json:"toolCallId,omitempty"`
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
	Value any    `json:"value"`
}

type aguiStateEvent struct {
	Type     string         `json:"type"`
	Snapshot *aguiWorkspace `json:"snapshot,omitempty"`
	Delta    []aguiPatch    `json:"delta,omitempty"`
}

func aguiMessages(workerID string, events []ConsoleEvent) []aguiMessage {
	var messages []aguiMessage
	calls := make(map[string]bool)
	for _, item := range events {
		message := aguiMessage{ID: fmt.Sprintf("%s:%d", workerID, item.Sequence), Role: "assistant"}
		switch item.Kind {
		case "text":
			if item.Text == "" {
				continue
			}
			message.Content = &item.Text
		case "user":
			message.Role, message.Content = "user", &item.Text
		case "tool_call":
			if item.ToolID == "" || item.Name == "" || calls[item.ToolID] {
				continue
			}
			calls[item.ToolID] = true
			args, _ := json.Marshal(struct {
				Detail string `json:"detail,omitempty"`
			}{item.Text})
			message.ToolCalls = []aguiToolCall{{
				ID: item.ToolID, Type: "function",
				Function: aguiFunction{Name: item.Name, Arguments: string(args)},
			}}
		case "tool_result":
			// The retained window may start after a tool call. Leave its result
			// out of the structured transcript if it has no matching call.
			if !calls[item.ToolID] {
				continue
			}
			message.Role, message.ToolCallID, message.Content = "tool", item.ToolID, &item.Text
		default:
			continue
		}
		messages = append(messages, message)
	}
	return messages
}

// The ordered run list is append-only. A length change replaces the list; a
// normal update replaces only changed runs. Reconnects always start afresh.
func aguiDelta(old, next aguiWorkspace) []aguiPatch {
	if len(old.Runs) != len(next.Runs) {
		return []aguiPatch{{Op: "replace", Path: "/runs", Value: next.Runs}}
	}
	var delta []aguiPatch
	for i, run := range next.Runs {
		if !bytes.Equal(old.Runs[i], run) {
			delta = append(delta, aguiPatch{Op: "replace", Path: fmt.Sprintf("/runs/%d", i), Value: run})
		}
	}
	return delta
}

func (s *service) aguiSnapshot() (aguiWorkspace, error) {
	// Detach mutable records before encoding. Each retained Console slice is
	// append-only or replaced by output ingestion, so its existing elements
	// can safely be read after releasing the mutex.
	s.mu.Lock()
	runs := make([]aguiRun, 0, len(s.state.Runs))
	for _, run := range s.state.Runs {
		item := aguiRun{Run: *run, Workers: make([]aguiWorker, 0, len(run.Workers))}
		item.Run.Workers = nil
		item.Requests = make([]*Question, 0, len(run.Requests))
		for _, question := range run.Requests {
			copy := *question
			item.Requests = append(item.Requests, &copy)
		}
		for _, worker := range run.Workers {
			copy := *worker
			if worker.Control != nil {
				control := *worker.Control
				control.Messages = append([]WorkerFollowUp(nil), control.Messages...)
				copy.Control = &control
			}
			item.Workers = append(item.Workers, aguiWorker{Worker: copy})
		}
		runs = append(runs, item)
	}
	s.mu.Unlock()

	snapshot := aguiWorkspace{Runs: make([]json.RawMessage, 0, len(runs))}
	for _, run := range runs {
		for i := range run.Workers {
			worker := &run.Workers[i]
			worker.Messages = aguiMessages(worker.ID, worker.Console)
			worker.Console = nil
		}
		raw, err := json.Marshal(run)
		if err != nil {
			return aguiWorkspace{}, err
		}
		snapshot.Runs = append(snapshot.Runs, raw)
	}
	return snapshot, nil
}

func (s *service) streamConsole(w http.ResponseWriter, r *http.Request) {
	// The workspace stream is for the desktop owner on the private Unix socket.
	// Agents continue using the project-scoped API through MCP.
	if _, supplied := r.Header["Authorization"]; supplied {
		respondError(w, denied())
		return
	}
	notify := make(chan struct{}, 1)
	s.mu.Lock()
	if s.consoleObservers == nil {
		s.consoleObservers = make(map[chan struct{}]struct{})
	}
	s.consoleObservers[notify] = struct{}{}
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.consoleObservers, notify)
		s.mu.Unlock()
	}()

	current, err := s.aguiSnapshot()
	if err != nil {
		respondError(w, err)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	httpWriter := http.NewResponseController(w)
	write := func(frame string) error {
		// A disconnected or stalled observer must not block service writes.
		_ = httpWriter.SetWriteDeadline(time.Now().Add(8 * time.Second))
		if _, err := fmt.Fprint(w, frame); err != nil {
			return err
		}
		return httpWriter.Flush()
	}
	send := func(event aguiStateEvent) error {
		raw, err := json.Marshal(event)
		if err != nil {
			return err
		}
		return write("data: " + string(raw) + "\n\n")
	}
	if err := send(aguiStateEvent{Type: "STATE_SNAPSHOT", Snapshot: &current}); err != nil {
		return
	}

	// A second subscriber can arrive before its predecessor's read finishes.
	// Share that bounded read across reconnects, including after the first
	// subscriber closes its stream.
	go s.restoreNativeHistories(context.WithoutCancel(r.Context()))

	heartbeat := time.NewTicker(5 * time.Second)
	defer heartbeat.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-heartbeat.C:
			if write(": heartbeat\n\n") != nil {
				return
			}
		case <-notify:
			next, err := s.aguiSnapshot()
			if err != nil {
				return
			}
			delta := aguiDelta(current, next)
			if len(delta) > 0 {
				if send(aguiStateEvent{Type: "STATE_DELTA", Delta: delta}) != nil {
					return
				}
				current = next
			}
		}
	}
}

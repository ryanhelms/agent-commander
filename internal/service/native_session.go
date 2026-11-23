package service

import (
	"context"
	"net/http"
	"strings"
	"time"
	"unicode"
)

// NativeSession is the provider-issued identity the local runner received at open.
type NativeSession struct {
	HarnessInstance string `json:"harness_instance"`
	SessionID       string `json:"session_id"`
}

type nativeHistoryReader interface {
	ReadConsoleHistory(context.Context, NativeSession, string) ([]ConsoleEvent, error)
}

type QuestionChoice struct {
	ID    string `json:"id"`
	Label string `json:"label"`
}

func validateChoices(choices []QuestionChoice) error {
	if len(choices) > 32 {
		return bad("too many choices")
	}
	seen := map[string]bool{}
	for _, c := range choices {
		if c.ID == "" || len(c.ID) > 256 || strings.TrimSpace(c.Label) == "" || len(c.Label) > 512 ||
			strings.IndexFunc(c.ID, unicode.IsControl) >= 0 || seen[c.ID] {
			return bad("each choice requires a unique ID and a label")
		}
		seen[c.ID] = true
	}
	return nil
}

func formatQuestion(prompt string, choices []QuestionChoice) string {
	if len(choices) == 0 {
		return prompt
	}
	var out strings.Builder
	out.WriteString(prompt)
	out.WriteString("\nReply with one of the IDs in brackets.")
	for _, c := range choices {
		out.WriteString("\n" + c.Label + " [" + c.ID + "]")
	}
	return out.String()
}

func (s *service) bindNativeSession(req *http.Request, actor string) (outcome, error) {
	// Only the local owner/runner can bind history. Agent tokens can never
	// point a worker at another transcript on the developer's machine.
	if actor != "" {
		return outcome{}, denied()
	}
	r, w := s.worker(req.PathValue("worker"))
	if w == nil {
		return outcome{}, missing("worker")
	}
	var ref NativeSession
	if err := decode(req, &ref); err != nil {
		return outcome{}, err
	}
	if ref.HarnessInstance == "" || len(ref.HarnessInstance) > 256 || ref.SessionID == "" || len(ref.SessionID) > 512 || strings.IndexFunc(ref.SessionID, unicode.IsControl) >= 0 {
		return outcome{}, bad("a native harness and session ID are required")
	}
	if w.NativeSession != nil {
		if *w.NativeSession == ref {
			return read(ref), nil
		}
		return outcome{}, conflict("worker is already bound to a different session")
	}
	if r.Status != "running" || w.State == "stopping" || ended(w.State) {
		return outcome{}, conflict("this worker cannot register a new session")
	}
	for _, run := range s.state.Runs {
		for _, other := range run.Workers {
			if other.NativeSession != nil && *other.NativeSession == ref {
				return outcome{}, conflict("session is already bound to another worker")
			}
		}
	}
	w.NativeSession = &ref
	return changed(ref), nil
}

// Preserve the old disk format for existing CLI sessions. For SDK sessions
// the transcript lives with the harness. Output and Console are live views.
func (s *service) durableState() database {
	db := s.state
	db.Runs = make([]*Run, len(s.state.Runs))
	for i, r := range s.state.Runs {
		run := *r
		run.Workers = make([]*Worker, len(r.Workers))
		for j, w := range r.Workers {
			run.Workers[j] = w
			if w.NativeSession == nil {
				continue
			}
			durable := *w
			durable.Output, durable.Console = "", nil
			if w.Control != nil {
				control := *w.Control
				control.Messages = append([]WorkerFollowUp(nil), control.Messages...)
				for k := range control.Messages {
					m := &control.Messages[k]
					if m.Status != "queued" && m.Status != "processing" && m.Status != "delivery_unknown" {
						m.Text = ""
					}
				}
				durable.Control = &control
			}
			run.Workers[j] = &durable
		}
		db.Runs[i] = &run
	}
	return db
}

type historyTarget struct {
	id, cwd, state string
	ref            NativeSession
	sequence       int
}

func lastSequence(w *Worker) int {
	if n := len(w.Console); n != 0 {
		return w.Console[n-1].Sequence
	}
	return 0
}

// A reconnect reads an inactive conversation from its native source. Never
// hold the command lock during I/O or replace newly arrived live events.
func (s *service) restoreNativeHistories(ctx context.Context) {
	reader, ok := s.launcher.(nativeHistoryReader)
	if !ok {
		return
	}
	s.mu.Lock()
	if s.readingHistory == nil {
		s.readingHistory = make(map[string]bool)
	}
	var targets []historyTarget
	for _, run := range s.state.Runs {
		for _, w := range run.Workers {
			if w.NativeSession == nil || s.readingHistory[w.ID] || turnActive(w.State) && len(w.Console) != 0 {
				continue
			}
			targets = append(targets, historyTarget{w.ID, w.Worktree, w.State, *w.NativeSession, lastSequence(w)})
			s.readingHistory[w.ID] = true
		}
	}
	s.mu.Unlock()
	// Sequential reads bound subprocess use when opening a workspace with many runs.
	for _, t := range targets {
		var events []ConsoleEvent
		var err error
		if ctx.Err() == nil {
			queryCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
			events, err = reader.ReadConsoleHistory(queryCtx, t.ref, t.cwd)
			cancel()
		}
		s.mu.Lock()
		delete(s.readingHistory, t.id)
		_, w := s.worker(t.id)
		if ctx.Err() == nil && w != nil && w.NativeSession != nil && *w.NativeSession == t.ref && w.State == t.state && lastSequence(w) == t.sequence {
			if err == nil && len(events) > 0 {
				w.Console = events
				var out strings.Builder
				for _, e := range events {
					out.WriteString(e.Text)
					out.WriteByte('\n')
				}
				w.Output = out.String()
				s.notifyConsole()
			} else if err != nil && len(w.Console) == 0 && w.Output == "" {
				w.Output = "Native history is unavailable. Reconnect to retry."
				s.notifyConsole()
			}
		}
		s.mu.Unlock()
	}
}

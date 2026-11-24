package service

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode"

	model "agent-acp.local/sdks/go/model"
	"google.golang.org/protobuf/encoding/protojson"

	"agentcommander/internal/acpprocessor"
	"agentcommander/internal/hosted"
)

// NativeSession is the provider-issued identity the local runner received at open.
type NativeSession struct {
	HarnessInstance string `json:"harness_instance"`
	SessionID       string `json:"session_id"`
}

type nativeHistoryReader interface {
	ReadConsoleHistory(context.Context, NativeSession, string) ([]ConsoleEvent, error)
}

type nativeHistoryPager interface {
	ReadNativeHistoryPage(context.Context, NativeSession, string, string, uint32) (json.RawMessage, error)
}

type nativeHistoryRecordReader interface {
	ReadNativeHistoryRecord(context.Context, NativeSession, string, string, string) (json.RawMessage, error)
}

type nativeJournalPager interface {
	ReadNativeJournalPage(context.Context, NativeSession, string, string, uint32) (json.RawMessage, error)
}

type stoppedHistoryPolicy interface {
	RequiresStoppedHistory(NativeSession) bool
}

func (s *service) requiresStoppedHistory(ref NativeSession) bool {
	policy, ok := s.launcher.(stoppedHistoryPolicy)
	return ok && policy.RequiresStoppedHistory(ref)
}

func (s *service) serveNativeHistoryPage(w http.ResponseWriter, req *http.Request) {
	if _, supplied := req.Header["Authorization"]; supplied {
		respondError(w, denied())
		return
	}
	query := req.URL.Query()
	source := query.Get("source")
	if source == "provider" {
		source = ""
	}
	view := query.Get("view")
	if view != "" && (view != "acp" || source == "journal") {
		respondError(w, bad("the ACP view requires live or provider history"))
		return
	}
	if source != "" && source != "journal" && source != "live" {
		respondError(w, bad("unknown native history source"))
		return
	}
	turnID := query.Get("turnId")
	if query.Has("turnId") && (source != "live" || turnID == "" || len(turnID) > 256 ||
		strings.IndexFunc(turnID, unicode.IsControl) >= 0) {
		respondError(w, bad("turnId requires a live ACP source and a valid turn ID"))
		return
	}
	cursor := query.Get("cursor")
	kind := query.Get("kind")
	if query.Has("kind") && (kind != LivePromptMediaPartKind || source != "live" || turnID == "") {
		respondError(w, bad("prompt attachments require a live source and turnId"))
		return
	}
	limit := uint64(32)
	if query.Has("limit") {
		parsed, err := strconv.ParseUint(query.Get("limit"), 10, 32)
		if err != nil || parsed == 0 || parsed > 128 {
			respondError(w, bad("history limit must be between 1 and 128"))
			return
		}
		limit = parsed
	}
	if len(cursor) > acpprocessor.ProviderCursorLimit {
		respondError(w, bad("history cursor exceeds size limit"))
		return
	}
	recordCursor := query.Get("recordCursor")
	if query.Has("recordCursor") && (recordCursor == "" || len(recordCursor) > acpprocessor.ProviderCursorLimit ||
		strings.IndexFunc(recordCursor, unicode.IsControl) >= 0 || source != "" || query.Has("limit")) {
		respondError(w, bad("recordCursor requires provider history, a nonempty record identity and no page limit"))
		return
	}
	s.mu.Lock()
	_, worker := s.worker(req.PathValue("worker"))
	if worker == nil {
		s.mu.Unlock()
		respondError(w, missing("worker"))
		return
	}
	if worker.NativeSession == nil {
		s.mu.Unlock()
		respondError(w, &apiError{http.StatusNotImplemented, "worker has no native history binding"})
		return
	}
	ref, cwd, workerID := *worker.NativeSession, worker.Worktree, worker.ID
	replayNotReady := source == "" && s.requiresStoppedHistory(ref) && worker.State != "stopped"
	s.mu.Unlock()

	var read func(context.Context, NativeSession, string, string, uint32) (json.RawMessage, error)
	if source == "live" {
		read = func(_ context.Context, ref NativeSession, _ string, cursor string, limit uint32) (json.RawMessage, error) {
			s.mu.Lock()
			page, err := s.liveSource.page(workerID, ref, turnID, kind, cursor, int(limit))
			s.mu.Unlock()
			if err != nil {
				return nil, err
			}
			return (protojson.MarshalOptions{EmitDefaultValues: true}).Marshal(page)
		}
	} else if source == "journal" {
		if reader, ok := s.launcher.(nativeJournalPager); ok {
			read = reader.ReadNativeJournalPage
		}
	} else if recordCursor != "" {
		if reader, ok := s.launcher.(nativeHistoryRecordReader); ok {
			read = func(ctx context.Context, selected NativeSession, cwd, hint string, _ uint32) (json.RawMessage, error) {
				return reader.ReadNativeHistoryRecord(ctx, selected, cwd, hint, recordCursor)
			}
		}
	} else if reader, ok := s.launcher.(nativeHistoryPager); ok {
		read = reader.ReadNativeHistoryPage
	}
	if read == nil {
		respondError(w, &apiError{http.StatusNotImplemented, "native history paging is unavailable"})
		return
	}
	ctx, cancel := context.WithTimeout(req.Context(), 20*time.Second)
	defer cancel()
	var page json.RawMessage
	var err error
	if replayNotReady {
		page, err = (protojson.MarshalOptions{EmitDefaultValues: true}).Marshal(&model.ReadHistoryResponse{
			Observations: []*model.Observation{{Session: &model.SessionRef{HarnessInstance: ref.HarnessInstance, SessionId: ref.SessionID},
				Event: &model.Observation_Gap{Gap: &model.HistoryGap{Reason: "Provider replay becomes available after this worker stops"}}}},
		})
	} else {
		page, err = read(ctx, ref, cwd, cursor, uint32(limit))
	}
	if err != nil {
		if source == "live" {
			respondError(w, err)
			return
		}
		// Provider diagnostics may contain session paths or subprocess output.
		respondError(w, &apiError{http.StatusServiceUnavailable, "native history page is unavailable"})
		return
	}
	if view == "acp" {
		page, err = acpprocessor.HistoryView(page)
		if err != nil {
			respondError(w, &apiError{http.StatusBadGateway, "could not decode the ACP history page"})
			return
		}
	}
	if access := hosted.From(req.Context()); access != nil && !access.Allowed() {
		respondError(w, denied())
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(page)
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
	if len(db.OutputBatches) != 0 {
		db.OutputBatches = make(map[string]outputReceipt, len(s.state.OutputBatches))
	}
	db.Runs = make([]*Run, len(s.state.Runs))
	for i, r := range s.state.Runs {
		run := *r
		run.Workers = make([]*Worker, len(r.Workers))
		for j, w := range r.Workers {
			run.Workers[j] = w
			if w.NativeSession == nil {
				if receipt, ok := s.state.OutputBatches[w.ID]; ok {
					db.OutputBatches[w.ID] = receipt
				}
				continue
			}
			durable := *w
			durable.Output, durable.Console, durable.Telemetry = "", nil, nil
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
			if w.NativeSession == nil || s.readingHistory[w.ID] || len(w.Console) != 0 {
				continue
			}
			if s.requiresStoppedHistory(*w.NativeSession) && w.State != "stopped" {
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
		// A stop can finish while reopening the transcript. That changes the
		// assignment's state, but leaves its native conversation and console intact.
		if ctx.Err() == nil && w != nil && w.NativeSession != nil && *w.NativeSession == t.ref &&
			(w.State == t.state || !turnActive(w.State) && !turnActive(t.state)) && lastSequence(w) == t.sequence {
			if err == nil && len(events) > 0 {
				w.Console = events
				var out strings.Builder
				for _, e := range events {
					out.WriteString(e.TerminalText())
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

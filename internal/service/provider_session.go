package service

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode"

	"agentcommander/internal/acpprocessor"
	"agentcommander/internal/hosted"
)

const providerReattaching = "reattaching"

// ProviderSessionScope is the frozen worker identity used for discovery and
// reattachment. Service callers select a worker rather than supplying a path
// or an arbitrary native session ID.
type ProviderSessionScope struct {
	LaunchSpec
	Ref             NativeSession
	ProviderBinding string
}

type ProviderSessionSummary struct {
	SessionID string `json:"session_id"`
	Title     string `json:"title,omitempty"`
}

type ProviderSessionPage struct {
	Sessions   []ProviderSessionSummary `json:"sessions"`
	NextCursor string                   `json:"next_cursor"`
}

type providerSessionLauncher interface {
	ListProviderSessions(context.Context, ProviderSessionScope, string, uint32) (ProviderSessionPage, error)
	ProviderHistoryAvailability(NativeSession) string
}

type reattachRequest struct {
	Generation                 int  `json:"generation"`
	AcknowledgeDeliveryUnknown bool `json:"acknowledge_delivery_unknown"`
}

type ReattachSpec struct {
	Ref             NativeSession
	ProviderBinding string
	Generation      int
}

type providerSessionStatus struct {
	PeerCapabilities *SessionCapabilities `json:"peer_capabilities,omitempty"`
	CanDiscover      bool                 `json:"can_discover"`
	CanReattach      bool                 `json:"can_reattach"`
	History          string               `json:"history"`
	Generation       int                  `json:"generation,omitempty"`
	DeliveryUnknown  int                  `json:"delivery_unknown"`
}

func localSessionOwner(req *http.Request) bool {
	_, supplied := req.Header["Authorization"]
	return !supplied && hosted.From(req.Context()) == nil
}

func sessionLaunchSpec(r *Run, w *Worker) LaunchSpec {
	return LaunchSpec{
		ID: w.ID, RunID: r.ID, ParentID: w.ParentID, Name: w.Name, Task: w.Task,
		Role: w.Role, Path: w.Worktree, Worktree: w.Worktree, Host: w.Host, Client: w.Client, CodingSource: w.Coding,
	}
}

func (s *service) sessionStatus(r *Run, w *Worker) providerSessionStatus {
	status := providerSessionStatus{PeerCapabilities: w.PeerCapabilities, History: "unavailable"}
	if w.Control != nil {
		status.Generation = w.Control.Generation
		if status.PeerCapabilities == nil {
			status.PeerCapabilities = w.Control.SessionCapabilities
		}
		for _, operation := range w.Control.Messages {
			if operation.Status == "delivery_unknown" {
				status.DeliveryUnknown++
			}
		}
		if intr := w.Control.Interrupt; intr != nil && (intr.Phase == "unconfirmed" || intr.Outcome == "unknown") {
			status.DeliveryUnknown++
		}
	}
	provider, supported := s.launcher.(providerSessionLauncher)
	if !supported || w.NativeSession == nil {
		return status
	}
	status.History = provider.ProviderHistoryAvailability(*w.NativeSession)
	if status.History == "after_stop" && w.State == "stopped" {
		status.History = "available"
	}
	if w.ProviderBinding == "" || (w.Host != "" && w.Host != "localhost") || status.PeerCapabilities == nil {
		return status
	}
	status.CanDiscover = status.PeerCapabilities.CanListSessions
	activeOtherWorkers := r.activeWorkers()
	if !ended(w.State) {
		activeOtherWorkers--
	}
	status.CanReattach = status.PeerCapabilities.CanResume && w.Role == "worker" && w.Control != nil &&
		!w.Control.Held && !w.Control.hasProcessingMessage() && w.Control.next() == nil &&
		(w.State == "stopped" || w.ProviderAvailability == providerExited && !turnActive(w.State)) &&
		(r.Status == "running" || r.Status == "completed" || r.Status == "stopped") &&
		activeOtherWorkers < r.WorkerLimit && !s.readingHistory[w.ID] && s.stoppedHistoryReads[w.ID] == 0
	return status
}

func (s *service) getProviderSessionStatus(req *http.Request, _ string) (outcome, error) {
	if !localSessionOwner(req) {
		return outcome{}, denied()
	}
	r, w := s.worker(req.PathValue("worker"))
	if w == nil {
		return outcome{}, missing("worker")
	}
	return read(s.sessionStatus(r, w)), nil
}

func (s *service) listProviderSessions(w http.ResponseWriter, req *http.Request) {
	if !localSessionOwner(req) {
		respondError(w, denied())
		return
	}
	cursor := req.URL.Query().Get("cursor")
	if len(cursor) > acpprocessor.ProviderCursorLimit || strings.IndexFunc(cursor, unicode.IsControl) >= 0 {
		respondError(w, bad("invalid provider session cursor"))
		return
	}
	limit := uint64(32)
	if req.URL.Query().Has("limit") {
		parsed, err := strconv.ParseUint(req.URL.Query().Get("limit"), 10, 32)
		if err != nil || parsed == 0 || parsed > 128 {
			respondError(w, bad("provider session limit must be between 1 and 128"))
			return
		}
		limit = parsed
	}
	s.mu.Lock()
	r, worker := s.worker(req.PathValue("worker"))
	if worker == nil {
		s.mu.Unlock()
		respondError(w, missing("worker"))
		return
	}
	if !s.sessionStatus(r, worker).CanDiscover {
		s.mu.Unlock()
		respondError(w, conflict("the selected worker's provider cannot list sessions"))
		return
	}
	scope := ProviderSessionScope{sessionLaunchSpec(r, worker), *worker.NativeSession, worker.ProviderBinding}
	s.mu.Unlock()

	ctx, cancel := context.WithTimeout(req.Context(), 20*time.Second)
	defer cancel()
	page, err := s.launcher.(providerSessionLauncher).ListProviderSessions(ctx, scope, cursor, uint32(limit))
	if err != nil {
		respondError(w, &apiError{http.StatusServiceUnavailable, "provider session discovery is unavailable"})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(page)
}

func (s *service) reattachWorker(req *http.Request, actor string) (outcome, error) {
	if !localSessionOwner(req) {
		return outcome{}, denied()
	}
	r, w, err := s.controlTarget(req, actor)
	if err != nil {
		return outcome{}, err
	}
	var input reattachRequest
	if err := decode(req, &input); err != nil {
		return outcome{}, err
	}
	key, intent, target, err := s.receipt(req, actor, input)
	if err != nil {
		return outcome{}, err
	}
	if key == "" || input.Generation <= 0 {
		return outcome{}, bad("an idempotency key and a positive control generation are required")
	}
	if target == w.ID {
		return read(w), nil
	}
	status := s.sessionStatus(r, w)
	if !status.CanReattach || status.Generation != input.Generation {
		return outcome{}, conflict("the provider binding or control lease is no longer available for reattachment")
	}
	if status.DeliveryUnknown != 0 && !input.AcknowledgeDeliveryUnknown {
		return outcome{}, conflict("acknowledge the unresolved delivery before reattaching")
	}

	spec := sessionLaunchSpec(r, w)
	w.Control.Generation++
	w.Control.Held = true
	w.Control.ActiveTurnID = ""
	w.State, w.Error, w.ProviderAvailability = "starting", "", providerReattaching
	r.Status = "running"
	r.cancelQuestions(w.ID)
	for token, id := range s.state.Tokens {
		if id == w.ID {
			delete(s.state.Tokens, token)
		}
	}
	spec.Token = randomID("") + randomID("")
	s.state.Tokens[digest(spec.Token)] = w.ID
	spec.Reattach = &ReattachSpec{*w.NativeSession, w.ProviderBinding, w.Control.Generation}
	s.remember(key, intent, w.ID)
	return outcome{w, http.StatusAccepted, true, func() { s.launch(spec) }}, nil
}

func (s *service) readyReattachedWorker(req *http.Request, actor string) (outcome, error) {
	r, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	var input struct {
		ReattachSpec
		PromptCapabilities  PromptCapabilities
		SessionCapabilities SessionCapabilities `json:"session_capabilities"`
	}
	if err := decode(req, &input); err != nil {
		return outcome{}, err
	}
	if w.NativeSession == nil || *w.NativeSession != input.Ref || w.ProviderBinding != input.ProviderBinding ||
		w.Control == nil || w.Control.Generation != input.Generation || !w.Control.Held {
		return outcome{}, conflict("reattachment does not match the reserved provider and control lease")
	}
	if w.ProviderAvailability == providerAvailable && w.State == "idle" {
		return read(w), nil
	}
	if w.ProviderAvailability != providerReattaching || (w.State != "starting" && w.State != "unknown") {
		return outcome{}, conflict("worker does not have a matching pending reattachment")
	}
	w.State, w.Error, w.ProviderAvailability = "idle", "", providerAvailable
	w.Control.PromptCapabilities = &input.PromptCapabilities
	w.Control.SessionCapabilities, w.PeerCapabilities = &input.SessionCapabilities, &input.SessionCapabilities
	r.refreshOutcome()
	return changed(w), nil
}

func failReattachment(r *Run, w *Worker, detail string) {
	w.State, w.Error, w.ProviderAvailability = "stopped", detail, providerExited
	w.Control.Held = false
	r.refreshOutcome()
}

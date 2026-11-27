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

// LegacyClaudeHarness identifies the original Claude CLI runner, whose native
// session is a local journal UUID rather than an ACP adapter binding.
const LegacyClaudeHarness = "local-claude-cli"

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

type legacyProviderSessionLauncher interface {
	RecoverLegacyCoordinator(context.Context, LaunchSpec, string) (NativeSession, string, error)
}

type legacySessionProof struct {
	ref     NativeSession
	binding string
}

// Legacy recovery verifies native evidence outside the service lock and
// rechecks that the original identity is still selected on redispatch.
func (s *service) legacyCoordinator(req *http.Request, r *Run, w *Worker) (*legacySessionProof, error) {
	resolver, supported := s.launcher.(legacyProviderSessionLauncher)
	if !supported || w.NativeSession != nil || w.ID != r.CoordinatorID || w.Role != "coordinator" ||
		(w.Host != "" && w.Host != "localhost") ||
		(!strings.EqualFold(w.Client, "claude") && !strings.EqualFold(w.Client, "claude code")) {
		return nil, nil
	}
	spec, created := sessionLaunchSpec(r, w), w.CreatedAt
	if prepared, ok := req.Context().Value(launchCheckKey{}).(launchPreparation); ok {
		if prepared.legacySpec != spec {
			return nil, conflict("coordinator changed during native session verification")
		}
		return prepared.legacy, nil
	}
	return nil, &launchCheck{prepare: func(ctx context.Context) launchPreparation {
		out := launchPreparation{legacySpec: spec}
		ref, binding, err := resolver.RecoverLegacyCoordinator(ctx, spec, created)
		if err == nil && ref.HarnessInstance == LegacyClaudeHarness && ref.SessionID != "" && binding != "" {
			out.legacy = &legacySessionProof{ref, binding}
		}
		return out
	}}
}

func withLegacySession(w *Worker, proof *legacySessionProof) *Worker {
	if proof == nil {
		return w
	}
	candidate := *w
	candidate.NativeSession, candidate.ProviderBinding = &proof.ref, proof.binding
	candidate.PeerCapabilities = &SessionCapabilities{CanResume: true, CanInterrupt: true}
	return &candidate
}

type reattachRequest struct {
	Generation                 int  `json:"generation"`
	AcknowledgeDeliveryUnknown bool `json:"acknowledge_delivery_unknown"`
}

type ReattachSpec struct {
	Ref             NativeSession
	ProviderBinding string
	Generation      int
	ProtocolVersion int `json:"protocol_version,omitempty"`
}

type providerSessionStatus struct {
	PeerCapabilities *SessionCapabilities `json:"peer_capabilities,omitempty"`
	NativeSession    *NativeSession       `json:"native_session,omitempty"`
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
	status := providerSessionStatus{PeerCapabilities: w.PeerCapabilities, NativeSession: w.NativeSession, History: "unavailable"}
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
	coordinator := w.Role == "coordinator" && w.ID == r.CoordinatorID
	controlAvailable := w.Control != nil && !w.Control.Held && !w.Control.hasProcessingMessage() && w.Control.next() == nil
	inactive := w.State == "stopped" || w.ProviderAvailability == providerExited && !turnActive(w.State)
	hasSlot := r.activeWorkers() < r.WorkerLimit
	if w.Role == "worker" && !ended(w.State) {
		hasSlot = r.activeWorkers()-1 < r.WorkerLimit
	}
	if coordinator {
		controlAvailable = w.Control == nil || controlAvailable
		inactive = inactive || w.State == "completed"
		hasSlot = true
		if status.Generation == 0 {
			status.Generation = 1
		}
	}
	status.CanReattach = status.PeerCapabilities.CanResume && (w.Role == "worker" || coordinator) &&
		controlAvailable && inactive && hasSlot &&
		(r.Status == "running" || r.Status == "completed" || r.Status == "stopped") &&
		!s.readingHistory[w.ID] && s.stoppedHistoryReads[w.ID] == 0
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
	proof, err := s.legacyCoordinator(req, r, w)
	if err != nil {
		return outcome{}, err
	}
	return read(s.sessionStatus(r, withLegacySession(w, proof))), nil
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
	r, w := s.worker(req.PathValue("worker"))
	if w == nil {
		return outcome{}, missing("worker")
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
	proof, err := s.legacyCoordinator(req, r, w)
	if err != nil {
		return outcome{}, err
	}
	candidate := withLegacySession(w, proof)
	status := s.sessionStatus(r, candidate)
	if !status.CanReattach || status.Generation != input.Generation {
		return outcome{}, conflict("the provider binding or control lease is no longer available for reattachment")
	}
	if status.DeliveryUnknown != 0 && !input.AcknowledgeDeliveryUnknown {
		return outcome{}, conflict("acknowledge the unresolved delivery before reattaching")
	}

	if proof != nil {
		for _, run := range s.state.Runs {
			for _, other := range run.Workers {
				if other.NativeSession != nil && *other.NativeSession == proof.ref {
					return outcome{}, conflict("native session is already bound")
				}
			}
		}
		w.NativeSession, w.ProviderBinding, w.PeerCapabilities = candidate.NativeSession, candidate.ProviderBinding, candidate.PeerCapabilities
	}
	spec := sessionLaunchSpec(r, w)
	if w.Control == nil {
		w.Control = &WorkerControl{Generation: status.Generation}
	}
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
	spec.Reattach = &ReattachSpec{
		Ref: *w.NativeSession, ProviderBinding: w.ProviderBinding, Generation: w.Control.Generation,
		ProtocolVersion: status.PeerCapabilities.ProtocolVersion,
	}
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

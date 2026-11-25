package service

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"time"
)

const MaxWorkerControlWait = 25 * time.Second

// ACPSessionPermissionScope addresses ACP v2 permissions that may outlive one
// foreground turn. The service derives its availability from the peer binding.
const ACPSessionPermissionScope = "$session"

type workerControlAnswer struct {
	ID              string `json:"id"`
	ProviderRequest string `json:"provider_request"`
	Choice          string `json:"choice"`
}

func activeProviderTurn(w *Worker) string {
	if w.NativeSession == nil || !turnActive(w.State) && w.State != "unknown" {
		return ""
	}
	if w.Control != nil && w.Control.ActiveTurnID != "" {
		return w.Control.ActiveTurnID
	}
	return "initial-" + w.ID
}

func (s *service) retireProviderPermissions(run *Run, workerID string) {
	for _, q := range run.Requests {
		if q.WorkerID == workerID {
			delete(s.state.Permissions, q.ID)
		}
	}
}

func (s *service) waitWorkerControl(w http.ResponseWriter, req *http.Request) {
	query := req.URL.Query()
	after, turn := query.Get("after"), query.Get("turn")
	wait := time.Duration(0)
	if raw := query.Get("wait_seconds"); raw != "" {
		seconds, err := strconv.Atoi(raw)
		if err != nil || seconds < 0 || seconds > int(MaxWorkerControlWait/time.Second) {
			respondError(w, bad("wait_seconds must be between 0 and 25"))
			return
		}
		wait = time.Duration(seconds) * time.Second
	}
	if len(after) > 128 || len(turn) > 256 {
		respondError(w, bad("invalid worker control revision or turn"))
		return
	}
	ctx, cancel := context.WithTimeout(req.Context(), wait)
	defer cancel()
	workerID := req.PathValue("worker")
	for {
		s.mu.Lock()
		actor, err := s.requestActor(req)
		var feed workerControlFeed
		if err == nil {
			feed, err = s.workerControlSnapshot(workerID, actor, turn)
		}
		if err != nil {
			s.mu.Unlock()
			respondError(w, err)
			return
		}
		body, _ := json.Marshal(feed)
		feed.Revision = digest(s.consoleInstance + "\x00" + workerID + "\x00" + turn + "\x00" + string(body))
		if feed.Revision != after || ctx.Err() != nil {
			s.mu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(feed)
			return
		}
		if s.controlChanged == nil {
			s.controlChanged = make(chan struct{})
		}
		changed := s.controlChanged
		s.mu.Unlock()
		select {
		case <-changed:
		case <-ctx.Done():
			if req.Context().Err() != nil {
				return
			}
		}
	}
}

func (s *service) finishTurnPermissions(run *Run, worker *Worker, failed bool) {
	for _, question := range run.Requests {
		if question.WorkerID != worker.ID {
			continue
		}
		permission := s.state.Permissions[question.ID]
		if !failed && permission.Turn == ACPSessionPermissionScope {
			continue
		}
		if question.Status == "pending" {
			question.Status = "cancelled"
		}
		delete(s.state.Permissions, question.ID)
	}
}

func (s *service) dismissProviderPermission(request *http.Request, actor string) (outcome, error) {
	run, worker, err := s.own(request, actor)
	if err != nil {
		return outcome{}, err
	}
	var input struct {
		ProviderRequest string `json:"provider_request"`
	}
	if err := decode(request, &input); err != nil {
		return outcome{}, err
	}
	if input.ProviderRequest == "" || len(input.ProviderRequest) > 256 {
		return outcome{}, bad("invalid provider permission request")
	}
	for _, question := range run.Requests {
		permission := s.state.Permissions[question.ID]
		if question.WorkerID != worker.ID || permission.Request != input.ProviderRequest ||
			permission.Turn != ACPSessionPermissionScope {
			continue
		}
		delete(s.state.Permissions, question.ID)
		if question.Status == "pending" {
			question.Status = "cancelled"
		}
		return changed(question), nil
	}
	return read(struct{}{}), nil
}

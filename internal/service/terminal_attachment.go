package service

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"agentcommander/internal/hosted"
)

// TerminalAttachment identifies the local tmux session hosting a managed runner.
// The harness behind that runner may execute on an SSH host.
type TerminalAttachment struct {
	WorkerID   string `json:"worker_id"`
	SocketPath string `json:"socket_path"`
	SessionID  string `json:"session_id"`
}

type terminalResolver interface {
	ResolveTerminal(context.Context, string) (TerminalAttachment, error)
}

func (s *service) serveTerminalAttachment(w http.ResponseWriter, req *http.Request) {
	if _, supplied := req.Header["Authorization"]; supplied || hosted.From(req.Context()) != nil {
		respondError(w, denied())
		return
	}
	id := req.PathValue("worker")
	s.mu.Lock()
	_, worker := s.worker(id)
	found := worker != nil
	s.mu.Unlock()
	if !found {
		respondError(w, missing("worker"))
		return
	}
	resolver, ok := s.launcher.(terminalResolver)
	if !ok {
		respondError(w, &apiError{http.StatusNotImplemented, "native terminal viewing requires a managed tmux runner"})
		return
	}
	ctx, cancel := context.WithTimeout(req.Context(), 3*time.Second)
	defer cancel()
	target, err := resolver.ResolveTerminal(ctx, id)
	if err != nil || target.WorkerID != id {
		respondError(w, conflict("the original dedicated tmux terminal is unavailable"))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(target)
}

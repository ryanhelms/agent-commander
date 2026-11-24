package service

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"agentcommander/internal/hosted"
)

// TerminalAttachment identifies a managed tmux session on this machine.
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
	local := worker != nil && (worker.Host == "" || worker.Host == "localhost")
	s.mu.Unlock()
	if worker == nil {
		respondError(w, missing("worker"))
		return
	}
	resolver, ok := s.launcher.(terminalResolver)
	if !ok || !local {
		respondError(w, &apiError{http.StatusNotImplemented, "native terminal viewing requires a local tmux worker"})
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

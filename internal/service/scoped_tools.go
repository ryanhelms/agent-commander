package service

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"agentcommander/internal/hosted"
	"agentcommander/internal/toolregistry"
)

const (
	scopedToolTimeout = 5 * time.Second
	scopedToolInput   = 16 << 10
	scopedToolOutput  = 64 << 10
)

func (s *service) scopedToolScope(r *http.Request) (toolregistry.Scope, error) {
	if hosted.From(r.Context()) != nil {
		return toolregistry.Scope{}, denied()
	}
	headers := r.Header.Values("Authorization")
	if len(headers) != 1 {
		return toolregistry.Scope{}, &apiError{http.StatusUnauthorized, "scoped tools require a worker credential"}
	}
	bearer, ok := strings.CutPrefix(headers[0], "Bearer ")
	if !ok || bearer == "" {
		return toolregistry.Scope{}, &apiError{http.StatusUnauthorized, "invalid worker credential"}
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	actor := s.state.Tokens[digest(bearer)]
	if actor == "" {
		return toolregistry.Scope{}, &apiError{http.StatusUnauthorized, "invalid worker credential"}
	}
	run, worker := s.worker(actor)
	if run == nil || worker == nil || actor != r.PathValue("worker") || run.ID != r.PathValue("run") ||
		run.Status != "running" || run.CoordinatorID != actor || worker.Role != "coordinator" || worker.Host != "localhost" {
		return toolregistry.Scope{}, denied()
	}
	switch worker.State {
	case "starting", "working", "waiting", "idle":
		return toolregistry.Scope{RunID: run.ID, WorkerID: actor, ProjectPath: run.Path}, nil
	default:
		return toolregistry.Scope{}, denied()
	}
}

func (s *service) listScopedTools(w http.ResponseWriter, r *http.Request) {
	scope, err := s.scopedToolScope(r)
	if err != nil {
		respondError(w, err)
		return
	}
	project := s.tools.Project(scope.ProjectPath)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(struct {
		Tools []toolregistry.Descriptor `json:"tools"`
	}{Tools: project.Descriptors()})
}

func (s *service) callScopedTool(w http.ResponseWriter, r *http.Request) {
	body := http.MaxBytesReader(w, r.Body, scopedToolInput)
	decoder := json.NewDecoder(body)
	decoder.DisallowUnknownFields()
	var invocation toolregistry.Invocation
	if err := decoder.Decode(&invocation); err != nil || invocation.ID == "" || invocation.Version < 1 {
		respondError(w, bad("expected a tool ID, version and arguments within the request size limit"))
		return
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		respondError(w, bad("unexpected data after the tool invocation"))
		return
	}
	scope, err := s.scopedToolScope(r)
	if err != nil {
		respondError(w, err)
		return
	}
	project := s.tools.Project(scope.ProjectPath)
	tool, ok := project.Lookup(invocation.ID, invocation.Version)
	if !ok {
		respondError(w, denied())
		return
	}
	args, err := tool.Arguments(invocation.Arguments)
	if err != nil {
		respondError(w, bad(err.Error()))
		return
	}
	if current, err := s.scopedToolScope(r); err != nil || current != scope {
		respondError(w, denied())
		return
	}
	// Connector I/O runs outside the service mutex. Recheck the same scope after
	// it returns so a run that stopped while waiting cannot receive the result.
	ctx, cancel := context.WithTimeout(r.Context(), scopedToolTimeout)
	defer cancel()
	bound := scope
	bound.ProjectPath = project.Path
	result, runErr := tool.Run(ctx, bound, args)
	current, err := s.scopedToolScope(r)
	if err != nil || current != scope || s.tools.Project(scope.ProjectPath).Path != project.Path {
		respondError(w, denied())
		return
	}
	switch {
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		respondError(w, &apiError{http.StatusGatewayTimeout, "scoped tool timed out"})
	case ctx.Err() != nil:
		return
	case errors.Is(runErr, toolregistry.ErrNotFound):
		respondError(w, missing("scoped tool resource"))
	case errors.Is(runErr, toolregistry.ErrUnavailable):
		respondError(w, &apiError{http.StatusServiceUnavailable, toolregistry.ErrUnavailable.Error()})
	case errors.Is(runErr, toolregistry.ErrRateLimited):
		respondError(w, &apiError{http.StatusTooManyRequests, toolregistry.ErrRateLimited.Error()})
	case runErr != nil || len(result) > scopedToolOutput || !json.Valid(result):
		respondError(w, &apiError{http.StatusBadGateway, "scoped tool failed or returned an invalid result"})
	default:
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(result)
	}
}

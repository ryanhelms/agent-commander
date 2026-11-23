package service

import (
	"context"
	"net/http"
	"slices"
	"time"

	"agentcommander/internal/worktrees"
)

type CodingTest struct {
	Command string `json:"command"`
	Outcome string `json:"outcome"`
}

type CodingHandoff struct {
	Revision string       `json:"revision"`
	Findings string       `json:"findings"`
	Tests    []CodingTest `json:"tests,omitempty"`
}

type Integration struct {
	ID        string              `json:"id"`
	Workers   []string            `json:"workers"`
	Revisions []string            `json:"revisions"`
	Target    worktrees.Checkout  `json:"target"`
	Candidate worktrees.Candidate `json:"candidate"`
}

func (s *service) codingCommit(req *http.Request, actor string) (outcome, error) {
	_, worker, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	if worker.Coding == nil || ended(worker.State) {
		return outcome{}, conflict("worker has no active coding assignment")
	}
	var input struct {
		Files   []string
		Message string
	}
	if err := decode(req, &input); err != nil {
		return outcome{}, err
	}
	revision, err := worktrees.Commit(req.Context(), *worker.Coding, input.Message, input.Files)
	if err != nil {
		return outcome{}, conflict(err.Error())
	}
	return read(map[string]string{"revision": revision}), nil
}

func (s *service) beginIntegration(req *http.Request, actor string) (outcome, error) {
	run := s.run(req.PathValue("run"))
	if run == nil {
		return outcome{}, missing("run")
	}
	if actor != "" && actor != run.CoordinatorID {
		return outcome{}, denied()
	}
	var input struct {
		Workers []string `json:"worker_ids"`
	}
	if err := decode(req, &input); err != nil {
		return outcome{}, err
	}
	if len(input.Workers) == 0 || len(input.Workers) > run.WorkerLimit {
		return outcome{}, bad("select one or more coding worker handoffs")
	}
	key, intent, existing, err := s.receipt(req, actor, input)
	if err != nil {
		return outcome{}, err
	}
	if key == "" {
		return outcome{}, bad("integration requires an idempotency key")
	}
	if existing != "" {
		for _, operation := range run.Integrations {
			if operation.ID == existing {
				return read(operation), nil
			}
		}
		return outcome{}, missing("integration receipt")
	}
	for _, operation := range run.Integrations {
		switch operation.Candidate.Status {
		case "queued", "testing", "advancing":
			return outcome{}, conflict("an integration is already in progress for the run")
		}
	}
	var chosen, revisions []string
	for _, id := range input.Workers {
		if slices.Contains(chosen, id) {
			return outcome{}, bad("select each coding worker once")
		}
		owner, worker := s.worker(id)
		if owner != run || worker.Handoff == nil {
			return outcome{}, conflict("selected worker has no coding handoff in this run")
		}
		chosen = append(chosen, id)
		revisions = append(revisions, worker.Handoff.Revision)
	}
	target, err := worktrees.Source(req.Context(), run.Path)
	if err != nil || target.Branch == "" {
		return outcome{}, conflict("integration requires a coordinator checkout on a branch")
	}
	if run.Branch != "" && run.Branch != target.Branch {
		return outcome{}, conflict("coordinator checkout is no longer on the run's original branch")
	}
	git, err := worktrees.New()
	if err != nil {
		return outcome{}, err
	}
	operation := &Integration{
		ID: randomID("i-"), Workers: chosen, Revisions: revisions, Target: target,
		Candidate: worktrees.Candidate{Status: "queued"},
	}
	run.Integrations = append(run.Integrations, operation)
	s.remember(key, intent, operation.ID)
	runID, operationID, test := run.ID, operation.ID, slices.Clone(run.TestCommand)
	return outcome{operation, 202, true, func() { s.integrate(runID, operationID, git, test) }}, nil
}

func (s *service) integrate(runID, id string, git worktrees.Git, test []string) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
	defer cancel()

	s.mu.Lock()
	operation := s.findIntegration(runID, id)
	if operation == nil || operation.Candidate.Status != "queued" {
		s.mu.Unlock()
		return
	}
	snapshot := *operation
	s.mu.Unlock()
	if !s.updateIntegration(runID, id, worktrees.Candidate{Status: "testing"}) {
		return
	}
	candidate := git.Prepare(ctx, snapshot.Target, id, snapshot.Revisions, test)
	if candidate.Status != "tested" {
		s.updateIntegration(runID, id, candidate)
		return
	}
	tested := candidate
	candidate.Status = "advancing"
	if !s.updateIntegration(runID, id, candidate) {
		return
	}
	s.integrateBranch.Lock()
	candidate = worktrees.Advance(ctx, snapshot.Target, tested)
	s.integrateBranch.Unlock()
	s.updateIntegration(runID, id, candidate)
}

func (s *service) findIntegration(runID, id string) *Integration {
	if run := s.run(runID); run != nil {
		for _, operation := range run.Integrations {
			if operation.ID == id {
				return operation
			}
		}
	}
	return nil
}

func (s *service) updateIntegration(runID, id string, candidate worktrees.Candidate) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	operation := s.findIntegration(runID, id)
	if operation == nil {
		return false
	}
	previous := operation.Candidate
	operation.Candidate = candidate
	if err := s.persist(); err != nil {
		operation.Candidate = previous
		return false
	}
	return true
}

// A restart may follow a successful ref update whose acknowledgement was lost.
// Only the original target and exact candidate revision can prove it completed.
func recoverIntegrations(run *Run) bool {
	dirty := false
	for _, operation := range run.Integrations {
		switch operation.Candidate.Status {
		case "queued", "testing":
			operation.Candidate.Status = "interrupted"
			operation.Candidate.Detail = "service restarted before the recorded candidate advanced"
		case "advancing":
			current, err := worktrees.Source(context.Background(), operation.Target.Path)
			if err == nil && current.Branch == operation.Target.Branch && current.Base == operation.Candidate.Revision {
				operation.Candidate.Status = "integrated"
			} else {
				operation.Candidate.Status = "unknown"
				operation.Candidate.Detail = "service restarted while advancing the target; inspect the original candidate and branch"
			}
		default:
			continue
		}
		dirty = true
	}
	return dirty
}

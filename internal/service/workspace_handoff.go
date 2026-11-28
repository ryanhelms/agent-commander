package service

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

var (
	workspaceHandoffID   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:@-]{0,127}$`)
	workspaceHandoffHead = regexp.MustCompile(`^[a-f0-9]{40}$`)
)

const workspaceHandoffTextLimit = 116 << 10

type workspaceHandoffInput struct {
	Workspace    string    `json:"workspace"`
	Anchor       string    `json:"anchor"`
	Title        string    `json:"title"`
	Text         string    `json:"text"`
	AutoStart    bool      `json:"autoStart"`
	ExpectedHead string    `json:"expectedHead,omitempty"`
	ExpiresAt    time.Time `json:"expiresAt"`
}

// workspaceHandoff records the local execution binding once. The device
// separately owns its durable inbox and the sender's delivery receipt.
type workspaceHandoff struct {
	Intent       string    `json:"intent"`
	ExpectedHead string    `json:"expectedHead,omitempty"`
	ExpiresAt    time.Time `json:"expiresAt"`
	workspaceHandoffStatus
}

type workspaceHandoffStatus struct {
	Run        string `json:"run"`
	Worker     string `json:"worker"`
	Operation  string `json:"operation,omitempty"`
	State      string `json:"state"`
	AcceptedAt string `json:"acceptedAt,omitempty"`
	VerifiedAt string `json:"verifiedAt,omitempty"`
	Head       string `json:"head,omitempty"`
	Failure    string `json:"failure,omitempty"`
}

func (s *service) workspaceHandoffView(record *workspaceHandoff) workspaceHandoffStatus {
	view := record.workspaceHandoffStatus
	if view.State != "queued" && view.State != "accepted" {
		return view
	}
	if record.expiredBeforeClaim(time.Now()) {
		view.State, view.Failure = "failed", "handoff_expired"
		return view
	}
	run, worker := s.worker(view.Worker)
	if run == nil || run.ID != view.Run {
		view.State, view.Failure = "failed", "coordinator_unavailable"
		return view
	}
	if view.Operation != "" && worker.Control != nil {
		if message := worker.Control.message(view.Operation); message != nil && message.Status == "cancelled" {
			view.State, view.Failure = "failed", "coordinator_turn_cancelled"
			return view
		}
	}
	if run.Status == "failed" || worker.State == "failed" {
		view.State, view.Failure = "failed", "coordinator_failed"
	} else if run.Status == "stopping" || run.Status == "stopped" || worker.State == "stopped" {
		view.State, view.Failure = "failed", "coordinator_stopped"
	} else if worker.ProviderAvailability == providerExited || worker.State == "disconnected" {
		view.State, view.Failure = "failed", "provider_unavailable"
	}
	return view
}

func (s *service) getWorkspaceHandoff(req *http.Request, actor string) (outcome, error) {
	if !localOwner(req, actor) {
		return outcome{}, denied()
	}
	record := s.state.WorkspaceHandoffs[req.PathValue("handoff")]
	if record == nil {
		return outcome{}, missing("workspace handoff")
	}
	return read(s.workspaceHandoffView(record)), nil
}

func (s *service) postWorkspaceHandoff(req *http.Request, actor string) (outcome, error) {
	if !localOwner(req, actor) {
		return outcome{}, denied()
	}
	id := req.PathValue("handoff")
	var in workspaceHandoffInput
	if err := decode(req, &in); err != nil {
		return outcome{}, err
	}
	if !workspaceHandoffID.MatchString(id) || !workspaceHandoffID.MatchString(in.Workspace) ||
		!workspaceHandoffID.MatchString(in.Anchor) || strings.TrimSpace(in.Title) == "" || len(in.Title) > 200 ||
		strings.TrimSpace(in.Text) == "" || len(in.Text) > workspaceHandoffTextLimit || in.ExpiresAt.IsZero() ||
		(in.ExpectedHead != "" && !workspaceHandoffHead.MatchString(in.ExpectedHead)) {
		return outcome{}, bad("invalid workspace handoff")
	}

	// AutoStart is current local policy, not an immutable part of the
	// handoff. Toggling it must not prevent replay of a prior reservation.
	intentInput := in
	intentInput.AutoStart = false
	intentInput.ExpiresAt = in.ExpiresAt.UTC()
	payload, _ := json.Marshal(intentInput)
	intent := digest(string(payload))
	if existing := s.state.WorkspaceHandoffs[id]; existing != nil {
		if existing.Intent != intent {
			return outcome{}, conflict("workspace handoff ID is already reserved for a different request")
		}
		return read(s.workspaceHandoffView(existing)), nil
	}

	if !in.ExpiresAt.After(time.Now()) {
		return outcome{}, conflict("workspace handoff expired before reservation")
	}

	anchor := s.run(in.Anchor)
	if anchor == nil {
		return outcome{}, missing("workspace anchor run")
	}
	if anchor.WorkspaceHandoffDestination != "" && anchor.WorkspaceHandoffDestination != in.Workspace {
		return outcome{}, conflict("workspace anchor is assigned to another inbox")
	}
	var run *Run
	for i := len(s.state.Runs) - 1; i >= 0; i-- {
		r := s.state.Runs[i]
		if r.ID != anchor.ID && (r.WorkspaceHandoffDestination != in.Workspace ||
			r.Path != anchor.Path || r.Client != anchor.Client) {
			continue
		}
		if r.Status == "stopping" {
			return outcome{}, conflict("workspace coordinator is still stopping")
		}
		if r.Status == "running" {
			run = r
			break
		}
	}
	record := &workspaceHandoff{Intent: intent, ExpectedHead: in.ExpectedHead, ExpiresAt: in.ExpiresAt.UTC()}
	record.State = "queued"
	var effect func()
	if run != nil {
		_, coordinator := s.worker(run.CoordinatorID)
		if coordinator == nil || coordinator.Role != "coordinator" || coordinator.Host != "localhost" ||
			!canFollowUp(run, coordinator) || coordinator.Control.Held ||
			(coordinator.State != "idle" && coordinator.State != "completed") ||
			coordinator.Control.ActiveTurnID != "" || coordinator.Control.hasProcessingMessage() {
			return outcome{}, conflict("workspace coordinator cannot accept a handoff right now")
		}
		if pending := coordinator.Control.next(); pending != nil {
			prior := s.state.WorkspaceHandoffs[pending.WorkspaceHandoffID]
			if prior == nil || !prior.expiredBeforeClaim(time.Now()) {
				return outcome{}, conflict("workspace coordinator already has a queued turn")
			}
			s.retireExpiredWorkspaceTurn(run, coordinator, pending)
		}
		message := WorkerFollowUp{ID: randomID("m-"), Status: "queued", Text: in.Text,
			Generation: coordinator.Control.Generation, WorkspaceHandoffID: id}
		coordinator.Control.Messages = append(coordinator.Control.Messages, message)
		run.WorkspaceHandoffDestination = in.Workspace
		record.Run, record.Worker, record.Operation = run.ID, coordinator.ID, message.ID
	} else {
		if !in.AutoStart {
			return outcome{}, conflict("workspace coordinator auto-start is disabled")
		}
		prepared, err := s.prepareLaunch(req.Context(), launchPrerequisites{path: anchor.Path, client: anchor.Client})
		if err != nil {
			return outcome{}, err
		}
		run = &Run{ID: randomID("r-"), Project: anchor.Project, Path: anchor.Path, Task: in.Text,
			Client: anchor.Client, Title: displayTitle(in.Title), Branch: prepared.branch, CreatedAt: timestamp(),
			Status: "running", WorkerLimit: anchor.WorkerLimit, Requests: []*Question{},
			TestCommand: anchor.TestCommand, WorkspaceHandoffDestination: in.Workspace, InitialWorkspaceHandoffID: id}
		worker, spec := s.newWorker(run, randomID("w-"), "Coordinator", in.Text, "", "coordinator", run.Client, "localhost", run.Path)
		spec.WorkspaceCoordinator = true
		run.CoordinatorID = worker.ID
		s.state.Runs = append(s.state.Runs, run)
		record.Run, record.Worker = run.ID, worker.ID
		effect = func() { s.launch(spec) }
	}
	if s.state.WorkspaceHandoffs == nil {
		s.state.WorkspaceHandoffs = make(map[string]*workspaceHandoff)
	}
	s.state.WorkspaceHandoffs[id] = record
	return outcome{record.workspaceHandoffStatus, http.StatusAccepted, true, effect}, nil
}

func (h *workspaceHandoff) expiredBeforeClaim(now time.Time) bool {
	return h.State == "queued" && !h.ExpiresAt.After(now)
}

func (s *service) failWorkspaceHandoff(id string, worker *Worker, failure string) {
	if h := s.state.WorkspaceHandoffs[id]; h != nil && h.Worker == worker.ID &&
		(h.State == "queued" || h.State == "accepted") {
		h.State, h.Failure = "failed", failure
	}
}

func (s *service) retireExpiredWorkspaceTurn(run *Run, worker *Worker, pending *WorkerFollowUp) {
	pending.Status = "cancelled"
	s.markOperationEnd(run, worker, pending)
	s.failWorkspaceHandoff(pending.WorkspaceHandoffID, worker, "handoff_expired")
}

func (s *service) expireWorkspaceHandoff(run *Run, worker *Worker, pending *WorkerFollowUp) outcome {
	if pending != nil {
		s.retireExpiredWorkspaceTurn(run, worker, pending)
	} else {
		worker.State, worker.Error = "failed", "Workspace handoff expired before coordinator startup."
		s.failWorkspaceHandoff(run.InitialWorkspaceHandoffID, worker, "handoff_expired")
	}
	run.refreshOutcome()
	return outcome{map[string]string{"error": "workspace handoff expired before claim"}, http.StatusConflict, true, nil}
}

func (s *service) acceptWorkspaceHandoff(id string, worker *Worker) {
	if h := s.state.WorkspaceHandoffs[id]; h != nil && h.Worker == worker.ID && h.State == "queued" {
		h.State, h.AcceptedAt = "accepted", time.Now().UTC().Format(time.RFC3339Nano)
	}
}

func (s *service) finishWorkspaceHandoff(ctx context.Context, id string, worker *Worker, state, stopReason string) {
	h := s.state.WorkspaceHandoffs[id]
	if h == nil || h.Worker != worker.ID || h.State != "accepted" {
		return
	}
	if state != "completed" || (stopReason != "" && stopReason != "end_turn") {
		h.State, h.Failure = "failed", "coordinator_turn_"+state
		if stopReason != "" {
			h.Failure = "coordinator_turn_" + stopReason
		}
		return
	}
	h.State = "unverified"
	h.Failure = "missing_evidence"
	if h.ExpectedHead == "" {
		return
	}
	// This proof covers the trusted checkout's HEAD at the exact turn end.
	// Commit authorship is outside the evidence contract.
	h.Head = workspaceHandoffCheckoutHead(ctx, worker.Worktree)
	if h.Head == h.ExpectedHead {
		h.State, h.VerifiedAt, h.Failure = "verified", time.Now().UTC().Format(time.RFC3339Nano), ""
	} else if h.Head != "" {
		h.Failure = "revision_mismatch"
	}
}

func workspaceHandoffCheckoutHead(ctx context.Context, path string) string {
	ctx, cancel := context.WithTimeout(ctx, 350*time.Millisecond)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", "rev-parse", "--verify", "HEAD")
	cmd.Dir = path
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + os.Getenv("HOME")}
	cmd.WaitDelay = 100 * time.Millisecond
	result, err := cmd.Output()
	head := strings.TrimSpace(string(result))
	if err != nil || !workspaceHandoffHead.MatchString(head) {
		return ""
	}
	return head
}

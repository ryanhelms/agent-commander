package service

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"agentcommander/internal/acpprocessor"
	"agentcommander/internal/toolregistry"
	"agentcommander/internal/worktrees"
)

type LaunchSpec struct {
	ID, RunID, ParentID, Name, Task, Role, Path, Token, Client string
	Host, Worktree                                             string
	CodingSource                                               *worktrees.Checkout
	Reattach                                                   *ReattachSpec `json:",omitempty"`
}

type Launcher interface {
	Launch(context.Context, LaunchSpec) error
	Stop(context.Context, string) error
}

type hostPlacement interface {
	WorkerCheckout(host, localCheckout, client string) (string, error)
}

// ConsoleEvent preserves a provider event for structured conversation views.
type ConsoleEvent struct {
	ACP      *acpprocessor.Activity `json:"acp,omitempty"`
	Sequence int                    `json:"sequence"`
	Kind     string                 `json:"kind"`
	ToolID   string                 `json:"tool_id,omitempty"`
	// Only the validated request or operation ID from a Commander call's ACP raw input.
	CommanderInput string `json:"commander_input,omitempty"`
	Name           string `json:"name,omitempty"`
	Phase          string `json:"phase,omitempty"`
	Text           string `json:"text,omitempty"`
}

type Worker struct {
	ID                   string               `json:"id"`
	Name                 string               `json:"name"`
	Role                 string               `json:"role"`
	ParentID             string               `json:"parent_id"`
	RunID                string               `json:"run_id"`
	State                string               `json:"state"`
	Host                 string               `json:"host"`
	Worktree             string               `json:"worktree"`
	Branch               string               `json:"branch,omitempty"`
	Client               string               `json:"client,omitempty"`
	CreatedAt            string               `json:"created_at,omitempty"`
	Task                 string               `json:"task"`
	Output               string               `json:"output"`
	Error                string               `json:"error,omitempty"`
	Result               string               `json:"result,omitempty"`
	Console              []ConsoleEvent       `json:"console,omitempty"`
	Control              *WorkerControl       `json:"control,omitempty"`
	NativeSession        *NativeSession       `json:"native_session,omitempty"`
	ProviderBinding      string               `json:"provider_binding,omitempty"`
	PeerCapabilities     *SessionCapabilities `json:"peer_session_capabilities,omitempty"`
	Connection           string               `json:"connection,omitempty"`
	Coding               *worktrees.Checkout  `json:"coding,omitempty"`
	Handoff              *CodingHandoff       `json:"handoff,omitempty"`
	FrontendTools        bool                 `json:"frontend_tools,omitempty"`
	Telemetry            *WorkerTelemetry     `json:"telemetry,omitempty"`
	ClaudeProgress       *ClaudeProgress      `json:"claude_progress,omitempty"`
	ProviderAvailability string               `json:"provider_availability,omitempty"`
}

type Question struct {
	ID       string           `json:"id"`
	WorkerID string           `json:"worker_id"`
	Question string           `json:"question"`
	Status   string           `json:"status"`
	Answer   string           `json:"answer"`
	Delivery string           `json:"delivery,omitempty"`
	Choices  []QuestionChoice `json:"choices,omitempty"`
	// The normalized console tool ID supplied by this provider permission.
	ProviderToolCallID string `json:"provider_tool_call_id,omitempty"`
}

type Run struct {
	ID            string         `json:"id"`
	Project       string         `json:"project"`
	Path          string         `json:"path"`
	Task          string         `json:"task"`
	Title         string         `json:"title,omitempty"`
	Branch        string         `json:"branch,omitempty"`
	CreatedAt     string         `json:"created_at,omitempty"`
	Client        string         `json:"client"`
	CoordinatorID string         `json:"coordinator_id"`
	Workers       []*Worker      `json:"workers"`
	Requests      []*Question    `json:"requests"`
	Status        string         `json:"status"`
	WorkerLimit   int            `json:"worker_limit"`
	TestCommand   []string       `json:"test_command,omitempty"`
	Integrations  []*Integration `json:"integrations,omitempty"`
}

type retryReceipt struct {
	Intent string `json:"intent"`
	Target string `json:"target"`
}

type providerPermission struct {
	Turn    string `json:"turn"`
	Request string `json:"request"`
}

type database struct {
	Permissions   map[string]providerPermission `json:"provider_permissions,omitempty"`
	OutputBatches map[string]outputReceipt      `json:"output_batches,omitempty"` // legacy workers persist their output
	Runs          []*Run                        `json:"runs"`
	Tokens        map[string]string             `json:"tokens"` // SHA-256(token) to worker ID
	Receipts      map[string]retryReceipt       `json:"receipts"`
	PromptParts   map[string][]PromptPart       `json:"prompt_parts,omitempty"`
}

type service struct {
	liveOutputBatches   map[string]outputReceipt // disposable with the native console window
	mu                  sync.Mutex
	process             sync.Mutex // order launches and stops across their external effects
	integrateBranch     sync.Mutex // serialize checked-out branch updates
	path                string
	state               database
	launcher            Launcher
	tools               *toolregistry.Registry
	consoleObservers    map[chan struct{}]struct{} // guarded by mu
	operationObservers  map[chan struct{}]string
	workspace           *workspaceProjection // owner-only workspace cache, guarded by mu
	consoleInstance     string
	controlChanged      chan struct{}
	readingHistory      map[string]bool
	stoppedHistoryReads map[string]int
	frontendRounds      map[string][]*frontendRound
	liveSource          liveSourceStore
	elicitations        map[string]*activeElicitation
	details             toolDetailStore
}

func randomID(prefix string) string {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		panic(err)
	}
	return prefix + hex.EncodeToString(id[:])
}

func digest(s string) string { return fmt.Sprintf("%x", sha256.Sum256([]byte(s))) }

func (s *service) load(stateDir string) error {
	if err := os.MkdirAll(stateDir, 0700); err != nil {
		return err
	}
	s.path = filepath.Join(stateDir, "state.json")
	s.state = database{Runs: []*Run{}, Tokens: map[string]string{}, Receipts: map[string]retryReceipt{}}
	data, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if err = json.Unmarshal(data, &s.state); err != nil {
		return fmt.Errorf("read Commander state: %w", err)
	}
	if s.state.Tokens == nil {
		s.state.Tokens = map[string]string{}
	}
	if s.state.Receipts == nil {
		s.state.Receipts = map[string]retryReceipt{}
	}
	for _, run := range s.state.Runs {
		if run.Title == "" {
			run.Title = displayTitle(run.Task)
		}
		for _, worker := range run.Workers {
			if worker.Client == "" {
				worker.Client = run.Client
			}
		}
		if run.WorkerLimit == 0 {
			run.WorkerLimit = defaultWorkerLimit
		}
	}
	if s.state.Runs == nil {
		s.state.Runs = []*Run{}
	}
	return nil
}

func (s *service) persist() error {
	if err := writeStateJSON(s.path, s.durableState()); err != nil {
		return err
	}
	if s.controlChanged != nil {
		close(s.controlChanged)
		s.controlChanged = nil
	}
	s.notifyConsole()
	return nil
}

func writeStateJSON(path string, value any) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".state-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err = json.NewEncoder(tmp).Encode(value); err == nil {
		err = tmp.Sync()
	}
	closeErr := tmp.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(name, path)
}

func (s *service) notifyConsole() {
	if s.workspace != nil {
		s.workspace.rebuild(s.state.Runs)
	}
	s.notifyOperations("")
	s.signalConsole()
}

func (s *service) notifyConsoleOutput(worker *Worker, appendedText string, appendedEvents []ConsoleEvent) {
	if s.workspace != nil {
		s.workspace.updateWorker(worker, appendedText, appendedEvents)
	}
	s.notifyOperations(worker.ID)
	s.signalConsole()
}

func (s *service) signalConsole() {
	for observer := range s.consoleObservers {
		select {
		case observer <- struct{}{}:
		default: // An outstanding notification already covers this commit.
		}
	}
}

func (s *service) saveBackground() {
	if err := s.persist(); err != nil {
		log.Printf("cannot persist managed worker transition: %v", err)
	}
}

func (s *service) run(id string) *Run {
	for _, r := range s.state.Runs {
		if r.ID == id {
			return r
		}
	}
	return nil
}

func (s *service) worker(id string) (*Run, *Worker) {
	for _, r := range s.state.Runs {
		for _, w := range r.Workers {
			if id == w.ID {
				return r, w
			}
		}
	}
	return nil, nil
}

func (s *service) question(id string) (*Run, *Question) {
	for _, r := range s.state.Runs {
		for _, q := range r.Requests {
			if id == q.ID {
				return r, q
			}
		}
	}
	return nil, nil
}

const defaultWorkerLimit = 10

func displayTitle(text string) string {
	const limit = 72
	for line := range strings.SplitSeq(text, "\n") {
		title := strings.TrimSpace(line)
		if title == "" {
			continue
		}
		runes := []rune(title)
		if len(runes) > limit {
			return string(runes[:limit-1]) + "…"
		}
		return title
	}
	return ""
}

// Workers in the local planning slice share the run's checkout. Capture its
// branch once at run creation so reopening a run cannot relabel its history.
func checkoutBranch(ctx context.Context, dir string) string {
	ctx, cancel := context.WithTimeout(ctx, 350*time.Millisecond)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", "symbolic-ref", "--quiet", "HEAD")
	cmd.Dir = dir
	// An inherited GIT_DIR or GIT_WORK_TREE can point at a different checkout.
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + os.Getenv("HOME")}
	cmd.WaitDelay = 100 * time.Millisecond
	ref, err := cmd.Output()
	if err != nil {
		return ""
	}
	branch, ok := strings.CutPrefix(strings.TrimSpace(string(ref)), "refs/heads/")
	if !ok {
		return ""
	}
	return branch
}

func timestamp() string { return time.Now().UTC().Format(time.RFC3339) }

func (r *Run) activeWorkers() int {
	count := 0
	for _, w := range r.Workers {
		if w.Role == "worker" && w.State != "failed" && w.State != "completed" && w.State != "stopped" {
			count++
		}
	}
	return count
}

func ended(state string) bool { return state == "completed" || state == "failed" || state == "stopped" }

// Any coordinator failure ends delegation immediately. Already-running children
// may still publish their output and final result until the user stops the run.
func (r *Run) cancelQuestions(workerID string) {
	for _, q := range r.Requests {
		if q.Status == "pending" && (workerID == "" || q.WorkerID == workerID) {
			q.Status = "cancelled"
		}
	}
}

func (r *Run) refreshOutcome() {
	if r.Status != "running" {
		return
	}
	allEnded, failed := true, false
	for _, w := range r.Workers {
		if w.State == "failed" {
			failed = true
			if w.ID == r.CoordinatorID {
				r.Status = "failed"
				return
			}
		}
		// A completed turn can still receive input through its developer-held
		// session. Handback re-evaluates the run after releasing that lease.
		heldBetweenTurns := w.State == "completed" && w.Control != nil && w.Control.Held
		if !ended(w.State) || heldBetweenTurns || (w.Control != nil && w.Control.next() != nil) {
			allEnded = false
		}
	}
	if allEnded {
		r.Status = "completed"
		if failed {
			r.Status = "failed"
		}
	}
}

func (s *service) newWorker(r *Run, id, name, task, parent, role, client, host, checkout string) (*Worker, LaunchSpec) {
	w := &Worker{
		ID: id, RunID: r.ID, Name: name, Task: task, ParentID: parent,
		Role: role, State: "starting", Host: host, Worktree: checkout,
		Client: client, CreatedAt: timestamp(),
	}
	if host == "localhost" {
		w.Branch = r.Branch
	}
	token := randomID("") + randomID("")
	s.state.Tokens[digest(token)] = w.ID
	r.Workers = append(r.Workers, w)
	return w, LaunchSpec{ID: w.ID, RunID: r.ID, ParentID: parent, Name: name, Task: task, Role: role, Path: r.Path, Token: token, Client: client, Host: host, Worktree: checkout}
}

// A persisted reservation may have reached tmux even if the service exits before it
// records the outcome. Preserve that identity across restart and never relaunch blindly.
func (s *service) launch(spec LaunchSpec) {
	if s.launcher == nil {
		return
	}
	s.process.Lock()
	defer s.process.Unlock()
	s.mu.Lock()
	r, w := s.worker(spec.ID)
	active := r != nil && r.Status == "running" && w.State == "starting"
	if r != nil && r.Status == "failed" && w.State == "starting" {
		w.State, w.Error = "failed", "Coordinator ended before this worker started."
		s.saveBackground()
	}
	s.mu.Unlock()
	if !active {
		return
	}
	if err := s.launcher.Launch(context.Background(), spec); err != nil {
		s.mu.Lock()
		defer s.mu.Unlock()
		r, w = s.worker(spec.ID)
		if r != nil && r.Status == "running" && w.State == "starting" {
			if spec.Reattach != nil {
				failReattachment(r, w, err.Error())
			} else {
				w.State, w.Error = "failed", err.Error()
				r.cancelQuestions(w.ID)
				r.refreshOutcome()
			}
			s.saveBackground()
		}
	}
}

func (s *service) stop(runID string, workers []string) {
	if s.launcher == nil {
		return
	}
	s.process.Lock()
	defer s.process.Unlock()
	for _, id := range workers {
		if err := s.launcher.Stop(context.Background(), id); err != nil {
			s.mu.Lock()
			_, w := s.worker(id)
			w.Error = err.Error()
			s.saveBackground()
			s.mu.Unlock()
			continue
		}
		s.mu.Lock()
		_, w := s.worker(id)
		w.State, w.Error = "stopped", ""
		s.saveBackground()
		s.mu.Unlock()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.run(runID)
	for _, w := range r.Workers {
		if w.State == "stopping" {
			return
		}
	}
	r.Status = "stopped"
	s.saveBackground()
}

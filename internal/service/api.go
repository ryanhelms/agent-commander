package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"agentcommander/internal/buildinfo"
	"agentcommander/internal/hosted"
	"agentcommander/internal/toolregistry"
	"agentcommander/internal/worktrees"
)

type apiError struct {
	code    int
	message string
}

func (e *apiError) Error() string   { return e.message }
func bad(message string) error      { return &apiError{400, message} }
func denied() error                 { return &apiError{403, "operation outside this worker's scope"} }
func missing(what string) error     { return &apiError{404, what + " not found"} }
func conflict(message string) error { return &apiError{409, message} }

type outcome struct {
	body    any
	code    int
	mutated bool
	after   func()
}

func read(v any) outcome    { return outcome{body: v, code: 200} }
func changed(v any) outcome { return outcome{body: v, code: 200, mutated: true} }

type endpoint func(*http.Request, string) (outcome, error)

func New(stateDir string, launcher Launcher, tools ...toolregistry.Tool) (http.Handler, error) {
	registry, err := toolregistry.Load(stateDir, tools...)
	if err != nil {
		return nil, err
	}
	return NewWithToolRegistry(stateDir, launcher, registry)
}

func NewWithToolRegistry(stateDir string, launcher Launcher, registry *toolregistry.Registry) (http.Handler, error) {
	s := &service{launcher: launcher, tools: registry, consoleInstance: randomID("console-"), frontendRounds: make(map[string][]*frontendRound)}
	if err := s.load(stateDir); err != nil {
		return nil, err
	}
	if err := s.details.open(stateDir); err != nil {
		return nil, fmt.Errorf("read transcript settings: %w", err)
	}
	// Agents reattach using their existing credentials. An uncertain launch never
	// creates a second tmux session. Fresh authenticated worker events restore state.
	dirty := false
	for _, run := range s.state.Runs {
		dirty = recoverIntegrations(run) || dirty
		for _, w := range run.Workers {
			if run.Status == "running" && w.State != "unknown" && w.State != "disconnected" && w.State != "stopping" && !ended(w.State) {
				if w.isLocalClaudeWorker() && w.ProviderAvailability == providerAvailable &&
					w.Control != nil && w.Control.ActiveTurnID != "" {
					w.ProviderAvailability = providerChecking
				}
				w.State, w.Error = "unknown", "Service restarted. Waiting for evidence from the original worker."
				if w.Control != nil {
					for i := range w.Control.Messages {
						message := &w.Control.Messages[i]
						if message.Status == "processing" {
							message.Status = "delivery_unknown"
							s.markOperationEnd(run, w, message)
							message.End.ConsoleInstance = ""
						}
					}
				}
				dirty = true
			}
		}
		previous := run.Status
		run.refreshOutcome()
		dirty = dirty || previous != run.Status
	}
	if dirty {
		if err := s.persist(); err != nil {
			return nil, err
		}
	}
	// A durable stop request survives a daemon restart. Stop targets stable managed IDs.
	type interruptedStop struct {
		id      string
		workers []string
	}
	var interrupted []interruptedStop
	for _, run := range s.state.Runs {
		if run.Status != "stopping" {
			continue
		}
		item := interruptedStop{id: run.ID}
		for _, w := range run.Workers {
			if w.State == "stopping" {
				item.workers = append(item.workers, w.ID)
			}
		}
		interrupted = append(interrupted, item)
	}
	var individualStops []string
	for _, run := range s.state.Runs {
		if run.Status != "stopping" && run.Status != "stopped" {
			for _, w := range run.Workers {
				if w.State == "stopping" {
					individualStops = append(individualStops, w.ID)
				}
			}
		}
	}
	for _, item := range interrupted {
		go s.stop(item.id, item.workers)
	}
	for _, id := range individualStops {
		go s.stopOne(id)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/catalog/notices/events", s.streamCatalogNotices)
	(&harnessRoutes{stateDir: stateDir, launcher: launcher}).register(mux)
	newPluginRoutes(stateDir).register(mux)
	mux.HandleFunc("GET /v1/network/coordinator", s.handleJSON(s.networkCoordinator))
	mux.HandleFunc("GET /v1/network/workspace-handoffs/{handoff}", s.handle(s.getWorkspaceHandoff))
	mux.HandleFunc("POST /v1/network/workspace-handoffs/{handoff}", s.handle(s.postWorkspaceHandoff))
	mux.HandleFunc("GET /v1/runs/{run}/workers/{worker}/tools", s.listScopedTools)
	mux.HandleFunc("POST /v1/runs/{run}/workers/{worker}/tools/calls", s.callScopedTool)
	mux.HandleFunc("GET /v1/ag-ui/events", s.streamConsole)
	mux.HandleFunc("POST /v1/ag-ui/workers/{worker}/run", s.streamWorkerRun)
	mux.HandleFunc("GET /v1/ag-ui/workers/{worker}/operations/{operation}", s.observeWorkerRun)
	mux.HandleFunc("GET /v1/ag-ui/workers/{worker}/operations", s.handle(s.workerRunReceipt))
	mux.HandleFunc("GET /v1/ag-ui/workers/{worker}", s.handle(s.workerRunInfo))
	mux.HandleFunc("GET /v1/workers/{worker}/history", s.serveNativeHistoryPage)
	mux.HandleFunc("GET /v1/workers/{worker}/provider-sessions", s.listProviderSessions)
	mux.HandleFunc("GET /v1/workers/{worker}/terminal", s.serveTerminalAttachment)
	mux.HandleFunc("POST /v1/workers/{worker}/output", s.handleJSONLimit(s.output, 16<<20))
	mux.HandleFunc("GET /v1/workers/{worker}/output", s.handleJSON(s.outputStream))
	mux.HandleFunc("GET /v1/workers/{worker}/live-source/events", s.streamLiveSource)
	mux.HandleFunc("POST /v1/workers/{worker}/live-source", s.handleJSONLimit(s.recordLiveSource, 2<<20))
	mux.HandleFunc("POST /v1/workers/{worker}/live-source/batch", s.handleJSONLimit(s.recordLiveSourceBatch, 2<<20))
	mux.HandleFunc("POST /v1/requests/{qid}/reconcile", s.reconcileSSHReply)
	mux.HandleFunc("POST /v1/workers/{worker}/ssh-link", s.handle(s.workerSSHLink))
	mux.HandleFunc("POST /v1/runs/{run}/integrations", s.handle(s.beginIntegration))
	mux.HandleFunc("POST /v1/workers/{worker}/coding/commit", s.handle(s.codingCommit))
	mux.HandleFunc("GET /v1/workers/{worker}/control", s.waitWorkerControl)
	mux.HandleFunc("POST /v1/workers/{worker}/messages", s.handlePreparedJSON(func(req *http.Request, actor string) (outcome, error) {
		return s.applyEndpoint(req, actor, s.sendWorkerMessage)
	}, 1<<20, s.prepareWorkerPrompt))
	mux.HandleFunc("POST /v1/workers/{worker}/elicitations/await", s.awaitElicitation)
	mux.HandleFunc("GET /v1/workers/{worker}/elicitations", s.handleJSON(s.listElicitations))
	mux.HandleFunc("POST /v1/workers/{worker}/elicitations/{elicitation}/reply", s.handleJSONLimit(s.answerElicitation, elicitationPayloadLimit))
	mux.HandleFunc("POST /v1/workers/{worker}/elicitations/complete", s.handleJSONLimit(s.completeElicitation, 1024))
	mux.HandleFunc("GET /v1/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"status": "ok", "api": buildinfo.APIVersion, "version": buildinfo.Current()})
	})
	for pattern, op := range map[string]endpoint{
		"GET /v1/runs": s.listRuns, "POST /v1/runs": s.createRun,
		"GET /v1/runs/{run}": s.getRun, "POST /v1/runs/{run}/workers": s.delegate,
		"POST /v1/runs/{run}/stop":            s.stopRun,
		"POST /v1/workers/{worker}/questions": s.ask, "GET /v1/workers/{worker}/questions/{qid}": s.getQuestion,
		"POST /v1/workers/{worker}/questions/{qid}/withdraw":   s.withdrawQuestion,
		"POST /v1/workers/{worker}/questions/dismiss-provider": s.dismissProviderPermission,
		"POST /v1/requests/{qid}/reply":                        s.reply, "POST /v1/workers/{worker}/state": s.workerState,
		"POST /v1/ag-ui/workers/{worker}/requests/{qid}/reply":                       s.replyToWorkerRun,
		"POST /v1/ag-ui/workers/{worker}/operations/{operation}/tools/{call}/result": s.resolveFrontendCall,
		"POST /v1/workers/{worker}/frontend-tools/ready":                             s.frontendToolReady,
		"GET /v1/workers/{worker}/frontend-tools":                                    s.listFrontendTools,
		"POST /v1/workers/{worker}/frontend-tools/calls":                             s.startFrontendCall,
		"GET /v1/workers/{worker}/frontend-tools/calls/{call}":                       s.readFrontendCall,
		"POST /v1/workers/{worker}/frontend-tools/calls/{call}/cancel":               s.cancelFrontendCall,
		"POST /v1/workers/{worker}/result":                                           s.workerResult,
		"POST /v1/workers/{worker}/native-session":                                   s.bindNativeSession,
		"POST /v1/workers/{worker}/control":                                          s.setWorkerControl,
		"POST /v1/workers/{worker}/control/ready":                                    s.workerControlReady,
		"POST /v1/workers/{worker}/control/finish":                                   s.finishWorkerTurn,
		"POST /v1/workers/{worker}/control/provider-exit":                            s.reportWorkerProviderExit,
		"GET /v1/workers/{worker}/session":                                           s.getProviderSessionStatus,
		"POST /v1/workers/{worker}/reattach":                                         s.reattachWorker,
		"POST /v1/workers/{worker}/control/reattached":                               s.readyReattachedWorker,
		"POST /v1/workers/{worker}/control/reconcile":                                s.reconcileWorkerProvider,
		"POST /v1/workers/{worker}/control/interrupt/claim":                          s.claimWorkerInterrupt,
		"POST /v1/workers/{worker}/control/interrupt/report":                         s.reportWorkerInterrupt,
		"POST /v1/workers/{worker}/messages/{message}/claim":                         s.claimWorkerMessage,
		"POST /v1/workers/{worker}/interrupt":                                        s.interruptWorker,
		"POST /v1/workers/{worker}/messages/{message}/cancel":                        s.cancelWorkerMessage,
		"GET /v1/workers/{worker}/tool-details":                                      s.readToolDetails,
		"GET /v1/settings/transcript":                                                s.readTranscriptSettings,
		"POST /v1/settings/transcript":                                               s.setTranscriptSettings,
		"POST /v1/workers/{worker}/stop":                                             s.stopWorker,
	} {
		mux.HandleFunc(pattern, s.handle(op))
	}
	return mux, nil
}

func (s *service) handle(op endpoint) http.HandlerFunc {
	return s.handleJSON(func(r *http.Request, actor string) (outcome, error) {
		return s.applyEndpoint(r, actor, op)
	})
}

func (s *service) handleJSON(op endpoint) http.HandlerFunc {
	return s.handleJSONLimit(op, 1<<20)
}

func (s *service) handleJSONLimit(op endpoint, limit int64) http.HandlerFunc {
	return s.handlePreparedJSON(op, limit, nil)
}

func (s *service) handlePreparedJSON(op endpoint, limit int64, prepare func(*http.Request, []byte) (*http.Request, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, limit)
		// Read the bounded body before taking the shared state lock.
		if r.Method == "POST" {
			raw, err := io.ReadAll(r.Body)
			if err != nil {
				respondError(w, bad("request exceeds size limit or could not be read"))
				return
			}
			r = r.WithContext(context.WithValue(r.Context(), bodyKey{}, raw))
			if prepare != nil {
				r, err = prepare(r, raw)
				if err != nil {
					respondError(w, err)
					return
				}
			}
		}
		res, body, err := s.dispatchJSON(r, op)
		if err != nil {
			respondError(w, err)
			return
		}
		if res.after != nil {
			go res.after()
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(res.code)
		_, _ = w.Write(append(body, '\n'))
	}
}

// dispatchJSON keeps state validation and persistence in one transaction. A launch
// can return an external check to run before any mutation, then reenter the
// endpoint with fresh authorization and state.
func (s *service) dispatchJSON(r *http.Request, op endpoint) (outcome, []byte, error) {
	s.mu.Lock()
	actor, err := s.requestActor(r)
	var res outcome
	if err == nil {
		res, err = op(r, actor)
	}
	var check *launchCheck
	if errors.As(err, &check) {
		s.mu.Unlock()
		prepared := check.prepare(r.Context())
		if r.Context().Err() != nil {
			return outcome{}, nil, r.Context().Err()
		}
		return s.dispatchJSON(r.WithContext(context.WithValue(r.Context(), launchCheckKey{}, prepared)), op)
	}
	var body []byte
	if err == nil {
		body, err = json.Marshal(res.body)
	}
	s.mu.Unlock()
	return res, body, err
}

// requestActor requires the service lock.
func (s *service) requestActor(r *http.Request) (string, error) {
	var actor string
	if _, present := r.Header["Authorization"]; present {
		bearer, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		actor = s.state.Tokens[digest(bearer)]
		if !ok || bearer == "" || actor == "" {
			return "", &apiError{401, "invalid worker credential"}
		}
	}
	if access := hosted.From(r.Context()); access != nil && !access.Allowed() {
		return "", denied()
	}
	return actor, nil
}

// applyEndpoint runs with the service lock held. A streaming command shares
// the same durable acceptance and rollback as its ordinary JSON endpoint.
func (s *service) applyEndpoint(r *http.Request, actor string, op endpoint) (outcome, error) {
	if access := hosted.From(r.Context()); access != nil && !access.Allowed() {
		return outcome{}, denied()
	}
	var before []byte
	if r.Method == "POST" {
		before, _ = json.Marshal(&s.state)
	}
	res, err := op(r, actor)
	if err != nil || !res.mutated {
		return res, err
	}
	if err := s.persist(); err != nil {
		var restored database
		if restoreErr := json.Unmarshal(before, &restored); restoreErr != nil {
			panic(restoreErr)
		}
		s.state = restored
		return outcome{}, fmt.Errorf("persist Commander state: %w", err)
	}
	return res, nil
}

func respondError(w http.ResponseWriter, err error) {
	status := http.StatusInternalServerError
	var e *apiError
	if errors.As(err, &e) {
		status = e.code
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}

type bodyKey struct{}

func decode(r *http.Request, fields any) error {
	b, _ := r.Context().Value(bodyKey{}).([]byte)
	if err := json.Unmarshal(b, fields); err != nil {
		return bad("expected a JSON object")
	}
	return nil
}
func (s *service) canRead(actor string, target *Run) bool {
	if actor == "" {
		return true
	}
	own, _ := s.worker(actor)
	return own != nil && own.Path == target.Path
}

func (s *service) listRuns(_ *http.Request, actor string) (outcome, error) {
	runs := []*Run{}
	for _, r := range s.state.Runs {
		if s.canRead(actor, r) {
			runs = append(runs, r)
		}
	}
	return read(map[string]any{"runs": runs}), nil
}
func (s *service) getRun(req *http.Request, actor string) (outcome, error) {
	r := s.run(req.PathValue("run"))
	if r == nil {
		return outcome{}, missing("run")
	}
	if !s.canRead(actor, r) {
		return outcome{}, denied()
	}
	if req.URL.Query().Get("view") == "ag-ui" {
		projected := aguiRun{Run: *r, Workers: make([]aguiWorker, len(r.Workers))}
		projected.Run.Workers = nil
		for i, worker := range r.Workers {
			projected.Workers[i].Worker = *worker
			projected.Workers[i].projectMessages()
		}
		return read(projected), nil
	}
	return read(r), nil
}

// An empty retry key opts out. Bind a supplied key to the actor, endpoint,
// resource and original arguments; a different payload cannot reuse it.
func (s *service) receipt(req *http.Request, actor string, input any) (key, intent, target string, err error) {
	raw := req.Header.Get("Idempotency-Key")
	var envelope struct {
		Key string `json:"idempotency_key"`
	}
	if e := decode(req, &envelope); e != nil {
		err = e
		return
	}
	if raw != "" && envelope.Key != "" && raw != envelope.Key {
		err = bad("conflicting idempotency keys")
		return
	}
	if raw == "" {
		raw = envelope.Key
	}
	if raw == "" {
		return
	}
	if len(raw) > 256 {
		err = bad("Idempotency-Key exceeds 256 bytes")
		return
	}
	payload, _ := json.Marshal(input)
	key = receiptKey(receiptActor(req, actor), req.URL.Path, raw)
	intent = digest(string(payload))
	if rec, ok := s.state.Receipts[key]; ok {
		if rec.Intent != intent {
			err = conflict("idempotency key already used for another operation")
			return
		}
		target = rec.Target
	}
	return
}

func receiptKey(actor, path, requestID string) string {
	return digest(actor + "\x00" + path + "\x00" + requestID)
}

func receiptActor(r *http.Request, local string) string {
	if access := hosted.From(r.Context()); access != nil {
		return access.ReceiptActor()
	}
	return local
}
func (s *service) remember(key, intent, target string) {
	if key != "" {
		s.state.Receipts[key] = retryReceipt{Intent: intent, Target: target}
	}
}
func (s *service) createRun(req *http.Request, actor string) (outcome, error) {
	if actor != "" {
		return outcome{}, denied()
	}
	var in struct {
		Project, Path, Task, Client string
		WorkerLimit                 int      `json:"worker_limit"`
		Title                       string   `json:"title,omitempty"`
		TestCommand                 []string `json:"test_command,omitempty"`
	}
	if err := decode(req, &in); err != nil {
		return outcome{}, err
	}
	if strings.TrimSpace(in.Task) == "" || !filepath.IsAbs(in.Path) {
		return outcome{}, bad("task and absolute project path are required")
	}
	if in.WorkerLimit == 0 {
		in.WorkerLimit = defaultWorkerLimit
	}
	if in.WorkerLimit < 1 || in.WorkerLimit > defaultWorkerLimit {
		return outcome{}, bad("worker_limit must be between 1 and 10")
	}
	if len(in.TestCommand) > 0 && strings.TrimSpace(in.TestCommand[0]) == "" {
		return outcome{}, bad("test_command requires an executable as its first argument")
	}
	in.Path = filepath.Clean(in.Path)
	key, intent, target, err := s.receipt(req, actor, in)
	if err != nil {
		return outcome{}, err
	}
	if target != "" {
		return read(s.run(target)), nil
	}
	if in.Project == "" {
		in.Project = filepath.Base(in.Path)
	}
	if in.Client == "" {
		in.Client = "claude"
	}
	prepared, err := s.prepareLaunch(req.Context(), launchPrerequisites{client: in.Client, path: in.Path})
	if err != nil {
		return outcome{}, err
	}
	title := displayTitle(in.Title)
	if title == "" {
		title = displayTitle(in.Task)
	}
	r := &Run{
		ID: randomID("r-"), Project: in.Project, Path: in.Path, Task: in.Task, Client: in.Client,
		Title: title, CreatedAt: timestamp(), Branch: prepared.branch,
		Status: "running", WorkerLimit: in.WorkerLimit, Requests: []*Question{}, TestCommand: in.TestCommand,
	}
	w, spec := s.newWorker(r, randomID("w-"), "Coordinator", in.Task, "", "coordinator", r.Client, "localhost", r.Path)
	r.CoordinatorID = w.ID
	s.state.Runs = append(s.state.Runs, r)
	s.remember(key, intent, r.ID)
	return outcome{r, 201, true, func() { s.launch(spec) }}, nil
}

func (s *service) delegate(req *http.Request, actor string) (outcome, error) {
	r := s.run(req.PathValue("run"))
	if r == nil {
		return outcome{}, missing("run")
	}
	var in struct {
		Name, Task string
		ParentID   string `json:"parent_id"`
		Client     string `json:"client,omitempty"`
		Host       string `json:"host,omitempty"`
		Kind       string `json:"kind,omitempty"`
	}
	if err := decode(req, &in); err != nil {
		return outcome{}, err
	}
	if strings.TrimSpace(in.Name) == "" || strings.TrimSpace(in.Task) == "" {
		return outcome{}, bad("worker name and task are required")
	}
	if in.Kind != "" && in.Kind != "research" && in.Kind != "review" && in.Kind != "coding" {
		return outcome{}, bad("worker kind must be research, review, or coding")
	}
	if in.ParentID == "" {
		in.ParentID = actor
		if actor == "" {
			in.ParentID = r.CoordinatorID
		}
	}
	pr, p := s.worker(in.ParentID)
	if p == nil || pr != r || (actor != "" && actor != p.ID) {
		return outcome{}, denied()
	}
	key, intent, target, err := s.receipt(req, actor, in)
	if err != nil {
		return outcome{}, err
	}
	if target != "" {
		_, w := s.worker(target)
		return read(w), nil
	}
	if r.Status != "running" || p.State == "stopping" || ended(p.State) {
		return outcome{}, conflict("run or assigning parent is no longer active")
	}
	if r.activeWorkers() >= r.WorkerLimit {
		return outcome{}, conflict(fmt.Sprintf("run has reached its %d-worker limit", r.WorkerLimit))
	}
	client := strings.TrimSpace(in.Client)
	if client == "" {
		client = r.Client
	}
	host := strings.TrimSpace(in.Host)
	if host == "" {
		host = "localhost"
	}
	prepared, err := s.prepareLaunch(req.Context(), launchPrerequisites{
		client: client, path: r.Path, host: host, kind: in.Kind, agent: actor != "",
	})
	if err != nil {
		return outcome{}, err
	}
	w, spec := s.newWorker(r, prepared.id, in.Name, in.Task, p.ID, "worker", client, host, prepared.checkout)
	if prepared.isolated != nil {
		w.Branch, w.Coding, spec.CodingSource = prepared.isolated.Branch, prepared.isolated, prepared.source
	}
	s.remember(key, intent, w.ID)
	return outcome{w, 201, true, func() { s.launch(spec) }}, nil
}

func (s *service) own(req *http.Request, actor string) (*Run, *Worker, error) {
	r, w := s.worker(req.PathValue("worker"))
	if w == nil {
		return nil, nil, missing("worker")
	}
	if actor != w.ID {
		return nil, nil, denied()
	}
	if r.Status == "stopping" || r.Status == "stopped" || w.State == "stopping" || w.State == "stopped" {
		return nil, nil, conflict("run or worker is stopping or stopped")
	}
	return r, w, nil
}

func (s *service) output(req *http.Request, actor string) (outcome, error) {
	_, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	var in workerOutput
	if err := decode(req, &in); err != nil {
		return outcome{}, err
	}
	if len(in.Events) > 24 {
		return outcome{}, bad("too many console events")
	}
	if !in.ClaudeProgress.valid() {
		return outcome{}, bad("invalid Claude progress observation")
	}
	for i := range in.Events {
		event := &in.Events[i]
		if !event.ACP.Valid() {
			return outcome{}, bad("invalid ACP activity")
		}
		if len(event.Text) > 17<<10 || len(event.ToolID) > 256 || len(event.Name) > 256 || len(event.Phase) > 64 {
			return outcome{}, bad("console event exceeds size limit")
		}
		if event.CommanderInput != "" {
			if len(event.CommanderInput) > 160 {
				return outcome{}, bad("invalid Commander tool correlation")
			}
			event.CommanderInput = CommanderToolInput(event.Name, json.RawMessage(event.CommanderInput))
		}
	}
	previous, replay, err := s.checkOutputBatch(req, w, &in)
	if err != nil {
		return outcome{}, err
	}
	ack := read(map[string]string{"id": w.ID})
	if replay {
		return ack, nil
	}
	restoreFromOutput := w.State == "unknown" && in.Text != "" && w.ProviderAvailability != providerChecking
	durable := w.NativeSession == nil || restoreFromOutput
	before := *w
	w.observeClaudeProgress(in.ClaudeProgress)
	inserted := 0
	if in.Batch > 1 && previous.Stream == "" {
		inserted = 1
		in.Events = append([]ConsoleEvent{{Kind: "output", Text: "Earlier runner output is unavailable after service restart."}}, in.Events...)
	}
	const maxOutput = 64 << 10
	if restoreFromOutput {
		w.State, w.Error = "working", ""
	}
	w.Output += in.Text
	if len(w.Output) > maxOutput {
		i := len(w.Output) - maxOutput
		for i < len(w.Output) && !utf8.RuneStart(w.Output[i]) {
			i++
		}
		w.Output = w.Output[i:]
	}
	if len(in.Events) > 0 {
		sequence := 0
		if count := len(w.Console); count > 0 {
			sequence = w.Console[count-1].Sequence
		}
		for i := range in.Events {
			sequence++
			in.Events[i].Sequence = sequence
			w.observeTelemetry(in.Events[i].ACP)
		}
		w.Console = append(w.Console, in.Events...)
		if len(w.Console) > consoleEventWindow {
			w.Console = append([]ConsoleEvent(nil), w.Console[len(w.Console)-consoleEventWindow:]...)
		}
	}
	receipt := in.receipt(req)
	if durable {
		if w.NativeSession == nil && receipt.Stream != "" {
			if s.state.OutputBatches == nil {
				s.state.OutputBatches = make(map[string]outputReceipt)
			}
			s.state.OutputBatches[w.ID] = receipt
		}
		if err := s.persist(); err != nil {
			*w = before
			if w.NativeSession == nil && receipt.Stream != "" {
				if previous.Stream == "" {
					delete(s.state.OutputBatches, w.ID)
				} else {
					s.state.OutputBatches[w.ID] = previous
				}
			}
			return outcome{}, fmt.Errorf("persist runner output: %w", err)
		}
	} else {
		s.notifyConsoleOutput(w, in.Text, in.Events)
	}
	s.details.add(w.ID, s.details.prepare(in.Details, in.Events, inserted, lastSequence(w)))
	if w.NativeSession != nil && receipt.Stream != "" {
		if s.liveOutputBatches == nil {
			s.liveOutputBatches = make(map[string]outputReceipt)
		}
		s.liveOutputBatches[w.ID] = receipt
	}
	return ack, nil
}
func (s *service) ask(req *http.Request, actor string) (outcome, error) {
	r, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	var in struct {
		Question           string
		Choices            []QuestionChoice `json:",omitempty"`
		ProviderTurn       string           `json:"provider_turn,omitempty"`
		ProviderRequest    string           `json:"provider_request,omitempty"`
		ProviderToolCallID string           `json:"provider_tool_call_id,omitempty"`
	}
	if err := decode(req, &in); err != nil {
		return outcome{}, err
	}
	if strings.TrimSpace(in.Question) == "" {
		return outcome{}, bad("question is required")
	}
	if err := validateChoices(in.Choices); err != nil {
		return outcome{}, err
	}
	key, intent, target, err := s.receipt(req, actor, in)
	if err != nil {
		return outcome{}, err
	}
	if target != "" {
		_, q := s.question(target)
		return read(q), nil
	}
	sessionPermission := in.ProviderTurn == ACPSessionPermissionScope && w.PeerCapabilities != nil &&
		w.PeerCapabilities.ProtocolVersion == 2
	if in.ProviderTurn != "" || in.ProviderRequest != "" {
		if in.ProviderTurn == "" || !sessionPermission && in.ProviderTurn != activeProviderTurn(w) ||
			in.ProviderRequest == "" || len(in.ProviderRequest) > 256 || len(in.Choices) == 0 {
			return outcome{}, conflict("permission does not match the active provider turn")
		}
		if !sessionPermission && w.Control != nil && w.Control.InterruptClaimed {
			return read(Question{Status: "cancelled"}), nil
		}
	}
	if ended(w.State) && !(sessionPermission && w.Role == "worker" && w.State == "completed" &&
		w.Control != nil && r.Status == "running" && !w.providerBlocksControl()) {
		return outcome{}, conflict("worker has ended")
	}
	if w.State == "disconnected" {
		return outcome{}, conflict("SSH worker disconnected; reconcile the original session first")
	}
	q := &Question{ID: randomID("q-"), WorkerID: w.ID, Question: formatQuestion(in.Question, in.Choices), Status: "pending", Choices: in.Choices}
	if in.ProviderTurn != "" {
		if len(in.ProviderToolCallID) <= 256 {
			q.ProviderToolCallID = in.ProviderToolCallID
		}
		if s.state.Permissions == nil {
			s.state.Permissions = make(map[string]providerPermission)
		}
		s.state.Permissions[q.ID] = providerPermission{Turn: in.ProviderTurn, Request: in.ProviderRequest}
	}
	r.Requests = append(r.Requests, q)
	s.remember(key, intent, q.ID)
	return outcome{q, 201, true, nil}, nil
}
func (s *service) getQuestion(req *http.Request, actor string) (outcome, error) {
	r, q := s.question(req.PathValue("qid"))
	if q == nil || q.WorkerID != req.PathValue("worker") {
		return outcome{}, missing("question")
	}
	if !s.canRead(actor, r) {
		return outcome{}, denied()
	}
	if actor == q.WorkerID && q.Status == "answered" {
		_, worker := s.worker(q.WorkerID)
		if q.Delivery == "unknown" || worker.State == "disconnected" {
			return outcome{}, conflict("reply cannot be delivered to the disconnected SSH session")
		}
	}
	return read(q), nil
}

func (s *service) withdrawQuestion(req *http.Request, actor string) (outcome, error) {
	_, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	_, q := s.question(req.PathValue("qid"))
	if q == nil || q.WorkerID != w.ID {
		return outcome{}, missing("question")
	}
	if _, providerPermission := s.state.Permissions[q.ID]; providerPermission || len(q.Choices) != 0 {
		return outcome{}, conflict("provider permission requests cannot be withdrawn as ordinary questions")
	}
	switch q.Status {
	case "cancelled":
		return read(q), nil
	case "pending":
		q.Status = "cancelled"
		return changed(q), nil
	default:
		return outcome{}, conflict("only pending questions can be withdrawn")
	}
}

func (s *service) reply(req *http.Request, actor string) (outcome, error) {
	r, q := s.question(req.PathValue("qid"))
	if q == nil {
		return outcome{}, missing("question")
	}
	_, w := s.worker(q.WorkerID)
	if actor != "" && (actor == w.ID || (actor != r.CoordinatorID && actor != w.ParentID)) {
		return outcome{}, denied()
	}
	var in struct {
		Answer     string
		Generation *int
	}
	if err := decode(req, &in); err != nil {
		return outcome{}, err
	}
	if strings.TrimSpace(in.Answer) == "" {
		return outcome{}, bad("answer is required")
	}
	if len(q.Choices) > 0 && !slices.ContainsFunc(q.Choices, func(choice QuestionChoice) bool { return choice.ID == in.Answer }) {
		return outcome{}, bad("reply with the exact ID of an offered choice")
	}
	if q.Status == "answered" {
		if q.Answer != in.Answer {
			return outcome{}, conflict("request already answered")
		}
		return read(q), nil
	}
	if w.State == "disconnected" {
		return outcome{}, conflict("SSH worker disconnected; the original request is retained")
	}
	if actor != "" && w.Control != nil && w.Control.Held {
		return outcome{}, conflict("developer holds worker input")
	}
	// Native worker replies are bound to the input grant the developer saw. The
	// explicit owner API still accepts unversioned replies from existing clients.
	if actor == "" && w.ID != r.CoordinatorID && in.Generation != nil &&
		(w.Control == nil || !w.Control.Held || w.Control.Generation != *in.Generation) {
		return outcome{}, conflict("worker input control changed before the reply")
	}
	backgroundPermission := w.Role == "worker" && w.State == "completed" && w.Control != nil &&
		r.Status == "running" && !w.providerBlocksControl() &&
		s.state.Permissions[q.ID].Turn == ACPSessionPermissionScope
	if q.Status != "pending" || r.Status == "stopping" || r.Status == "stopped" ||
		w.State == "stopping" || ended(w.State) && !backgroundPermission {
		return outcome{}, conflict("the requesting worker is no longer running")
	}
	q.Answer, q.Status = in.Answer, "answered"
	if w.Host != "" && w.Host != "localhost" {
		q.Delivery = "unconfirmed"
	}
	return changed(q), nil
}
func (s *service) workerState(req *http.Request, actor string) (outcome, error) {
	r, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	var in struct{ State, Error string }
	if err := decode(req, &in); err != nil {
		return outcome{}, err
	}
	switch in.State {
	case "working", "waiting", "idle", "completed", "failed":
	default:
		return outcome{}, bad("invalid worker state")
	}
	if w.ProviderAvailability == providerChecking {
		return outcome{}, conflict("the original Claude turn must be reconciled first")
	}
	if w.ProviderAvailability == providerReattaching {
		if in.State != "failed" {
			return outcome{}, conflict("reattachment must confirm the original provider session first")
		}
		failReattachment(r, w, in.Error)
		return changed(w), nil
	}
	if w.State == "disconnected" {
		return outcome{}, conflict("SSH worker disconnected; reconcile the original session first")
	}
	if ended(w.State) && w.State != in.State {
		return outcome{}, conflict("worker has already ended")
	}
	if w.ID == r.CoordinatorID && r.InitialWorkspaceHandoffID != "" {
		if in.State == "working" {
			if h := s.state.WorkspaceHandoffs[r.InitialWorkspaceHandoffID]; h != nil && h.expiredBeforeClaim(time.Now()) {
				return s.expireWorkspaceHandoff(r, w, nil), nil
			}
			s.acceptWorkspaceHandoff(r.InitialWorkspaceHandoffID, w)
		} else if ended(in.State) {
			s.finishWorkspaceHandoff(req.Context(), r.InitialWorkspaceHandoffID, w, in.State, "")
			if in.State == "failed" {
				s.failWorkspaceHandoff(r.InitialWorkspaceHandoffID, w, "coordinator_failed")
			}
		}
	}
	w.State, w.Error = in.State, in.Error
	if ended(in.State) {
		r.cancelQuestions(w.ID)
		s.retireProviderPermissions(r, w.ID)
	}
	r.refreshOutcome()
	return changed(map[string]string{"id": w.ID, "state": w.State}), nil
}
func (s *service) workerResult(req *http.Request, actor string) (outcome, error) {
	_, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	var in struct {
		Result   string
		Revision string       `json:"revision,omitempty"`
		Tests    []CodingTest `json:"tests,omitempty"`
	}
	if err := decode(req, &in); err != nil {
		return outcome{}, err
	}
	if strings.TrimSpace(in.Result) == "" {
		return outcome{}, bad("result is required")
	}
	if in.Revision != "" {
		if w.Coding == nil {
			return outcome{}, conflict("worker has no assigned coding worktree")
		}
		if err := worktrees.VerifyRevision(req.Context(), *w.Coding, in.Revision); err != nil {
			return outcome{}, conflict(err.Error())
		}
		w.Handoff = &CodingHandoff{Revision: in.Revision, Findings: in.Result, Tests: in.Tests}
	}
	w.Result = in.Result
	return changed(map[string]string{"id": w.ID, "result": w.Result}), nil
}
func (s *service) stopRun(req *http.Request, actor string) (outcome, error) {
	r := s.run(req.PathValue("run"))
	if r == nil {
		return outcome{}, missing("run")
	}
	if actor != "" {
		return outcome{}, denied()
	}
	if r.Status == "stopped" || r.Status == "completed" {
		return read(r), nil
	}
	r.Status = "stopping"
	r.cancelQuestions("")
	var owned []string
	for _, w := range r.Workers {
		if w.State == "stopped" {
			continue
		}
		owned = append(owned, w.ID)
		w.State = "stopping"
		s.stopWorkerInbox(r, w)
	}
	return outcome{r, 200, true, func() { s.stop(r.ID, owned) }}, nil
}

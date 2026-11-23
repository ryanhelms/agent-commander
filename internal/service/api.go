package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"unicode/utf8"
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

func New(stateDir string, launcher Launcher) (http.Handler, error) {
	s := &service{launcher: launcher}
	if err := s.load(stateDir); err != nil {
		return nil, err
	}
	// Agents reattach using their existing credentials. An uncertain launch never
	// creates a second tmux session. Fresh authenticated worker events restore state.
	dirty := false
	for _, run := range s.state.Runs {
		for _, w := range run.Workers {
			if run.Status == "running" && w.State != "unknown" && w.State != "stopping" && !ended(w.State) {
				w.State, w.Error = "unknown", "Service restarted. Waiting for evidence from the original worker."
				if w.Control != nil {
					for i := range w.Control.Messages {
						if w.Control.Messages[i].Status == "processing" {
							w.Control.Messages[i].Status = "delivery_unknown"
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
				if w.Role == "worker" && w.State == "stopping" {
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
	mux.HandleFunc("GET /v1/ag-ui/events", s.streamConsole)
	mux.HandleFunc("GET /v1/workers/{worker}/history", s.serveNativeHistoryPage)
	mux.HandleFunc("GET /v1/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"status":"ok"}`+"\n")
	})
	for pattern, op := range map[string]endpoint{
		"GET /v1/runs": s.listRuns, "POST /v1/runs": s.createRun,
		"GET /v1/runs/{run}": s.getRun, "POST /v1/runs/{run}/workers": s.delegate,
		"POST /v1/runs/{run}/stop": s.stopRun, "POST /v1/workers/{worker}/output": s.output,
		"POST /v1/workers/{worker}/questions": s.ask, "GET /v1/workers/{worker}/questions/{qid}": s.getQuestion,
		"POST /v1/requests/{qid}/reply": s.reply, "POST /v1/workers/{worker}/state": s.workerState,
		"POST /v1/workers/{worker}/result":                   s.workerResult,
		"POST /v1/workers/{worker}/native-session":           s.bindNativeSession,
		"GET /v1/workers/{worker}/control":                   s.workerControlStatus,
		"POST /v1/workers/{worker}/control":                  s.setWorkerControl,
		"POST /v1/workers/{worker}/control/ready":            s.workerControlReady,
		"POST /v1/workers/{worker}/control/finish":           s.finishWorkerTurn,
		"POST /v1/workers/{worker}/control/interrupt/claim":  s.claimWorkerInterrupt,
		"POST /v1/workers/{worker}/messages":                 s.sendWorkerMessage,
		"POST /v1/workers/{worker}/messages/{message}/claim": s.claimWorkerMessage,
		"POST /v1/workers/{worker}/interrupt":                s.interruptWorker,
		"POST /v1/workers/{worker}/stop":                     s.stopWorker,
	} {
		mux.HandleFunc(pattern, s.handle(op))
	}
	return mux, nil
}

func (s *service) handle(op endpoint) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
		// Read the bounded body before taking the shared state lock.
		if r.Method == "POST" {
			raw, err := io.ReadAll(r.Body)
			if err != nil {
				respondError(w, bad("request exceeds size limit or could not be read"))
				return
			}
			r = r.WithContext(context.WithValue(r.Context(), bodyKey{}, raw))
		}
		s.mu.Lock()
		actor := ""
		if _, present := r.Header["Authorization"]; present {
			bearer, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
			actor = s.state.Tokens[digest(bearer)]
			if !ok || bearer == "" || actor == "" {
				s.mu.Unlock()
				respondError(w, &apiError{401, "invalid worker credential"})
				return
			}
		}
		var before []byte
		if r.Method == "POST" {
			before, _ = json.Marshal(&s.state)
		}
		res, err := op(r, actor)
		if err == nil && res.mutated {
			if e := s.persist(); e != nil {
				var restored database
				if restoreErr := json.Unmarshal(before, &restored); restoreErr != nil {
					panic(restoreErr)
				}
				s.state = restored
				err = fmt.Errorf("persist Commander state: %w", e)
			}
		}
		var body []byte
		if err == nil {
			body, err = json.Marshal(res.body)
		}
		s.mu.Unlock()
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
	key = digest(actor + "\x00" + req.URL.Path + "\x00" + raw)
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
		WorkerLimit                 int    `json:"worker_limit"`
		Title                       string `json:"title,omitempty"`
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
	in.Path = filepath.Clean(in.Path)
	key, intent, target, err := s.receipt(req, actor, in)
	if err != nil {
		return outcome{}, err
	}
	if target != "" {
		return read(s.run(target)), nil
	}
	info, err := os.Stat(in.Path)
	if err != nil || !info.IsDir() {
		return outcome{}, bad("project path must be an existing directory")
	}
	if in.Project == "" {
		in.Project = filepath.Base(in.Path)
	}
	if in.Client == "" {
		in.Client = "claude"
	}
	if launcher, ok := s.launcher.(interface{ CheckClient(string) error }); ok {
		if err := launcher.CheckClient(in.Client); err != nil {
			return outcome{}, conflict(err.Error())
		}
	}
	title := displayTitle(in.Title)
	if title == "" {
		title = displayTitle(in.Task)
	}
	r := &Run{
		ID: randomID("r-"), Project: in.Project, Path: in.Path, Task: in.Task, Client: in.Client,
		Title: title, CreatedAt: timestamp(), Branch: checkoutBranch(req.Context(), in.Path),
		Status: "running", WorkerLimit: in.WorkerLimit, Requests: []*Question{},
	}
	w, spec := s.newWorker(r, "Coordinator", in.Task, "", "coordinator", r.Client, "localhost", r.Path)
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
	}
	if err := decode(req, &in); err != nil {
		return outcome{}, err
	}
	if strings.TrimSpace(in.Name) == "" || strings.TrimSpace(in.Task) == "" {
		return outcome{}, bad("worker name and task are required")
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
	host, checkout := strings.TrimSpace(in.Host), r.Path
	if host == "" {
		host = "localhost"
	}
	if host == "localhost" {
		if launcher, ok := s.launcher.(interface{ CheckClient(string) error }); ok {
			if err := launcher.CheckClient(client); err != nil {
				return outcome{}, conflict(err.Error())
			}
		}
	} else {
		placement, ok := s.launcher.(hostPlacement)
		if !ok {
			return outcome{}, conflict("SSH hosts are unavailable")
		}
		var err error
		checkout, err = placement.WorkerCheckout(host, r.Path, client)
		if err != nil {
			return outcome{}, conflict(err.Error())
		}
	}
	w, spec := s.newWorker(r, in.Name, in.Task, p.ID, "worker", client, host, checkout)
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
	var in struct {
		Text   string
		Events []ConsoleEvent
	}
	if err := decode(req, &in); err != nil {
		return outcome{}, err
	}
	if len(in.Events) > 24 {
		return outcome{}, bad("too many console events")
	}
	for _, event := range in.Events {
		if len(event.Text) > 17<<10 || len(event.ToolID) > 256 || len(event.Name) > 256 {
			return outcome{}, bad("console event exceeds size limit")
		}
	}
	const maxOutput = 64 << 10
	if w.State == "unknown" && in.Text != "" {
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
		for _, event := range in.Events {
			sequence++
			event.Sequence = sequence
			w.Console = append(w.Console, event)
		}
		const eventWindow = 128
		if len(w.Console) > eventWindow {
			w.Console = append([]ConsoleEvent(nil), w.Console[len(w.Console)-eventWindow:]...)
		}
	}
	return changed(map[string]string{"id": w.ID}), nil
}
func (s *service) ask(req *http.Request, actor string) (outcome, error) {
	r, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	var in struct {
		Question string
		Choices  []QuestionChoice `json:",omitempty"`
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
	if ended(w.State) {
		return outcome{}, conflict("worker has ended")
	}
	q := &Question{ID: randomID("q-"), WorkerID: w.ID, Question: formatQuestion(in.Question, in.Choices), Status: "pending", Choices: in.Choices}
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
	return read(q), nil
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
	var in struct{ Answer string }
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
	if actor != "" && w.Control != nil && w.Control.Held {
		return outcome{}, conflict("developer holds worker input")
	}
	if q.Status != "pending" || r.Status == "stopping" || r.Status == "stopped" || w.State == "stopping" || ended(w.State) {
		return outcome{}, conflict("the requesting worker is no longer running")
	}
	q.Answer, q.Status = in.Answer, "answered"
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
	if ended(w.State) && w.State != in.State {
		return outcome{}, conflict("worker has already ended")
	}
	w.State, w.Error = in.State, in.Error
	if ended(in.State) {
		r.cancelQuestions(w.ID)
	}
	r.refreshOutcome()
	return changed(map[string]string{"id": w.ID, "state": w.State}), nil
}
func (s *service) workerResult(req *http.Request, actor string) (outcome, error) {
	_, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	var in struct{ Result string }
	if err := decode(req, &in); err != nil {
		return outcome{}, err
	}
	if strings.TrimSpace(in.Result) == "" {
		return outcome{}, bad("result is required")
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
		stopWorkerInbox(w)
	}
	return outcome{r, 200, true, func() { s.stop(r.ID, owned) }}, nil
}

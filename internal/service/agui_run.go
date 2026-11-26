package service

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"slices"
	"time"

	"agentcommander/internal/hosted"
)

// A run targets one known worker. The thread ID is the stable Commander
// worker ID and the run ID identifies this submission across retries.
type aguiRunInput struct {
	ThreadID string `json:"threadId"`
	RunID    string `json:"runId"`
	Messages []struct {
		Role    string          `json:"role"`
		Content json.RawMessage `json:"content"`
	} `json:"messages"`
	Tools          []frontendTool `json:"tools"`
	ForwardedProps struct {
		Generation *int `json:"generation"`
	} `json:"forwardedProps"`
}

type frontendIntentKey struct{}

type aguiRunState struct {
	WorkerID             string                `json:"workerId"`
	Status               string                `json:"status"`
	OperationID          string                `json:"operationId"`
	OperationStatus      string                `json:"operationStatus"`
	PendingRequests      []Question            `json:"pendingRequests"`
	Requests             []Question            `json:"requests"`
	UnconfirmedToolCalls []unconfirmedToolCall `json:"unconfirmedToolCalls,omitempty"`
}

func (s *service) replyToWorkerRun(r *http.Request, actor string) (outcome, error) {
	if actor != "" {
		return outcome{}, denied()
	}
	_, question := s.question(r.PathValue("qid"))
	if question == nil || question.WorkerID != r.PathValue("worker") {
		return outcome{}, missing("worker request")
	}
	if hosted.From(r.Context()) != nil && question.Status == "pending" {
		var input struct{ Generation *int }
		if err := decode(r, &input); err != nil {
			return outcome{}, err
		}
		_, worker := s.worker(question.WorkerID)
		if worker == nil || worker.Control == nil || !worker.Control.Held ||
			input.Generation == nil || *input.Generation != worker.Control.Generation {
			return outcome{}, conflict("worker input is held by another controller")
		}
	}
	return s.reply(r, actor)
}

func (s *service) workerRunInfo(r *http.Request, actor string) (outcome, error) {
	if actor != "" {
		return outcome{}, denied()
	}
	run, worker := s.worker(r.PathValue("worker"))
	if worker == nil {
		return outcome{}, missing("worker")
	}
	payload := map[string]any{
		"workerId": worker.ID, "role": worker.Role, "status": worker.State, "client": worker.Client,
		"runId": run.ID, "runStatus": run.Status,
		"nativeHistory": worker.NativeSession != nil,
	}
	if worker.FrontendTools {
		payload["frontendTools"] = true
	}
	if worker.Control != nil && worker.Control.PromptCapabilities != nil {
		payload["promptCapabilities"] = worker.Control.PromptCapabilities
	}
	if worker.Control != nil && worker.Control.SessionCapabilities != nil {
		payload["sessionCapabilities"] = worker.Control.SessionCapabilities
	}
	if canFollowUp(run, worker) && worker.Control.Held {
		payload["generation"] = worker.Control.Generation
	}
	return read(payload), nil
}

func (s *service) streamWorkerRun(w http.ResponseWriter, r *http.Request) {
	// Hosted requests arrive through the authorized gateway context.
	if _, supplied := r.Header["Authorization"]; supplied {
		respondError(w, denied())
		return
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	var input aguiRunInput
	if err != nil || json.Unmarshal(raw, &input) != nil || input.RunID == "" || len(input.RunID) > 128 ||
		input.ThreadID != r.PathValue("worker") || input.ForwardedProps.Generation == nil {
		respondError(w, bad("expected matching threadId, runId and forwardedProps.generation"))
		return
	}
	if err := compileFrontendTools(input.Tools); err != nil {
		respondError(w, err)
		return
	}
	if count := len(input.Messages); count == 0 || input.Messages[count-1].Role != "user" {
		respondError(w, bad("the last message must be a user message with text content"))
		return
	}
	prompt, parts, err := aguiPrompt(input.Messages[len(input.Messages)-1].Content)
	if err != nil {
		respondError(w, err)
		return
	}
	if err := s.checkPromptResourceScope(r, parts); err != nil {
		respondError(w, err)
		return
	}
	body, _ := json.Marshal(struct {
		Text       string
		Generation int
	}{prompt, *input.ForwardedProps.Generation})
	command := context.WithValue(r.Context(), bodyKey{}, body)
	command = context.WithValue(command, frontendIntentKey{}, input.Tools)
	command = context.WithValue(command, promptPartsKey{}, parts)
	toSend := r.Clone(command)
	toSend.Header.Set("Idempotency-Key", input.RunID)
	s.mu.Lock()
	var toolAccess *hosted.Access
	if len(input.Tools) != 0 {
		if access := hosted.From(r.Context()); access != nil {
			toolAccess = access.WithScope(frontendToolScope)
			if !toolAccess.Allowed() {
				s.mu.Unlock()
				respondError(w, denied())
				return
			}
		}
		_, worker := s.worker(input.ThreadID)
		if worker != nil && !worker.FrontendTools {
			s.mu.Unlock()
			respondError(w, &apiError{http.StatusNotImplemented, "worker has no verified frontend tool bridge"})
			return
		}
	}
	result, err := s.applyEndpoint(toSend, "", s.sendWorkerMessage)
	if err != nil {
		s.mu.Unlock()
		respondError(w, err)
		return
	}
	operation := result.body.(WorkerFollowUp).ID
	if result.code == http.StatusAccepted && len(input.Tools) != 0 {
		s.addFrontendRound(input.ThreadID, operation, receiptActor(r, ""), toolAccess, input.Tools)
	} else if toolAccess != nil {
		s.renewFrontendRound(toSend, input.ThreadID, operation)
	}
	s.mu.Unlock()
	s.streamWorkerOperation(w, r, input.ThreadID, input.RunID, operation)
}

type aguiRunReceipt struct {
	RunID       string `json:"runId"`
	OperationID string `json:"operationId"`
}

func (s *service) workerRunReceipt(r *http.Request, actor string) (outcome, error) {
	if actor != "" {
		return outcome{}, denied()
	}
	receipt, err := s.lookupWorkerRun(r)
	return read(receipt), err
}

// lookupWorkerRun runs with the state lock held.
func (s *service) lookupWorkerRun(r *http.Request) (aguiRunReceipt, error) {
	runID := r.URL.Query().Get("runId")
	if runID == "" || len(runID) > 128 {
		return aguiRunReceipt{}, bad("runId is required")
	}
	runPath := "/v1/ag-ui/workers/" + r.PathValue("worker") + "/run"
	key := receiptKey(receiptActor(r, ""), runPath, runID)
	receipt, found := s.state.Receipts[key]
	if !found {
		return aguiRunReceipt{}, missing("worker operation")
	}
	return aguiRunReceipt{RunID: runID, OperationID: receipt.Target}, nil
}

func (s *service) observeWorkerRun(w http.ResponseWriter, r *http.Request) {
	if _, supplied := r.Header["Authorization"]; supplied {
		respondError(w, denied())
		return
	}
	s.mu.Lock()
	receipt, err := s.lookupWorkerRun(r)
	if err == nil {
		if receipt.OperationID == r.PathValue("operation") {
			s.renewFrontendRound(r, r.PathValue("worker"), receipt.OperationID)
		} else {
			err = missing("worker operation")
		}
	}
	s.mu.Unlock()
	if err != nil {
		respondError(w, err)
		return
	}
	s.streamWorkerOperation(w, r, r.PathValue("worker"), receipt.RunID, receipt.OperationID)
}

// renewFrontendRound runs under the state lock after the operation receipt is proved.
func (s *service) renewFrontendRound(r *http.Request, worker, operation string) {
	if access := hosted.From(r.Context()); access != nil {
		actor := access.ReceiptActor()
		for _, round := range s.frontendRounds[worker] {
			if round.operation == operation && round.actor == actor {
				round.renew(access)
				return
			}
		}
	}
}

func (s *service) streamWorkerOperation(w http.ResponseWriter, r *http.Request, workerID, runID, operation string) {
	notify := make(chan struct{}, 1)
	s.mu.Lock()
	if s.operationObservers == nil {
		s.operationObservers = make(map[chan struct{}]string)
	}
	s.operationObservers[notify] = workerID
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.operationObservers, notify)
		s.mu.Unlock()
	}()

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store, no-transform")
	w.Header().Set("X-Accel-Buffering", "no")
	dispatchTools := r.URL.Query().Get("frontendTools") != "observe"
	if !dispatchTools {
		w.Header().Set("Commander-Frontend-Tools", "observe")
	}
	writer := http.NewResponseController(w)
	write := func(frame []byte) error {
		if access := hosted.From(r.Context()); access != nil && !access.Allowed() {
			return context.Canceled
		}
		_ = writer.SetWriteDeadline(time.Now().Add(8 * time.Second))
		defer writer.SetWriteDeadline(time.Time{})
		if _, err := w.Write(frame); err != nil {
			return err
		}
		return writer.Flush()
	}
	send := func(event any) error {
		payload, err := json.Marshal(event)
		if err != nil {
			return err
		}
		frame := make([]byte, 0, len(payload)+8)
		frame = append(frame, "data: "...)
		frame = append(frame, payload...)
		return write(append(frame, '\n', '\n'))
	}
	lifecycle := func(kind string) map[string]any {
		return map[string]any{"type": kind, "threadId": workerID, "runId": runID}
	}
	if send(lifecycle("RUN_STARTED")) != nil {
		return
	}
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	var lastState *aguiRunState
	var console operationConsole
	var output operationMessageStream
	incremental := r.URL.Query().Get("projection") == "incremental"
	sentCalls, sentResults := make(map[string]bool), make(map[string]bool)
	for {
		state, events, gap := s.workerRunView(workerID, operation)
		if incremental {
			console.checkContinuity(events)
			if gap == "" || (console.notice != "" && len(events) > 0) {
				gap = console.notice
			}
		}
		messages := console.project(workerID, events)
		// Call and gap overlays are private to this authorized operation.
		messages = messages[:len(messages):len(messages)]
		if gap != "" {
			messages = append([]aguiMessage{operationPreviewGap(operation, gap)}, messages...)
		}
		calls, resultError := s.frontendCalls(r, workerID, operation)
		if resultError != nil {
			gap := "Retained frontend tool results are unavailable for this operation."
			messages = append(messages, aguiMessage{ID: "frontend-gap-" + operation, Role: "system", Content: &gap})
		}
		for _, call := range calls {
			if call.dispatched && call.Result == nil && !sentCalls[call.ID] {
				state.UnconfirmedToolCalls = append(state.UnconfirmedToolCalls, unconfirmedToolCall{
					ID: call.ID, Name: call.Name, Arguments: call.Arguments,
				})
			}
		}
		if lastState == nil {
			if send(map[string]any{"type": "STATE_SNAPSHOT", "snapshot": state}) != nil {
				return
			}
		} else if changes := operationStateDelta(*lastState, state); len(changes) > 0 {
			if incremental {
				if send(aguiStateEvent{Type: "STATE_DELTA", Delta: changes}) != nil {
					return
				}
			} else if send(map[string]any{"type": "STATE_SNAPSHOT", "snapshot": state}) != nil {
				return
			}
		}
		for _, call := range calls {
			// Deliver a live result once, then send the authoritative message
			// including its error and chronological position, even on the final tick.
			if call.Result != nil && sentCalls[call.ID] && !sentResults[call.ID] {
				event := map[string]any{"type": "TOOL_CALL_RESULT", "toolCallId": call.ID,
					"messageId": "result-" + call.ID, "role": "tool", "content": call.Result.Content}
				if call.Result.Error != "" {
					event["error"] = call.Result.Error
				}
				if send(event) != nil {
					return
				}
				sentResults[call.ID] = true
			}
			if sentCalls[call.ID] || call.Result != nil {
				messages = append(messages, call.message())
			}
			if call.Result != nil {
				messages = append(messages, call.resultMessage())
			}
		}
		lastState = &state
		active := state.OperationStatus == "queued" || state.OperationStatus == "processing"
		frame, err := output.frame(messages, incremental && len(calls) == 0, active && len(calls) == 0)
		if err != nil || (len(frame) > 0 && write(frame) != nil) {
			return
		}
		for _, call := range calls {
			if !sentCalls[call.ID] && call.Result != nil {
				// A reconnect restores resolved tools as messages so it never
				// presents them to the app as new work.
				sentCalls[call.ID], sentResults[call.ID] = true, true
				continue
			}
			if dispatchTools && !sentCalls[call.ID] && !call.dispatched && s.dispatchFrontendCall(r, workerID, operation, call.ID) {
				start := map[string]any{"type": "TOOL_CALL_START", "toolCallId": call.ID,
					"toolCallName": call.Name, "parentMessageId": "frontend-" + call.ID,
					"metadata": map[string]any{"commanderOperationId": operation}}
				args := map[string]any{"type": "TOOL_CALL_ARGS", "toolCallId": call.ID, "delta": string(call.Arguments)}
				end := map[string]any{"type": "TOOL_CALL_END", "toolCallId": call.ID,
					"metadata": map[string]any{"commanderOperationId": operation}}
				if send(start) != nil || send(args) != nil || send(end) != nil {
					return
				}
				sentCalls[call.ID] = true
			}

		}
		switch state.OperationStatus {
		case "completed", "interrupted", "cancelled":
			_ = send(lifecycle("RUN_FINISHED"))
			return
		case "failed", "delivery_unknown", "unavailable":
			event := lifecycle("RUN_ERROR")
			event["message"] = "Worker operation " + state.OperationStatus
			_ = send(event)
			return
		}
		select {
		case <-r.Context().Done():
			return
		case <-notify:
		case <-ticker.C:
			if write([]byte(": heartbeat\n\n")) != nil {
				return
			}
		}
	}
}

// A workspace commit can affect any operation. Native output belongs to one
// worker, so unrelated hosted observers can stay asleep.
func (s *service) notifyOperations(workerID string) {
	for observer, worker := range s.operationObservers {
		if workerID == "" || workerID == worker {
			select {
			case observer <- struct{}{}:
			default:
			}
		}
	}
}

func (s *service) workerRunView(workerID, operation string) (aguiRunState, []ConsoleEvent, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state := aguiRunState{WorkerID: workerID, OperationID: operation, OperationStatus: "unavailable",
		PendingRequests: []Question{}, Requests: []Question{}}
	var gap string
	run, worker := s.worker(workerID)
	if worker == nil || worker.Control == nil {
		return state, nil, ""
	}
	receipt := worker.Control.message(operation)
	if receipt == nil {
		return state, nil, ""
	}
	state.Status, state.OperationStatus = worker.State, receipt.Status
	requests, events := run.Requests, worker.Console
	active := receipt.Status == "queued" || receipt.Status == "processing"
	if !active {
		end := receipt.End
		if end == nil {
			state.Status = ""
			return state, nil, "No conversation boundary was recorded for this operation. Open the worker's history for its available transcript."
		}
		state.Status = end.WorkerState
		requests = requests[:max(0, min(end.RequestCount, len(requests)))]
		events, gap = s.completedOperationPreview(worker, end)
	}
	const resolvedLimit = 128
	resolved := 0
	for i := len(requests) - 1; i >= 0; i-- {
		q := requests[i]
		if q.WorkerID != workerID {
			continue
		}
		if q.Status == "pending" {
			if !active {
				continue
			}
			state.PendingRequests = append(state.PendingRequests, *q)
		} else {
			if resolved >= resolvedLimit {
				continue
			}
			resolved++
		}
		state.Requests = append(state.Requests, *q)
	}
	slices.Reverse(state.PendingRequests)
	slices.Reverse(state.Requests)
	return state, events, gap
}

func operationPreviewGap(operation, text string) aguiMessage {
	return aguiMessage{ID: "preview-gap-" + operation, Role: "system", Content: &text}
}

func (s *service) completedOperationPreview(worker *Worker, end *operationEnd) ([]ConsoleEvent, string) {
	const unavailable = "The console preview for this operation is unavailable. Open the worker's history for its available transcript."
	if worker.NativeSession != nil && (end.ConsoleInstance == "" || end.ConsoleInstance != s.consoleInstance) {
		return nil, unavailable
	}
	if end.Sequence == 0 {
		return nil, ""
	}
	events := worker.Console
	if len(events) == 0 || events[0].Sequence > end.Sequence || lastSequence(worker) < end.Sequence {
		return nil, unavailable
	}
	if after := slices.IndexFunc(events, func(event ConsoleEvent) bool { return event.Sequence > end.Sequence }); after >= 0 {
		events = events[:after]
	}
	if events[0].Sequence > 1 {
		return events, "Earlier output for this operation is outside the retained console preview."
	}
	return events, ""
}

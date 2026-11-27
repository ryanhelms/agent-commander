package service

import (
	"context"
	"net/http"
	"slices"
	"strings"
)

// WorkerControl is the durable lease and addressed inbox for a managed Claude
// worker. Only the local developer may change the lease. Each queued follow-up
// is bound to the generation under which it was accepted.
type WorkerControl struct {
	Generation          int                  `json:"generation"`
	Held                bool                 `json:"held"`
	InterruptRequested  bool                 `json:"interrupt_requested,omitempty"`
	InterruptClaimed    bool                 `json:"interrupt_claimed,omitempty"`
	Messages            []WorkerFollowUp     `json:"messages,omitempty"`
	PromptCapabilities  *PromptCapabilities  `json:"prompt_capabilities,omitempty"`
	SessionCapabilities *SessionCapabilities `json:"session_capabilities,omitempty"`
	Interrupt           *WorkerInterrupt     `json:"interrupt,omitempty"`
	ActiveTurnID        string               `json:"active_turn_id,omitempty"`
	LastStopReason      string               `json:"last_stop_reason,omitempty"`
}

// SessionCapabilities records the non-media operations negotiated by the SDK.
// A nil capability set on an older worker preserves its existing controls.
type SessionCapabilities struct {
	ProtocolVersion int  `json:"protocol_version,omitempty"`
	CanAnswer       bool `json:"can_answer"`
	CanInterrupt    bool `json:"can_interrupt"`
	CanResume       bool `json:"can_resume"`
	CanListSessions bool `json:"can_list_sessions"`
	CanReadHistory  bool `json:"can_read_history"`
}

type WorkerFollowUp struct {
	ID         string        `json:"id"`
	Status     string        `json:"status"`
	Text       string        `json:"text"`
	Generation int           `json:"generation"`
	End        *operationEnd `json:"end,omitempty"`
	StopReason string        `json:"stop_reason,omitempty"`
}

type operationEnd struct {
	Sequence        int    `json:"sequence"`
	RequestCount    int    `json:"request_count"`
	WorkerState     string `json:"worker_state"`
	ConsoleInstance string `json:"console_instance,omitempty"`
}

func (s *service) markOperationEnd(run *Run, worker *Worker, message *WorkerFollowUp) {
	end := &operationEnd{Sequence: lastSequence(worker), RequestCount: len(run.Requests), WorkerState: worker.State}
	if worker.NativeSession != nil {
		end.ConsoleInstance = s.consoleInstance
	}
	message.End = end
	delete(s.state.PromptParts, message.ID)
}

// ClaimedWorkerFollowUp exposes ordered attachments only to the worker that
// claimed this command.
type ClaimedWorkerFollowUp struct {
	WorkerFollowUp
	Parts []PromptPart `json:"parts,omitempty"`
}

func (c *WorkerControl) message(id string) *WorkerFollowUp {
	for i := range c.Messages {
		if c.Messages[i].ID == id {
			return &c.Messages[i]
		}
	}
	return nil
}

func (c *WorkerControl) next() *WorkerFollowUp {
	for i := range c.Messages {
		m := &c.Messages[i]
		if m.Status == "queued" && m.Generation == c.Generation {
			return m
		}
	}
	return nil
}

func (c *WorkerControl) hasProcessingMessage() bool {
	return slices.ContainsFunc(c.Messages, func(message WorkerFollowUp) bool { return message.Status == "processing" })
}

func turnActive(state string) bool {
	return state == "working" || state == "waiting"
}

func canFollowUp(r *Run, w *Worker) bool {
	return r.Status == "running" && w.Control != nil && !w.providerBlocksControl() &&
		(turnActive(w.State) || w.State == "idle" || w.State == "completed")
}

func (s *service) controlTarget(req *http.Request, actor string) (*Run, *Worker, error) {
	r, w := s.worker(req.PathValue("worker"))
	if w == nil {
		return nil, nil, missing("worker")
	}
	localCoordinator := actor == "" && localSessionOwner(req) && w.Role == "coordinator" &&
		w.ID == r.CoordinatorID && w.Control != nil
	if !localCoordinator && (w.Role != "worker" || (actor != "" && actor != w.ParentID && actor != r.CoordinatorID)) {
		return nil, nil, denied()
	}
	return r, w, nil
}

func (s *service) setWorkerControl(req *http.Request, actor string) (outcome, error) {
	if actor != "" {
		return outcome{}, denied()
	}
	r, w, err := s.controlTarget(req, actor)
	if err != nil {
		return outcome{}, err
	}
	if !canFollowUp(r, w) {
		return outcome{}, conflict("this worker cannot accept follow-ups right now")
	}
	var input struct {
		Held       *bool
		Generation int
	}
	if err := decode(req, &input); err != nil {
		return outcome{}, err
	}
	if input.Held == nil {
		return outcome{}, bad("held is required")
	}
	c := w.Control
	if c.Held == *input.Held {
		return read(c), nil
	}
	if c.Generation != input.Generation {
		return outcome{}, conflict("worker control changed; refresh its current owner")
	}
	c.Held = *input.Held
	c.Generation++
	if !c.InterruptClaimed {
		c.closeInterrupt()
		c.InterruptRequested = false
	}
	for i := range c.Messages {
		if c.Messages[i].Status == "queued" {
			c.Messages[i].Status = "cancelled"
			s.markOperationEnd(r, w, &c.Messages[i])
		}
	}
	r.refreshOutcome()
	return changed(c), nil
}

func (s *service) sendWorkerMessage(req *http.Request, actor string) (outcome, error) {
	r, w, err := s.controlTarget(req, actor)
	if err != nil {
		return outcome{}, err
	}
	var input struct {
		Text       string
		Generation int
	}
	if err := decode(req, &input); err != nil {
		return outcome{}, err
	}
	parts, agui := req.Context().Value(promptPartsKey{}).([]PromptPart)
	textOnly := !slices.ContainsFunc(parts, func(part PromptPart) bool { return part.Type != "text" })
	if (textOnly && strings.TrimSpace(input.Text) == "") || len(input.Text) > 16<<10 {
		return outcome{}, bad("follow-up must contain between 1 and 16384 bytes")
	}
	tools, _ := req.Context().Value(frontendIntentKey{}).([]frontendTool)
	receiptInput := struct {
		Text       string
		Generation int
		Tools      []frontendTool `json:",omitempty"`
		Parts      []PromptPart   `json:",omitempty"`
	}{input.Text, input.Generation, tools, parts}
	if agui && textOnly {
		// Bind the receipt to exactly what the adapter receives, including
		// empty blocks. A string and a single text block have the same wire form.
		receiptInput.Text = ""
		if len(parts) == 0 {
			receiptInput.Parts = []PromptPart{{Type: "text", Text: input.Text}}
		}
	}
	key, intent, target, err := s.receipt(req, actor, receiptInput)
	if err != nil && key != "" && agui && textOnly {
		// Older AG-UI receipts retained only the concatenated text. Recover
		// their original operation without changing its payload or resending.
		receiptInput.Text, receiptInput.Parts = input.Text, nil
		key, intent, target, err = s.receipt(req, actor, receiptInput)
	}
	if err != nil {
		return outcome{}, err
	}
	c := w.Control
	if target != "" && c != nil {
		if existing := c.message(target); existing != nil {
			return read(*existing), nil
		}
	}
	if w.ProviderAvailability == providerExited {
		if w.Error != "" {
			return outcome{}, conflict(w.Error + "; inspect the worker's source")
		}
		return outcome{}, conflict("the local Claude adapter exited; inspect the worker's source")
	}
	if !canFollowUp(r, w) {
		return outcome{}, conflict("this worker cannot accept follow-ups right now")
	}
	if (actor == "" && (!c.Held || c.Generation != input.Generation)) || (actor != "" && c.Held) {
		return outcome{}, conflict("worker input is held by another controller")
	}
	if !c.PromptCapabilities.allows(parts) {
		return outcome{}, &apiError{http.StatusNotImplemented, "the worker does not advertise support for these prompt parts"}
	}
	if c.next() != nil {
		return outcome{}, conflict("this worker already has a queued follow-up")
	}
	m := WorkerFollowUp{ID: randomID("m-"), Status: "queued", Text: input.Text, Generation: c.Generation}
	c.Messages = append(c.Messages, m)
	if len(parts) > 0 {
		if s.state.PromptParts == nil {
			s.state.PromptParts = make(map[string][]PromptPart)
		}
		s.state.PromptParts[m.ID] = parts
	}
	s.remember(key, intent, m.ID)
	return outcome{m, 202, true, nil}, nil
}

// cancelWorkerMessage removes the developer's queued follow-up. A claimed
// message is already with the provider; interrupt the turn instead.
func (s *service) cancelWorkerMessage(req *http.Request, actor string) (outcome, error) {
	if !localOwner(req, actor) {
		return outcome{}, denied()
	}
	r, w, err := s.controlTarget(req, actor)
	if err != nil {
		return outcome{}, err
	}
	if w.Control == nil {
		return outcome{}, missing("follow-up")
	}
	m := w.Control.message(req.PathValue("message"))
	if m == nil {
		return outcome{}, missing("follow-up")
	}
	if m.Status == "cancelled" {
		return read(*m), nil
	}
	if m.Status != "queued" {
		return outcome{}, conflict("this follow-up is no longer queued")
	}
	m.Status = "cancelled"
	s.markOperationEnd(r, w, m)
	r.refreshOutcome()
	return changed(*m), nil
}

type workerControlFeed struct {
	Revision             string                `json:"revision,omitempty"`
	Answers              []workerControlAnswer `json:"answers,omitempty"`
	Live                 bool                  `json:"live"`
	NextMessageID        string                `json:"next_message_id,omitempty"`
	InterruptRequested   bool                  `json:"interrupt_requested,omitempty"`
	InterruptID          string                `json:"interrupt_id,omitempty"`
	Generation           int                   `json:"generation,omitempty"`
	State                string                `json:"state,omitempty"`
	ProviderAvailability string                `json:"provider_availability,omitempty"`
}

func (s *service) workerControlSnapshot(workerID, actor, turn string) (workerControlFeed, error) {
	r, w := s.worker(workerID)
	if w == nil {
		return workerControlFeed{}, missing("worker")
	}
	if actor != w.ID || (w.Role != "worker" && w.Control == nil && turn == "") {
		return workerControlFeed{}, denied()
	}
	feed := workerControlFeed{State: w.State, ProviderAvailability: w.ProviderAvailability, Live: r.Status == "running" && w.Control != nil &&
		w.ProviderAvailability != providerExited && w.State != "stopping" && w.State != "stopped" && w.State != "failed"}
	if feed.Live {
		feed.InterruptRequested = w.Control.InterruptRequested
		if feed.InterruptRequested && w.Control.Interrupt != nil {
			feed.InterruptID = w.Control.Interrupt.ID
		}
		feed.Generation = w.Control.Generation
		if w.State == "idle" || w.State == "completed" {
			if m := w.Control.next(); m != nil {
				feed.NextMessageID = m.ID
			}
		}
	}
	sessionPermissions := turn == ACPSessionPermissionScope && w.PeerCapabilities != nil &&
		w.PeerCapabilities.ProtocolVersion == 2
	if turn != "" && (turn == activeProviderTurn(w) || sessionPermissions) {
		for _, q := range r.Requests {
			permission := s.state.Permissions[q.ID]
			if q.WorkerID == w.ID && permission.Turn == turn &&
				q.Status == "answered" && q.Delivery != "unknown" {
				feed.Answers = append(feed.Answers, workerControlAnswer{q.ID, permission.Request, q.Answer})
			}
		}
	}
	return feed, nil
}

func (s *service) workerControlReady(req *http.Request, actor string) (outcome, error) {
	r, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	if r.Status != "running" || (w.Role != "worker" && (w.ID != r.CoordinatorID || w.Control == nil)) {
		return outcome{}, conflict("worker control cannot be registered")
	}
	var input struct {
		Idle                bool
		PromptCapabilities  *PromptCapabilities
		SessionCapabilities *SessionCapabilities `json:"session_capabilities"`
		ProviderSession     *NativeSession       `json:"provider_session"`
	}
	if err := decode(req, &input); err != nil {
		return outcome{}, err
	}
	if input.ProviderSession != nil &&
		(!w.isLocalClaudeWorker() || *w.NativeSession != *input.ProviderSession || input.Idle) {
		return outcome{}, conflict("control registration does not match the original Claude session")
	}
	if w.Control != nil {
		updated := false
		if caps := input.PromptCapabilities; caps != nil &&
			(w.Control.PromptCapabilities == nil || *caps != *w.Control.PromptCapabilities) {
			w.Control.PromptCapabilities = caps
			updated = true
		}
		if caps := input.SessionCapabilities; caps != nil &&
			(w.Control.SessionCapabilities == nil || *caps != *w.Control.SessionCapabilities) {
			w.Control.SessionCapabilities = caps
			if !caps.CanInterrupt && !w.Control.InterruptClaimed {
				w.Control.closeInterrupt()
				w.Control.InterruptRequested = false
			}
			updated = true
		}
		if w.State == "unknown" && input.Idle && !w.providerBlocksControl() {
			w.State, w.Error = "idle", ""
			updated = true
		}
		if updated {
			return changed(w.Control), nil
		}
		return read(w.Control), nil
	}
	if w.State != "working" || input.Idle {
		return outcome{}, conflict("worker must be working to register control")
	}
	w.Control = &WorkerControl{Generation: 1, PromptCapabilities: input.PromptCapabilities, SessionCapabilities: input.SessionCapabilities}
	if w.NativeSession != nil {
		w.Control.ActiveTurnID = "initial-" + w.ID
	}
	if input.ProviderSession != nil {
		w.ProviderAvailability = providerAvailable
	}
	return changed(w.Control), nil
}

func (s *service) claimWorkerMessage(req *http.Request, actor string) (outcome, error) {
	r, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	if w.Control != nil && turnActive(w.State) {
		if active := w.Control.message(req.PathValue("message")); active != nil && active.Status == "processing" {
			return read(ClaimedWorkerFollowUp{*active, s.state.PromptParts[active.ID]}), nil
		}
	}
	if !canFollowUp(r, w) || (w.State != "idle" && w.State != "completed") {
		return outcome{}, conflict("worker cannot start a new turn")
	}
	m := w.Control.next()
	if m == nil || m.ID != req.PathValue("message") {
		return outcome{}, conflict("follow-up is no longer eligible for delivery")
	}
	m.Status = "processing"
	if w.NativeSession != nil {
		w.Control.ActiveTurnID = m.ID
	}
	w.State, w.Error, w.Result = "working", "", ""
	return changed(ClaimedWorkerFollowUp{*m, s.state.PromptParts[m.ID]}), nil
}

func (s *service) finishWorkerTurn(req *http.Request, actor string) (outcome, error) {
	r, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	var in struct {
		State           string
		Error           string
		MessageID       string `json:"message_id"`
		ObservedTurnEnd bool   `json:"observed_turn_end"`
		DeliveryUnknown bool   `json:"delivery_unknown"`
		StopReason      string `json:"stop_reason,omitempty"`
	}
	if err := decode(req, &in); err != nil {
		return outcome{}, err
	}
	if in.State == "disconnected" {
		return s.disconnectSSHWorker(r, w, in.MessageID)
	}
	if in.State != "completed" && in.State != "failed" && in.State != "idle" {
		return outcome{}, bad("invalid turn outcome")
	}
	if w.Control == nil {
		return outcome{}, conflict("there is no active managed turn")
	}
	var message *WorkerFollowUp
	finalStatus := in.State
	if in.State == "idle" {
		finalStatus = "interrupted"
	}
	if in.DeliveryUnknown {
		if in.State != "failed" || in.ObservedTurnEnd || in.StopReason != "" {
			return outcome{}, bad("unknown provider delivery requires an unconfirmed failed turn")
		}
		finalStatus = "delivery_unknown"
	}
	switch in.StopReason {
	case "":
	case "end_turn":
		if in.State != "completed" {
			return outcome{}, bad("end_turn requires a completed turn")
		}
	case "cancelled":
		if in.State != "idle" {
			return outcome{}, bad("cancelled requires an idle worker")
		}
	case "max_tokens", "max_turn_requests", "refusal":
		if in.State != "idle" {
			return outcome{}, bad("a provider-stopped turn leaves the worker idle")
		}
		finalStatus = "completed"
	default:
		return outcome{}, bad("invalid provider stop reason")
	}
	if in.MessageID != "" {
		message = w.Control.message(in.MessageID)
		if message != nil && message.Status == finalStatus {
			if message.StopReason != in.StopReason {
				return outcome{}, conflict("follow-up already has a different stop reason")
			}
			return read(w), nil
		}
		if message == nil || (message.Status != "processing" && message.Status != "delivery_unknown") {
			return outcome{}, conflict("follow-up is not active")
		}
	} else if w.State == in.State {
		return read(w), nil
	}
	if !turnActive(w.State) && w.State != "unknown" {
		return outcome{}, conflict("there is no active managed turn")
	}
	if w.Control.ActiveTurnID != "" {
		turnID := in.MessageID
		if turnID == "" {
			turnID = "initial-" + w.ID
		}
		if w.Control.ActiveTurnID != turnID {
			return outcome{}, conflict("turn outcome does not match the original provider turn")
		}
		if receipt := w.Control.Interrupt; receipt != nil && receipt.TurnID == turnID && receipt.Outcome == "" {
			if in.ObservedTurnEnd {
				receipt.Outcome = finalStatus
			} else {
				w.Control.closeInterrupt()
			}
		}
		w.Control.ActiveTurnID = ""
	}
	if w.ProviderAvailability == providerChecking {
		w.ProviderAvailability = providerAvailable
	}
	if message != nil {
		message.Status = finalStatus
		message.StopReason = in.StopReason
	}
	w.Control.LastStopReason = in.StopReason
	w.Control.InterruptRequested = false
	w.Control.InterruptClaimed = false
	w.State, w.Error = in.State, in.Error
	s.finishTurnPermissions(r, w, in.State == "failed")
	if message != nil {
		s.markOperationEnd(r, w, message)
	}
	if in.State == "failed" {
		s.stopWorkerInbox(r, w)
	}
	r.refreshOutcome()
	return changed(w), nil
}

func (s *service) disconnectSSHWorker(r *Run, w *Worker, messageID string) (outcome, error) {
	if w.Host == "" || w.Host == "localhost" || w.NativeSession == nil || w.Control == nil {
		return outcome{}, conflict("worker has no managed SSH session")
	}
	if w.State == "disconnected" {
		return read(w), nil
	}
	if !turnActive(w.State) && w.State != "unknown" {
		return outcome{}, conflict("there is no active SSH turn")
	}
	var message *WorkerFollowUp
	if messageID != "" {
		message = w.Control.message(messageID)
		if message == nil || (message.Status != "processing" && message.Status != "delivery_unknown") {
			return outcome{}, conflict("follow-up is not active")
		}
		message.Status = "delivery_unknown"
	}
	w.Control.InterruptRequested, w.Control.InterruptClaimed = false, false
	w.State = "disconnected"
	w.Error = "SSH disconnected. Commander could not confirm delivery to the original session."
	for _, q := range r.Requests {
		if q.WorkerID == w.ID && q.Delivery == "unconfirmed" {
			q.Delivery = "unknown"
		}
	}
	if message != nil {
		s.markOperationEnd(r, w, message)
	}
	return changed(w), nil
}

func (s *service) interruptWorker(req *http.Request, actor string) (outcome, error) {
	r, w, err := s.controlTarget(req, actor)
	if err != nil {
		return outcome{}, err
	}
	c := w.Control
	if c == nil {
		return outcome{}, conflict("there is no active managed turn to interrupt")
	}
	if actor != "" && c.Held {
		return outcome{}, conflict("developer holds worker input")
	}
	var target interruptTarget
	if body, _ := req.Context().Value(bodyKey{}).([]byte); len(body) != 0 {
		if err := decode(req, &target); err != nil {
			return outcome{}, err
		}
	}
	if target.TurnID != "" && c.Interrupt != nil && c.Interrupt.TurnID == target.TurnID &&
		c.Interrupt.Generation == target.Generation {
		return read(c), nil
	}
	if !canFollowUp(r, w) || !turnActive(w.State) {
		return outcome{}, conflict("there is no active managed turn to interrupt")
	}
	if target.TurnID != "" && (target.TurnID != c.ActiveTurnID || c.Generation != target.Generation) {
		return outcome{}, conflict("worker turn or input control changed before interrupt")
	}
	if caps := c.SessionCapabilities; caps != nil && !caps.CanInterrupt {
		return outcome{}, &apiError{http.StatusNotImplemented, "the worker does not support interrupting a turn"}
	}
	if c.InterruptRequested {
		return read(c), nil
	}
	c.InterruptRequested = true
	if c.ActiveTurnID != "" {
		c.Interrupt = &WorkerInterrupt{ID: randomID("i-"), TurnID: c.ActiveTurnID, Generation: c.Generation, Phase: "accepted"}
	}
	return outcome{c, 202, true, nil}, nil
}

func (s *service) claimWorkerInterrupt(req *http.Request, actor string) (outcome, error) {
	r, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	var input struct {
		interruptTarget
		PermissionTurn string `json:"permission_turn_id,omitempty"`
	}
	if err := decode(req, &input); err != nil {
		return outcome{}, err
	}
	c := w.Control
	if c == nil || w.providerBlocksControl() || !c.InterruptRequested || (!turnActive(w.State) && w.State != "unknown") {
		return outcome{}, conflict("there is no active interrupt")
	}
	if c.Interrupt != nil && !c.Interrupt.matches(input.interruptTarget) {
		return outcome{}, conflict("interrupt claim does not match the original request")
	}
	if c.InterruptClaimed {
		return read(c), nil
	}
	if c.Generation != input.Generation {
		return outcome{}, conflict("worker control changed before interrupt")
	}
	if input.PermissionTurn != "" {
		if input.PermissionTurn != activeProviderTurn(w) {
			return outcome{}, conflict("interrupt does not match the active provider permission turn")
		}
		for _, q := range r.Requests {
			if q.WorkerID == w.ID && q.Status == "pending" && s.state.Permissions[q.ID].Turn == input.PermissionTurn {
				q.Status = "cancelled"
			}
		}
	}
	c.InterruptClaimed = true
	if c.Interrupt != nil {
		c.Interrupt.Phase = "claimed"
	}
	return changed(c), nil
}

func (s *service) stopWorkerInbox(run *Run, w *Worker) {
	s.retireProviderPermissions(run, w.ID)
	s.retireElicitations(w.ID)
	if w.Control == nil {
		return
	}
	for i := range w.Control.Messages {
		m := &w.Control.Messages[i]
		switch m.Status {
		case "queued":
			m.Status = "cancelled"
		case "processing":
			m.Status = "delivery_unknown"
		default:
			continue
		}
		s.markOperationEnd(run, w, m)
	}
	w.Control.closeInterrupt()
	w.Control.InterruptRequested = false
	w.Control.InterruptClaimed = false
	w.Control.Held = false
}

func (s *service) stopWorker(req *http.Request, actor string) (outcome, error) {
	r, w, err := s.controlTarget(req, actor)
	if err != nil {
		return outcome{}, err
	}
	if actor != "" && w.Control != nil && w.Control.Held {
		return outcome{}, conflict("developer holds worker input")
	}
	if w.State == "stopped" || r.Status == "stopping" || r.Status == "stopped" {
		return read(w), nil
	}
	w.State, w.Error = "stopping", ""
	s.stopWorkerInbox(r, w)
	r.cancelQuestions(w.ID)
	id := w.ID
	return outcome{w, 202, true, func() { s.stopOne(id) }}, nil
}

func (s *service) stopOne(id string) {
	if s.launcher == nil {
		return
	}
	s.process.Lock()
	defer s.process.Unlock()
	s.mu.Lock()
	r, w := s.worker(id)
	active := w != nil && w.State == "stopping" && r.Status != "stopping" && r.Status != "stopped"
	s.mu.Unlock()
	if !active {
		return
	}
	err := s.launcher.Stop(context.Background(), id)
	s.mu.Lock()
	defer s.mu.Unlock()
	r, w = s.worker(id)
	if w == nil || w.State != "stopping" {
		return
	}
	if err != nil {
		w.Error = err.Error()
	} else {
		w.State, w.Error = "stopped", ""
		r.refreshOutcome()
	}
	s.saveBackground()
}

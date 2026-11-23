package service

import (
	"context"
	"net/http"
	"strings"
)

// WorkerControl is the durable lease and addressed inbox for a managed Claude
// worker. Only the local developer may change the lease. Each queued follow-up
// is bound to the generation under which it was accepted.
type WorkerControl struct {
	Generation         int              `json:"generation"`
	Held               bool             `json:"held"`
	InterruptRequested bool             `json:"interrupt_requested,omitempty"`
	InterruptClaimed   bool             `json:"interrupt_claimed,omitempty"`
	Messages           []WorkerFollowUp `json:"messages,omitempty"`
}

type WorkerFollowUp struct {
	ID         string `json:"id"`
	Status     string `json:"status"`
	Text       string `json:"text"`
	Generation int    `json:"generation"`
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

func turnActive(state string) bool {
	return state == "working" || state == "waiting"
}

func canFollowUp(r *Run, w *Worker) bool {
	return r.Status == "running" && w.Control != nil &&
		(turnActive(w.State) || w.State == "idle" || w.State == "completed")
}

func (s *service) controlTarget(req *http.Request, actor string) (*Run, *Worker, error) {
	r, w := s.worker(req.PathValue("worker"))
	if w == nil {
		return nil, nil, missing("worker")
	}
	if w.Role != "worker" || (actor != "" && actor != w.ParentID && actor != r.CoordinatorID) {
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
		c.InterruptRequested = false
	}
	for i := range c.Messages {
		if c.Messages[i].Status == "queued" {
			c.Messages[i].Status = "cancelled"
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
	if strings.TrimSpace(input.Text) == "" || len(input.Text) > 16<<10 {
		return outcome{}, bad("follow-up must contain between 1 and 16384 bytes")
	}
	key, intent, target, err := s.receipt(req, actor, input)
	if err != nil {
		return outcome{}, err
	}
	c := w.Control
	if target != "" && c != nil {
		if existing := c.message(target); existing != nil {
			return read(existing), nil
		}
	}
	if !canFollowUp(r, w) {
		return outcome{}, conflict("this worker cannot accept follow-ups right now")
	}
	if (actor == "" && (!c.Held || c.Generation != input.Generation)) || (actor != "" && c.Held) {
		return outcome{}, conflict("worker input is held by another controller")
	}
	if c.next() != nil {
		return outcome{}, conflict("this worker already has a queued follow-up")
	}
	m := WorkerFollowUp{ID: randomID("m-"), Status: "queued", Text: input.Text, Generation: c.Generation}
	c.Messages = append(c.Messages, m)
	s.remember(key, intent, m.ID)
	return outcome{m, 202, true, nil}, nil
}

type workerControlFeed struct {
	Live               bool   `json:"live"`
	NextMessageID      string `json:"next_message_id,omitempty"`
	InterruptRequested bool   `json:"interrupt_requested,omitempty"`
	Generation         int    `json:"generation,omitempty"`
	State              string `json:"state,omitempty"`
}

func (s *service) workerControlStatus(req *http.Request, actor string) (outcome, error) {
	r, w := s.worker(req.PathValue("worker"))
	if w == nil {
		return outcome{}, missing("worker")
	}
	if actor != w.ID || w.Role != "worker" {
		return outcome{}, denied()
	}
	feed := workerControlFeed{State: w.State, Live: r.Status == "running" && w.Control != nil && w.State != "stopping" && w.State != "stopped" && w.State != "failed"}
	if feed.Live {
		feed.InterruptRequested = w.Control.InterruptRequested
		feed.Generation = w.Control.Generation
		if w.State == "idle" || w.State == "completed" {
			if m := w.Control.next(); m != nil {
				feed.NextMessageID = m.ID
			}
		}
	}
	return read(feed), nil
}

func (s *service) workerControlReady(req *http.Request, actor string) (outcome, error) {
	r, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	if r.Status != "running" || w.Role != "worker" {
		return outcome{}, conflict("worker control cannot be registered")
	}
	var input struct{ Idle bool }
	if err := decode(req, &input); err != nil {
		return outcome{}, err
	}
	if w.Control != nil {
		if w.State == "unknown" && input.Idle {
			w.State, w.Error = "idle", ""
			return changed(w.Control), nil
		}
		return read(w.Control), nil
	}
	if w.State != "working" || input.Idle {
		return outcome{}, conflict("worker must be working to register control")
	}
	w.Control = &WorkerControl{Generation: 1}
	return changed(w.Control), nil
}

func (s *service) claimWorkerMessage(req *http.Request, actor string) (outcome, error) {
	r, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	if w.Control != nil && turnActive(w.State) {
		if active := w.Control.message(req.PathValue("message")); active != nil && active.Status == "processing" {
			return read(active), nil
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
	w.State, w.Error, w.Result = "working", "", ""
	return changed(m), nil
}

func (s *service) finishWorkerTurn(req *http.Request, actor string) (outcome, error) {
	r, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	var in struct {
		State     string
		Error     string
		MessageID string `json:"message_id"`
	}
	if err := decode(req, &in); err != nil {
		return outcome{}, err
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
	if in.MessageID != "" {
		message = w.Control.message(in.MessageID)
		if message != nil && message.Status == finalStatus {
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
	if message != nil {
		message.Status = finalStatus
	}
	w.Control.InterruptRequested = false
	w.Control.InterruptClaimed = false
	w.State, w.Error = in.State, in.Error
	r.cancelQuestions(w.ID)
	if in.State == "failed" {
		stopWorkerInbox(w)
	}
	r.refreshOutcome()
	return changed(w), nil
}

func (s *service) interruptWorker(req *http.Request, actor string) (outcome, error) {
	r, w, err := s.controlTarget(req, actor)
	if err != nil {
		return outcome{}, err
	}
	if !canFollowUp(r, w) || !turnActive(w.State) {
		return outcome{}, conflict("there is no active managed turn to interrupt")
	}
	if actor != "" && w.Control.Held {
		return outcome{}, conflict("developer holds worker input")
	}
	if w.Control.InterruptRequested {
		return read(w.Control), nil
	}
	w.Control.InterruptRequested = true
	return outcome{w.Control, 202, true, nil}, nil
}

func (s *service) claimWorkerInterrupt(req *http.Request, actor string) (outcome, error) {
	_, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	var input struct{ Generation int }
	if err := decode(req, &input); err != nil {
		return outcome{}, err
	}
	c := w.Control
	if c == nil || !c.InterruptRequested || (!turnActive(w.State) && w.State != "unknown") {
		return outcome{}, conflict("there is no active interrupt")
	}
	if c.InterruptClaimed {
		return read(c), nil
	}
	if c.Generation != input.Generation {
		return outcome{}, conflict("worker control changed before interrupt")
	}
	c.InterruptClaimed = true
	return changed(c), nil
}

func stopWorkerInbox(w *Worker) {
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
		}
	}
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
	stopWorkerInbox(w)
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

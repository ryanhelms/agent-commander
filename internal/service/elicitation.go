package service

import (
	"encoding/json"
	"io"
	"net/http"
	"slices"
	"strings"
	"time"

	"agent-acp.local/sdks/go/runtime"
	"agentcommander/internal/hosted"
	"github.com/google/jsonschema-go/jsonschema"
)

const (
	elicitationPayloadLimit = 32 << 10
	elicitationWait         = 5 * time.Minute
	elicitationRetention    = 15 * time.Minute
)

// Elicitation is visible only through the local owner API. User form values are
// returned directly to the waiting worker and never stored in the run database.
type Elicitation struct {
	ID       string        `json:"id"`
	Worker   string        `json:"worker_id"`
	Session  NativeSession `json:"session"`
	Status   string        `json:"status"`
	URLHost  string        `json:"url_host,omitempty"`
	Punycode bool          `json:"punycode,omitempty"`
	runtime.ElicitationRequest
}

type activeElicitation struct {
	view     Elicitation
	schema   *jsonschema.Resolved
	done     chan struct{}
	response runtime.ElicitationResponse
	expires  time.Time
}

func elicitationSchema(raw json.RawMessage) (*jsonschema.Resolved, error) {
	var fields map[string]any
	if json.Unmarshal(raw, &fields) != nil || fields["type"] != "object" || !boundedToolJSON(fields, 0, true) {
		return nil, bad("elicitation form requires a flat, self-contained object schema")
	}
	props, valid := fields["properties"].(map[string]any)
	if !valid || len(props) > 32 {
		return nil, bad("elicitation form has unsupported properties")
	}
	if required, ok := fields["required"].([]any); ok {
		for _, property := range required {
			name, ok := property.(string)
			if !ok || props[name] == nil {
				return nil, bad("elicitation form names an undefined required field")
			}
		}
	}
	for _, value := range props {
		property, ok := value.(map[string]any)
		if !ok {
			return nil, bad("elicitation form has an unsupported field")
		}
		switch property["type"] {
		case "string", "number", "integer", "boolean":
		case "array":
			items, ok := property["items"].(map[string]any)
			if !ok || !elicitationChoices(items) {
				return nil, bad("elicitation multi-select fields require explicit string choices")
			}
		default:
			return nil, bad("elicitation form has an unsupported field type")
		}
	}
	var schema jsonschema.Schema
	if json.Unmarshal(raw, &schema) != nil {
		return nil, bad("invalid elicitation form schema")
	}
	var forbidAdditional jsonschema.Schema
	if err := json.Unmarshal([]byte("false"), &forbidAdditional); err != nil {
		return nil, err
	}
	schema.AdditionalProperties = &forbidAdditional
	resolved, err := schema.Resolve(nil)
	if err != nil {
		return nil, bad("invalid elicitation form constraints")
	}
	return resolved, nil
}

func elicitationChoices(items map[string]any) bool {
	if enum, ok := items["enum"].([]any); ok && items["type"] == "string" && len(enum) != 0 {
		for _, value := range enum {
			if _, stringChoice := value.(string); !stringChoice {
				return false
			}
		}
		return true
	}
	choices, ok := items["anyOf"].([]any)
	if !ok || len(choices) == 0 || items["type"] != nil && items["type"] != "string" {
		return false
	}
	for _, value := range choices {
		choice, ok := value.(map[string]any)
		if !ok || len(choice) != 2 {
			return false
		}
		if _, ok := choice["const"].(string); !ok {
			return false
		}
		if _, ok := choice["title"].(string); !ok {
			return false
		}
	}
	return true
}

func (s *service) awaitElicitation(w http.ResponseWriter, req *http.Request) {
	if hosted.From(req.Context()) != nil {
		respondError(w, denied())
		return
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, req.Body, elicitationPayloadLimit))
	if err != nil {
		respondError(w, bad("elicitation request exceeds its size limit"))
		return
	}
	var input runtime.ElicitationRequest
	if json.Unmarshal(raw, &input) != nil || strings.TrimSpace(input.Message) == "" || len(input.Message) > 4096 {
		respondError(w, bad("invalid elicitation request"))
		return
	}
	item := &activeElicitation{
		view: Elicitation{ID: randomID("e-"), Status: "pending", ElicitationRequest: input},
		done: make(chan struct{}),
	}
	switch input.Mode {
	case "form":
		item.schema, err = elicitationSchema(input.RequestedSchema)
	case "url":
		host, valid := runtime.ElicitationURLHost(input.URL)
		if !valid || input.ElicitationID == "" || len(input.ElicitationID) > 256 {
			err = bad("elicitation URL must be HTTPS, without embedded credentials")
		}
		item.view.URLHost = host
		item.view.Punycode = strings.Contains(strings.ToLower(host), "xn--")
	default:
		err = bad("invalid elicitation mode")
	}
	if err != nil {
		respondError(w, err)
		return
	}

	s.mu.Lock()
	actor, err := s.requestActor(req)
	if err == nil {
		err = s.bindElicitation(req, actor, item)
	}
	s.mu.Unlock()
	if err != nil {
		respondError(w, err)
		return
	}
	timer := time.NewTimer(elicitationWait)
	defer timer.Stop()
	select {
	case <-item.done:
	case <-req.Context().Done():
	case <-timer.C:
	}
	s.mu.Lock()
	response := item.response
	if response.Action == "" || req.Context().Err() != nil {
		response = runtime.ElicitationResponse{Action: "cancel"}
	}
	if input.Mode != "url" || response.Action != "accept" {
		delete(s.elicitations, item.view.ID)
	}
	s.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(response)
}

func (s *service) bindElicitation(req *http.Request, actor string, item *activeElicitation) error {
	run, worker, err := s.own(req, actor)
	if err != nil {
		return err
	}
	if worker.NativeSession == nil || item.view.SessionID != worker.NativeSession.SessionID ||
		run.Status != "running" || worker.providerBlocksControl() || worker.State == "stopping" ||
		worker.State == "stopped" || worker.State == "failed" || worker.State == "disconnected" {
		return conflict("elicitation does not match an available provider session")
	}
	s.expireElicitations()
	if len(s.elicitations) >= 128 {
		return conflict("too many outstanding ACP elicitations")
	}
	count := 0
	for _, previous := range s.elicitations {
		if previous.view.Worker == worker.ID {
			count++
			if item.view.ElicitationID != "" && previous.view.ElicitationID == item.view.ElicitationID {
				return conflict("provider elicitation is already active")
			}
		}
	}
	if count >= 16 {
		return conflict("too many outstanding elicitations for this worker")
	}
	if s.elicitations == nil {
		s.elicitations = make(map[string]*activeElicitation)
	}
	item.view.Worker = worker.ID
	item.view.Session = *worker.NativeSession
	s.elicitations[item.view.ID] = item
	return nil
}

func (s *service) retireElicitations(worker string) {
	for id, item := range s.elicitations {
		if item.view.Worker != worker {
			continue
		}
		if item.view.Status == "pending" {
			item.response.Action = "cancel"
			item.view.Status = "cancel"
			close(item.done)
		}
		delete(s.elicitations, id)
	}
}

func (s *service) expireElicitations() {
	now := time.Now()
	for id, item := range s.elicitations {
		if !item.expires.IsZero() && now.After(item.expires) {
			delete(s.elicitations, id)
		}
	}
}

func (s *service) listElicitations(req *http.Request, actor string) (outcome, error) {
	if actor != "" || hosted.From(req.Context()) != nil {
		return outcome{}, denied()
	}
	_, worker := s.worker(req.PathValue("worker"))
	if worker == nil {
		return outcome{}, missing("worker")
	}
	s.expireElicitations()
	items := make([]Elicitation, 0)
	for _, item := range s.elicitations {
		if item.view.Worker == worker.ID {
			items = append(items, item.view)
		}
	}
	slices.SortFunc(items, func(a, b Elicitation) int { return strings.Compare(a.ID, b.ID) })
	return read(map[string]any{"elicitations": items}), nil
}

func (s *service) answerElicitation(req *http.Request, actor string) (outcome, error) {
	if actor != "" || hosted.From(req.Context()) != nil {
		return outcome{}, denied()
	}
	var answer runtime.ElicitationResponse
	if err := decode(req, &answer); err != nil {
		return outcome{}, err
	}
	item := s.elicitations[req.PathValue("elicitation")]
	if item == nil || item.view.Worker != req.PathValue("worker") {
		return outcome{}, missing("elicitation")
	}
	if item.view.Status != "pending" {
		return outcome{}, conflict("elicitation already resolved")
	}
	run, worker := s.worker(item.view.Worker)
	if worker == nil || worker.NativeSession == nil || *worker.NativeSession != item.view.Session ||
		run.Status != "running" || worker.State == "stopping" || worker.State == "stopped" ||
		worker.State == "failed" || worker.State == "disconnected" || worker.providerBlocksControl() {
		return outcome{}, conflict("the requesting provider session is no longer available")
	}
	switch answer.Action {
	case "accept":
		if item.schema != nil {
			var content map[string]any
			if len(answer.Content) > elicitationPayloadLimit || json.Unmarshal(answer.Content, &content) != nil || content == nil ||
				item.schema.Validate(content) != nil {
				return outcome{}, bad("form response does not match the requested fields")
			}
		} else if len(answer.Content) != 0 && string(answer.Content) != "null" {
			return outcome{}, bad("URL consent does not accept form content")
		}
	case "decline", "cancel":
		answer.Content = nil
	default:
		return outcome{}, bad("elicitation action must be accept, decline or cancel")
	}
	item.response, item.view.Status = answer, answer.Action
	if item.view.Mode == "url" && answer.Action == "accept" {
		item.expires = time.Now().Add(elicitationRetention)
	}
	close(item.done)
	return read(item.view), nil
}

func (s *service) completeElicitation(req *http.Request, actor string) (outcome, error) {
	if hosted.From(req.Context()) != nil {
		return outcome{}, denied()
	}
	_, worker, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	var in struct {
		SessionID     string `json:"sessionId"`
		ElicitationID string `json:"elicitationId"`
	}
	if err := decode(req, &in); err != nil {
		return outcome{}, err
	}
	s.expireElicitations()
	for _, item := range s.elicitations {
		if item.view.Worker == worker.ID && worker.NativeSession != nil && *worker.NativeSession == item.view.Session &&
			item.view.SessionID == in.SessionID &&
			item.view.ElicitationID == in.ElicitationID && item.view.Status == "accept" {
			item.view.Status = "completed"
			break
		}
	}
	return read(map[string]bool{"ok": true}), nil
}

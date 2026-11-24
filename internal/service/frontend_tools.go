package service

import (
	"encoding/json"
	"net/http"
	"regexp"
	"strings"
	"time"

	"agentcommander/internal/hosted"
	"github.com/google/jsonschema-go/jsonschema"
	segmentjson "github.com/segmentio/encoding/json"
)

const frontendToolScope = "commander:frontend-tools"

var frontendToolName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_-]{0,63}$`)

type frontendTool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Parameters  json.RawMessage `json:"parameters"`
	schema      *jsonschema.Resolved
}

type frontendRound struct {
	operation string
	actor     string
	access    *hosted.Access
	tools     []frontendTool
	calls     []frontendCall
}

type frontendCall struct {
	ID         string          `json:"id"`
	Name       string          `json:"name"`
	Arguments  json.RawMessage `json:"arguments"`
	Result     *toolMessage    `json:"result,omitempty"`
	Cancelled  bool            `json:"cancelled,omitempty"`
	deadline   time.Time
	dispatched bool
}

// A second connection may reconcile an invocation that could have reached
// the app. It receives data, never another executable tool event.
type unconfirmedToolCall struct {
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

func (c frontendCall) message() aguiMessage {
	return aguiMessage{ID: "frontend-" + c.ID, Role: "assistant", ToolCalls: []aguiToolCall{{
		ID: c.ID, Type: "function", Function: aguiFunction{Name: c.Name, Arguments: string(c.Arguments)},
	}}}
}

func (c frontendCall) resultMessage() aguiMessage {
	return aguiMessage{ID: "result-" + c.ID, Role: "tool", Content: &c.Result.Content, ToolCallID: c.ID, Error: c.Result.Error}
}

// toolMessage is the AG-UI client tool result, addressed by toolCallId.
type toolMessage struct {
	ID         string `json:"id"`
	Role       string `json:"role"`
	ToolCallID string `json:"toolCallId"`
	Content    string `json:"content"`
	Error      string `json:"error,omitempty"`
}

func compileFrontendTools(tools []frontendTool) error {
	if len(tools) > 8 {
		return bad("at most eight frontend tools may be registered for a turn")
	}
	names := make(map[string]bool, len(tools))
	for i := range tools {
		tool := &tools[i]
		if !frontendToolName.MatchString(tool.Name) || names[tool.Name] ||
			strings.TrimSpace(tool.Description) == "" || len(tool.Description) > 1024 || len(tool.Parameters) > 8192 {
			return bad("frontend tools need unique names, descriptions and bounded object schemas")
		}
		names[tool.Name] = true
		var raw map[string]any
		if err := json.Unmarshal(tool.Parameters, &raw); err != nil || !boundedToolJSON(raw, 0, true) {
			return bad("frontend tool parameters require bounded inline JSON Schema")
		}
		var schema jsonschema.Schema
		if err := json.Unmarshal(tool.Parameters, &schema); err != nil || schema.Type != "object" {
			return bad("frontend tool parameters must use a JSON Schema object")
		}
		resolved, err := schema.Resolve(nil)
		if err != nil {
			return bad("frontend tool parameters require a valid self-contained JSON Schema")
		}
		tool.schema = resolved
	}
	return nil
}

func boundedToolJSON(value any, depth int, schema bool) bool {
	if depth > 24 {
		return false
	}
	switch value := value.(type) {
	case map[string]any:
		for key, child := range value {
			if (schema && (key == "$ref" || key == "$dynamicRef" || key == "$recursiveRef")) ||
				!boundedToolJSON(child, depth+1, schema) {
				return false
			}
		}
	case []any:
		for _, child := range value {
			if !boundedToolJSON(child, depth+1, schema) {
				return false
			}
		}
	}
	return true
}

// The MCP process announces the bridge through its existing worker credential.
func (s *service) frontendToolReady(req *http.Request, actor string) (outcome, error) {
	_, worker, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	if worker.Role != "worker" {
		return outcome{}, conflict("frontend tools require a managed worker")
	}
	capability := map[string]bool{"frontendTools": true}
	if worker.FrontendTools {
		return read(capability), nil
	}
	worker.FrontendTools = true
	return changed(capability), nil
}

func (s *service) addFrontendRound(worker, operation, actor string, access *hosted.Access, tools []frontendTool) {
	var rounds []*frontendRound
	_, w := s.worker(worker)
	for _, round := range s.frontendRounds[worker] {
		message := w.Control.message(round.operation)
		if message != nil && (message.Status == "queued" || message.Status == "processing") {
			rounds = append(rounds, round)
		}
	}
	s.frontendRounds[worker] = append(rounds, &frontendRound{operation: operation, actor: actor, access: access, tools: tools})
}

func (s *service) processingFrontendRound(worker *Worker) *frontendRound {
	if worker.Control == nil || !worker.Control.Held || worker.Control.InterruptRequested || !turnActive(worker.State) {
		return nil
	}
	for _, round := range s.frontendRounds[worker.ID] {
		if message := worker.Control.message(round.operation); message != nil &&
			message.Status == "processing" && message.Generation == worker.Control.Generation {
			return round
		}
	}
	return nil
}

func (s *service) activeFrontendRound(worker *Worker) *frontendRound {
	round := s.processingFrontendRound(worker)
	if round != nil && (round.access == nil || round.access.Allowed()) {
		return round
	}
	return nil
}

func (round *frontendRound) renew(access *hosted.Access) {
	if round.access != nil {
		if renewed := round.access.Renew(access); renewed != nil {
			round.access = renewed
		}
	}
}

func (s *service) listFrontendTools(req *http.Request, actor string) (outcome, error) {
	_, worker, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	if round := s.activeFrontendRound(worker); round != nil {
		return read(round.tools), nil
	}
	return read([]frontendTool{}), nil
}

func (s *service) startFrontendCall(req *http.Request, actor string) (outcome, error) {
	_, worker, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	round := s.activeFrontendRound(worker)
	if round == nil {
		return outcome{}, conflict("no authorized frontend tool turn is active")
	}
	var input struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := decode(req, &input); err != nil {
		return outcome{}, err
	}
	var tool *frontendTool
	for i := range round.tools {
		if round.tools[i].Name == input.Name {
			tool = &round.tools[i]
			break
		}
	}
	if tool == nil {
		return outcome{}, missing("frontend tool")
	}
	if len(input.Arguments) > 16<<10 {
		return outcome{}, bad("frontend tool arguments exceed the size limit")
	}
	var arguments map[string]any
	// Use native integers for schema validation. The validator treats
	// json.Number as a string for JSON type checks.
	_, err = segmentjson.Parse(input.Arguments, &arguments, segmentjson.UseInt64|segmentjson.UseUint64)
	if err != nil || arguments == nil || !boundedToolJSON(arguments, 0, false) || tool.schema.Validate(arguments) != nil {
		return outcome{}, bad("arguments do not match the advertised frontend tool schema")
	}
	if len(round.calls) >= 8 {
		return outcome{}, conflict("frontend tool call limit reached for this turn")
	}
	call := frontendCall{ID: randomID("ft-"), Name: tool.Name, Arguments: input.Arguments, deadline: time.Now().Add(time.Minute)}
	round.calls = append(round.calls, call)
	s.notifyConsole()
	return read(call), nil
}

func (s *service) readFrontendCall(req *http.Request, actor string) (outcome, error) {
	_, worker, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	round := s.processingFrontendRound(worker)
	if round == nil || (round.access != nil && !round.access.GrantAllowed()) {
		return outcome{}, conflict("frontend tool turn ended or its grant was revoked")
	}
	for _, call := range round.calls {
		if call.ID == req.PathValue("call") {
			if call.Result == nil && !time.Now().Before(call.deadline) {
				return outcome{}, conflict("frontend tool call expired")
			}
			return read(call), nil
		}
	}
	return outcome{}, missing("frontend tool call")
}

// The worker may abandon a particular MCP request while its turn and other
// frontend calls continue. Record that evidence even if the app disconnected.
func (s *service) cancelFrontendCall(req *http.Request, actor string) (outcome, error) {
	_, worker, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	for _, round := range s.frontendRounds[worker.ID] {
		for i := range round.calls {
			call := &round.calls[i]
			if call.ID != req.PathValue("call") {
				continue
			}
			if call.Result != nil && !call.Cancelled {
				return read(map[string]string{"id": call.ID, "status": "already_resolved"}), nil
			}
			if !call.Cancelled {
				call.Cancelled = true
				call.Result = &toolMessage{ID: "cancel-" + call.ID, Role: "tool", ToolCallID: call.ID,
					Error: "The worker cancelled its wait. Any app-side effect is unconfirmed."}
				s.notifyConsole()
			}
			// A failed disk write cannot undo an observed cancellation. Keep
			// the call retired in memory and allow a retry to save its receipt.
			if err := s.saveFrontendResult(worker.ID, round, *call); err != nil {
				return outcome{}, &apiError{http.StatusInternalServerError, "frontend tool cancellation could not be saved"}
			}
			return read(map[string]string{"id": call.ID, "status": "cancelled"}), nil
		}
	}
	return outcome{}, missing("frontend tool call")
}

func (s *service) resolveFrontendCall(req *http.Request, actor string) (outcome, error) {
	if actor != "" {
		return outcome{}, denied()
	}
	_, worker := s.worker(req.PathValue("worker"))
	if worker == nil {
		return outcome{}, missing("worker")
	}
	operation, callID, principal := req.PathValue("operation"), req.PathValue("call"), receiptActor(req, "")
	for _, round := range s.frontendRounds[worker.ID] {
		if round.operation != operation || round.actor != principal {
			continue
		}
		for i := range round.calls {
			call := &round.calls[i]
			if call.ID != callID {
				continue
			}
			return s.acceptFrontendResult(req, worker, round, call)
		}
	}
	saved, err := s.savedFrontendResults(worker.ID, operation, principal)
	if err == nil {
		for _, call := range saved {
			if call.ID == callID {
				result, err := parseFrontendResult(req, callID)
				if err != nil {
					return outcome{}, err
				}
				return replayFrontendResult(call, result)
			}
		}
	}
	return outcome{}, missing("frontend tool call")
}

func (s *service) acceptFrontendResult(req *http.Request, worker *Worker, round *frontendRound, call *frontendCall) (outcome, error) {
	result, err := parseFrontendResult(req, call.ID)
	if err != nil {
		return outcome{}, err
	}
	if call.Result != nil {
		return replayFrontendResult(*call, result)
	}
	if round != s.processingFrontendRound(worker) || !time.Now().Before(call.deadline) {
		return outcome{}, conflict("frontend tool call is no longer active")
	}
	round.renew(hosted.From(req.Context()))
	if round.access != nil && !round.access.Allowed() {
		return outcome{}, conflict("frontend tool authorization is no longer active")
	}
	accepted := *call
	accepted.Result = &result
	if err := s.saveFrontendResult(worker.ID, round, accepted); err != nil {
		return outcome{}, &apiError{http.StatusInternalServerError, "frontend tool result could not be saved"}
	}
	*call = accepted
	s.notifyConsole()
	return read(accepted), nil
}

func parseFrontendResult(req *http.Request, callID string) (toolMessage, error) {
	var result toolMessage
	if err := decode(req, &result); err != nil {
		return toolMessage{}, err
	}
	if result.Role != "tool" || result.ToolCallID != callID || result.ID == "" ||
		len(result.ID) > 128 || len(result.Content) > 32<<10 || len(result.Error) > 1024 {
		return toolMessage{}, bad("expected an AG-UI tool message for this call")
	}
	return result, nil
}

func replayFrontendResult(call frontendCall, result toolMessage) (outcome, error) {
	if call.Cancelled {
		return outcome{}, conflict("worker cancelled the frontend tool call")
	}
	if *call.Result == result {
		return read(call), nil
	}
	return outcome{}, conflict("frontend tool call already resolved")
}

func (s *service) dispatchFrontendCall(r *http.Request, worker, operation, id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if r.Context().Err() != nil {
		return false
	}
	if access := hosted.From(r.Context()); access != nil && !access.WithScope(frontendToolScope).Allowed() {
		return false
	}
	_, target := s.worker(worker)
	if target == nil {
		return false
	}
	round := s.activeFrontendRound(target)
	if round == nil || round.operation != operation || round.actor != receiptActor(r, "") {
		return false
	}
	for i := range round.calls {
		call := &round.calls[i]
		if call.ID == id && !call.dispatched && call.Result == nil && time.Now().Before(call.deadline) {
			call.dispatched = true
			s.notifyOperations(worker)
			return true
		}
	}
	return false
}

func (s *service) frontendCalls(r *http.Request, worker, operation string) ([]frontendCall, error) {
	access := hosted.From(r.Context())
	if access != nil && !access.WithScope(frontendToolScope).Allowed() {
		return nil, nil
	}
	actor := receiptActor(r, "")
	s.mu.Lock()
	for _, round := range s.frontendRounds[worker] {
		if round.operation != operation || round.actor != actor {
			continue
		}
		calls := make([]frontendCall, 0, len(round.calls))
		_, target := s.worker(worker)
		active := target != nil && round == s.processingFrontendRound(target) && (round.access == nil || round.access.Allowed())
		for _, call := range round.calls {
			if call.Result != nil || (active && time.Now().Before(call.deadline)) {
				calls = append(calls, call)
			}
		}
		s.mu.Unlock()
		return calls, nil
	}
	s.mu.Unlock()
	return s.savedFrontendResults(worker, operation, actor)
}

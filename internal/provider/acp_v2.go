package provider

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"

	"agentcommander/internal/acpprocessor"

	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"
	"agentcommander/internal/service"
)

func configureACPProtocol(config *runtime.Config) error {
	switch os.Getenv("AGENT_COMMANDER_ACP_PROTOCOL") {
	case "", "auto", "v1":
		config.ProtocolVersion = 1
	case "v2":
		config.ProtocolVersion = 2
	default:
		return errors.New("AGENT_COMMANDER_ACP_PROTOCOL must be auto, v1, or v2")
	}
	return nil
}

type acpV2Inputs struct {
	api  *api
	path string
}

func (p *acpV2Inputs) handles(event *model.Observation) bool {
	return event.GetInput() != nil || event.GetExtension().GetType() == runtime.ACPV2PermissionDismissedSource
}

func (p *acpV2Inputs) observe(ctx context.Context, source *acpSourcePublisher, screen *screen, event *model.Observation) error {
	activity := source.captureObservation(ctx, event)
	if dismissed := event.GetExtension(); dismissed.GetType() == runtime.ACPV2PermissionDismissedSource {
		var request struct{ RequestID string }
		if json.Unmarshal(dismissed.Data, &request) != nil || request.RequestID == "" {
			return errors.New("provider permission cancellation omitted its request identity")
		}
		return p.api.requestContext(ctx, "POST", p.path+"/questions/dismiss-provider", map[string]string{
			"provider_request": request.RequestID,
		}, nil)
	}

	request := event.GetInput()
	if request.GetRequestId() == "" || len(request.GetChoices()) == 0 {
		return errors.New("provider permission omitted its offered choices")
	}
	choices := make([]service.QuestionChoice, 0, len(request.Choices))
	for _, option := range request.Choices {
		choices = append(choices, service.QuestionChoice{ID: option.Id, Label: option.Label})
	}
	var question service.Question
	if err := p.api.requestContext(ctx, "POST", p.path+"/questions", map[string]any{
		"question": request.Prompt, "choices": choices, "provider_turn": service.ACPSessionPermissionScope,
		"provider_request": request.RequestId, "idempotency_key": request.RequestId,
		"provider_tool_call_id": acpPermissionToolCallID(event, true),
	}, &question); err != nil {
		return err
	}
	screen.line(question.ID + " · " + question.Question)
	if activity != nil {
		screen.recordEvent(service.ConsoleEvent{Kind: "output", Text: "[Provider event: Permission requested] " + question.Question, ACP: activity})
	}
	return nil
}

func acpV2Message(event *model.Observation, activity *acpprocessor.Activity) (service.ConsoleEvent, bool) {
	if activity == nil {
		return service.ConsoleEvent{}, false
	}
	var kind, id, value, operation string
	if extension := event.GetExtension(); extension.GetType() == runtime.ACPV2MessageStateSource {
		var snapshot struct {
			Kind, MessageID string
			Omitted         bool
			Content         []struct{ Type, Text string }
		}
		if json.Unmarshal(extension.Data, &snapshot) != nil {
			return service.ConsoleEvent{}, false
		}
		var text strings.Builder
		for _, block := range snapshot.Content {
			if block.Type == "text" {
				text.WriteString(block.Text)
			} else if block.Type != "" {
				text.WriteString("[ACP " + block.Type + "]")
			}
		}
		if snapshot.Omitted {
			text.WriteString("[Message exceeded the live preview limit]")
		}
		kind, id, value, operation = snapshot.Kind, snapshot.MessageID, text.String(), "replace"
	} else if ext := paramsSource(event); ext.GetType() == runtime.ACPUpdateParamsSource {
		inner, err := acpprocessor.ScopedUpdate(ext.Data, event.GetSession().GetSessionId())
		if err != nil {
			return service.ConsoleEvent{}, false
		}
		var chunk struct {
			SessionUpdate, MessageID string
			Content                  struct{ Type, Text string }
		}
		if json.Unmarshal(inner, &chunk) != nil {
			return service.ConsoleEvent{}, false
		}
		var isChunk bool
		kind, isChunk = strings.CutSuffix(chunk.SessionUpdate, "_chunk")
		if !isChunk || chunk.Content.Type == "" {
			return service.ConsoleEvent{}, false
		}
		id, value, operation = chunk.MessageID, chunk.Content.Text, "append"
		if chunk.Content.Type != "text" {
			value = "[ACP " + chunk.Content.Type + "]"
		}
	}
	var display string
	switch kind {
	case "agent_message":
		display = "text"
	case "user_message":
		display = "user"
	case "agent_thought":
		display = "thinking"
	case "session_message":
		display = "output"
	default:
		return service.ConsoleEvent{}, false
	}
	if id == "" {
		return service.ConsoleEvent{}, false
	}
	correlation := *activity
	correlation.Kind, correlation.MessageID, correlation.MessageOp, correlation.ContentType = kind, id, operation, "text"
	if !correlation.Valid() {
		return service.ConsoleEvent{}, false
	}
	return service.ConsoleEvent{Kind: display, Text: consoleText(value), ACP: &correlation}, true
}

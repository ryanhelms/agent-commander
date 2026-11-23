package provider

import (
	"context"
	"errors"
	"fmt"
	"os"
	"slices"
	"strings"
	"time"

	agentacp "agent-acp.local/sdks/go"
	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"
	"agentcommander/internal/localapi"
	"agentcommander/internal/service"
)

var errACPDisconnected = errors.New("live provider connection disconnected")

// The runner owns the session, scopes MCP to this job and passes only the
// native session identity to Commander. Output is a live projection.
func runACP(ctx context.Context, j job, a *api, s *screen) error {
	policyJob := j
	cwd := j.Worker.Path
	var args []string
	if j.SSH != nil {
		socket, closeForward, err := startWorkerForward(j.Socket, j.Worker.Token)
		if err != nil {
			return fmt.Errorf("start worker API forward: %w", err)
		}
		defer closeForward()
		args, policyJob.Socket = j.SSH.sessionArgs(j.Worker, socket)
		policyJob.Executable = j.SSH.Agentctl
		cwd = j.SSH.Checkout
	}
	config, err := planningConfig(policyJob)
	if err != nil {
		return err
	}
	if j.SSH != nil {
		config.HarnessInstance = j.SSH.harnessInstance()
		config.Args = args
	}
	if _, supplied := config.Env["PATH"]; j.NodePath != "" && !supplied {
		if config.Env == nil {
			config.Env = make(map[string]string)
		}
		config.Env["PATH"] = j.NodePath + string(os.PathListSeparator) + os.Getenv("PATH")
	}
	rt, err := runtime.New(config)
	if err != nil {
		return err
	}
	defer rt.Close()
	client := agentacp.New(rt)
	openCtx, cancelOpen := context.WithTimeout(ctx, 30*time.Second)
	opened, err := client.Open(openCtx, &model.OpenRequest{HarnessInstance: config.HarnessInstance, WorkingDirectory: cwd})
	cancelOpen()
	if err != nil {
		return fmt.Errorf("open %s session: %w", j.Harness, err)
	}
	ref := opened.GetSession().GetRef()
	if ref.GetSessionId() == "" || ref.GetHarnessInstance() != config.HarnessInstance {
		return errors.New("harness returned an invalid session identity")
	}
	path := "/v1/workers/" + j.Worker.ID
	owner := &api{localapi.New(j.Socket, "")}
	if err := owner.request("POST", path+"/native-session", service.NativeSession{HarnessInstance: ref.HarnessInstance, SessionID: ref.SessionId}, nil); err != nil {
		return fmt.Errorf("bind provider session: %w", err)
	}
	showAssignment(s, j)
	go terminalInput(j, a, s)

	managed := j.Worker.Role == "worker"
	if managed {
		if err := a.request("POST", path+"/control/ready", struct{}{}, nil); err != nil {
			return err
		}
	}
	var cursor string
	turnID, prompt, messageID := "initial-"+j.Worker.ID, j.Worker.Task, ""
	for {
		state, turnErr := runACPTurn(ctx, client, ref, a, s, path, turnID, prompt, managed, &cursor)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if !managed {
			return turnErr
		}
		if j.SSH != nil && errors.Is(turnErr, errACPDisconnected) {
			s.line("SSH disconnected. The original request and conversation are available for reconciliation.")
			s.flush()
			return publishTurnOutcome(ctx, a, path+"/control/finish", map[string]string{
				"state": "disconnected", "message_id": messageID,
			})
		}
		outcome := map[string]string{"state": state, "message_id": messageID}
		if turnErr != nil {
			outcome["error"] = turnErr.Error()
		}
		s.flush()
		if err := publishTurnOutcome(ctx, a, path+"/control/finish", outcome); err != nil {
			return err
		}
		if turnErr != nil {
			return turnErr
		}
		next, ok := waitForFollowUp(ctx, a, path)
		if !ok {
			return nil
		}
		turnID, prompt, messageID = next.ID, next.Text, next.ID
		s.line("You: " + prompt)
		s.event("user", "", "", prompt)
	}
}

func planningConfig(j job) (runtime.Config, error) {
	if j.Codex != nil {
		return j.Codex.config(j)
	}
	if j.Harness != "claude" {
		return runtime.Config{}, fmt.Errorf("unsupported managed planning profile %q", j.Harness)
	}
	servers, instructions, allowed := agentPolicy(j)
	builtins := []string{"Read", "Grep", "Glob"}
	allowedTools := strings.Split(allowed, ",")
	// --allowedTools controls automatic approval in Claude. Also remove each
	// coordinator-only MCP operation from a worker's visible tool surface.
	var disallowed []string
	for _, tool := range coordinatorTools {
		if !slices.Contains(allowedTools, tool) {
			disallowed = append(disallowed, tool)
		}
	}
	config := runtime.Config{
		OncePermissionsOnly: true,
		HarnessInstance:     "local-" + j.Harness, WorkingDirectory: j.Worker.Path, Command: j.Adapter,
		SessionMeta: map[string]any{
			"systemPrompt": map[string]string{"append": instructions},
			"claudeCode": map[string]any{"options": map[string]any{
				"tools": builtins, "allowedTools": allowedTools, "disallowedTools": disallowed,
				"strictMcpConfig": true, "settingSources": []string{},
				"allowDangerouslySkipPermissions": false, "mcpServersDelivery": "initialize",
			}},
		},
	}
	if j.NodePath != "" {
		config.Env = map[string]string{"PATH": j.NodePath + string(os.PathListSeparator) + os.Getenv("PATH")}
	}
	for name, srv := range servers {
		config.MCPServers = append(config.MCPServers, runtime.MCPServer{Name: name, Command: srv.Command, Args: srv.Args, Env: srv.Env})
	}
	return config, nil
}

type acpUpdate struct {
	event *model.Observation
	err   error
}

func runACPTurn(ctx context.Context, client *agentacp.Sessions, ref *model.SessionRef, a *api, s *screen, path, turnID, prompt string, managed bool, cursor *string) (string, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	sent, err := client.Send(ctx, &model.SendRequest{Session: ref, OperationId: turnID, Text: prompt})
	if err = accepted(sent.GetReceipt(), err); err != nil {
		return "failed", err
	}
	after := *cursor
	updates := make(chan acpUpdate, 64)
	go func() {
		defer close(updates)
		for event, err := range client.Observe(ctx, &model.ObserveRequest{Session: ref, AfterCursor: after}) {
			select {
			case updates <- acpUpdate{event, err}:
			case <-ctx.Done():
				return
			}
		}
	}()
	pending := map[string]*model.InputRequest{}
	interruptAttempted := false
	ticker := time.NewTicker(350 * time.Millisecond)
	defer ticker.Stop()
	var text strings.Builder
	flushText := func() {
		if text.Len() > 0 {
			s.event("text", "", "", text.String())
			text.Reset()
		}
	}
	defer flushText()
	for {
		select {
		case <-ctx.Done():
			return "idle", ctx.Err()
		case update, ok := <-updates:
			if update.err != nil {
				return "failed", update.err
			}
			if !ok {
				return "failed", errACPDisconnected
			}
			e := update.event
			*cursor = e.Cursor
			if e.GetGap() != nil {
				return "failed", errors.New("live provider observations expired during this turn")
			}
			if e.GetTurnId() != turnID {
				continue
			}
			switch {
			case e.GetText() != nil && e.GetText().Speaker == model.Speaker_SPEAKER_ASSISTANT:
				value := consoleText(e.GetText().Text)
				s.write(value)
				text.WriteString(value)
				if strings.HasSuffix(value, "\n") || text.Len() >= 8192 {
					flushText()
				}
			case e.GetTool() != nil:
				flushText()
				tool := e.GetTool()
				name := strings.TrimPrefix(tool.Name, "mcp__commander__")
				switch tool.Phase {
				case "completed", "failed":
					s.event("tool_result", tool.CallId, "", tool.Summary)
				default:
					if name != "" {
						s.line("→ " + name)
						s.event("tool_call", tool.CallId, name, tool.Summary)
					}
				}
			case e.GetInput() != nil:
				flushText()
				request := e.GetInput()
				if request.RequestId == "" || len(request.Choices) == 0 {
					return "failed", errors.New("provider requested an unsupported form of input")
				}
				choices := make([]service.QuestionChoice, 0, len(request.Choices))
				for _, option := range request.Choices {
					choices = append(choices, service.QuestionChoice{ID: option.Id, Label: option.Label})
				}
				var q service.Question
				if err := a.request("POST", path+"/questions", map[string]any{"question": request.Prompt, "choices": choices, "idempotency_key": request.RequestId}, &q); err != nil {
					return "failed", err
				}
				pending[q.ID] = request
				s.line(q.ID + " · " + q.Question)
			case e.GetTurnEnded() != nil:
				reason := e.GetTurnEnded().Reason
				switch reason {
				case "end_turn":
					s.line("")
					return "completed", nil
				case "cancelled":
					s.line("Turn interrupted.")
					return "idle", nil
				case "adapter disconnected":
					return "failed", errACPDisconnected
				default:
					return "failed", fmt.Errorf("provider stopped the turn: %s", reason)
				}
			}
		case <-ticker.C:
			if managed && !interruptAttempted {
				var feed controlFeed
				if a.request("GET", path+"/control", nil, &feed) == nil && feed.InterruptRequested {
					if a.request("POST", path+"/control/interrupt/claim", map[string]int{"generation": feed.Generation}, nil) == nil {
						interruptAttempted = true
						result, err := client.Interrupt(ctx, &model.InterruptRequest{Session: ref, OperationId: "interrupt-" + turnID, TurnId: turnID})
						if err = accepted(result.GetReceipt(), err); err != nil {
							// The original turn can finish between the API claim and delivery.
							// Its turn-ended observation remains authoritative.
							s.line("Interrupt could not be confirmed: " + err.Error())
						}
					}
				}
			}
			for id, request := range pending {
				var q service.Question
				if a.request("GET", path+"/questions/"+id, nil, &q) != nil || q.Status != "answered" {
					continue
				}
				if !slices.ContainsFunc(request.Choices, func(opt *model.Choice) bool { return opt.Id == q.Answer }) {
					return "failed", errors.New("reply does not match an offered provider choice")
				}
				answer, err := client.Answer(ctx, &model.AnswerRequest{Session: ref, OperationId: "answer-" + id, RequestId: request.RequestId, Answer: &model.AnswerRequest_OptionId{OptionId: q.Answer}})
				if answer.GetReceipt().GetStatus() == model.DeliveryStatus_DELIVERY_STATUS_UNKNOWN {
					return "failed", errACPDisconnected
				}
				if err = accepted(answer.GetReceipt(), err); err != nil {
					return "failed", err
				}
				delete(pending, id)
			}
		}
	}
}

func accepted(receipt *model.Receipt, err error) error {
	if err != nil {
		return err
	}
	switch receipt.GetStatus() {
	case model.DeliveryStatus_DELIVERY_STATUS_ACCEPTED, model.DeliveryStatus_DELIVERY_STATUS_DELIVERED:
		return nil
	default:
		return fmt.Errorf("provider delivery %s: %s", receipt.GetStatus(), receipt.GetDetail())
	}
}

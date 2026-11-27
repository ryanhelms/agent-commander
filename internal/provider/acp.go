package provider

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"slices"
	"strings"
	"time"

	agentacp "agent-acp.local/sdks/go"
	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"
	"agentcommander/harness"
	"agentcommander/internal/acpprocessor"
	"agentcommander/internal/localapi"
	"agentcommander/internal/service"
)

var errACPDisconnected = errors.New("live provider connection disconnected")

var errACPObservationGap = errors.New("live provider observations expired")

const managedClaudeModel = "opus"

// The runner owns the session, scopes MCP to this job and passes only the
// native session identity to Commander. Output is a live projection.
func runACP(ctx context.Context, j job, a *api, s *screen) error {
	policyJob := j
	cwd := j.Worker.Path
	var args []string
	var persistent *persistentProxy
	if j.SSH != nil {
		socket, closeForward, err := startWorkerForward(j.Socket, j.Worker.Token)
		if err != nil {
			return fmt.Errorf("start worker API forward: %w", err)
		}
		defer closeForward()
		if j.SSH.Persistent {
			persistent = &persistentProxy{Profile: *j.SSH, Worker: j.Worker.ID, LocalSocket: socket, OwnerSocket: j.Socket}
			if err := persistent.start(ctx); err != nil {
				return err
			}
			defer persistent.stop()
			policyJob.Socket = persistentAPI(j.Worker.ID)
		} else {
			args, policyJob.Socket = j.SSH.sessionArgs(j.Worker, socket)
		}
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
	if persistent != nil {
		data, err := json.Marshal(persistent)
		if err != nil {
			return err
		}
		config.Command, config.Args = j.Executable, []string{"persistent-acp", "proxy"}
		if config.Env == nil {
			config.Env = make(map[string]string)
		}
		config.Env[persistentACPConfig] = string(data)
		for i := range config.MCPServers {
			config.MCPServers[i].Env["AGENT_COMMANDER_PERSISTENT_SSH_WAIT"] = "1"
		}
	}
	setACPNodePath(&config, j.NodePath)
	j.ACPBroker.apply(&config, j.Executable)
	stderr := &lineWriter{s: s}
	config.Stderr = stderr
	if err := configureACPProtocol(&config); err != nil {
		return err
	}
	configureACPActivity(&config)
	if resume := j.Worker.Reattach; resume != nil {
		config.ModelOnResume = acpOpenRequest(j, config.HarnessInstance, cwd).GetModel()
		if resume.ProtocolVersion != 0 {
			config.ProtocolVersion = resume.ProtocolVersion
		}
	}
	configureACPToolTransport(ctx, j, &config, a)
	configureACPElicitation(j, &config, a, s)
	source := newACPSourcePublisher()
	source.portable = j.BuiltinInstance != ""
	config.OnACPUpdate = source.capture
	rt, err := openSessionRuntime(j, config)
	if err != nil {
		return err
	}
	var finishSource func()
	defer func() {
		_ = rt.Close()
		if finishSource != nil {
			finishSource()
		}
		stderr.flush()
	}()
	client := agentacp.New(rt)
	openCtx, cancelOpen := context.WithTimeout(ctx, 30*time.Second)
	var session *model.Session
	if resume := j.Worker.Reattach; resume != nil {
		opened, err := client.Resume(openCtx, &model.ResumeRequest{Session: &model.SessionRef{
			HarnessInstance: resume.Ref.HarnessInstance, SessionId: resume.Ref.SessionID,
		}})
		cancelOpen()
		if err != nil {
			return fmt.Errorf("reattach %s session: %w", j.Harness, err)
		}
		session = opened.GetSession()
	} else {
		opened, err := client.Open(openCtx, acpOpenRequest(j, config.HarnessInstance, cwd))
		cancelOpen()
		if err != nil {
			return fmt.Errorf("open %s session: %w", j.Harness, err)
		}
		session = opened.GetSession()
	}
	ref := session.GetRef()
	if ref.GetSessionId() == "" || ref.GetHarnessInstance() != config.HarnessInstance {
		return errors.New("harness returned an invalid session identity")
	}
	path := "/v1/workers/" + j.Worker.ID
	nativeSession := service.NativeSession{HarnessInstance: ref.HarnessInstance, SessionID: ref.SessionId}
	managed := j.Worker.Role == "worker"
	capabilities := session.GetCapabilities()
	protocolVersion := 1
	if negotiated, ok := rt.(interface {
		NegotiatedProtocolVersion(*model.SessionRef) (int, error)
	}); ok {
		var err error
		protocolVersion, err = negotiated.NegotiatedProtocolVersion(ref)
		if err != nil {
			return err
		}
	}
	promptCaps := service.PromptCapabilities{Image: capabilities.GetCanPromptImage(), Audio: capabilities.GetCanPromptAudio(), ResourceLink: j.BuiltinInstance == "", EmbeddedContext: capabilities.GetCanPromptEmbeddedContext()}
	sessionCaps := service.SessionCapabilities{
		ProtocolVersion: protocolVersion,
		CanAnswer:       capabilities.GetCanAnswer(), CanInterrupt: capabilities.GetCanInterrupt(),
		CanResume: capabilities.GetCanResume(), CanListSessions: capabilities.GetCanListSessions(), CanReadHistory: capabilities.GetCanReadHistory(),
	}
	if resume := j.Worker.Reattach; resume != nil {
		if nativeSession != resume.Ref || !managed || resume.ProtocolVersion != 0 && protocolVersion != resume.ProtocolVersion {
			return errors.New("harness did not reattach the original worker session")
		}
	} else {
		binding := struct {
			service.NativeSession
			ProviderBinding  string                      `json:"provider_binding,omitempty"`
			PeerCapabilities service.SessionCapabilities `json:"peer_capabilities"`
		}{NativeSession: nativeSession, ProviderBinding: j.ProviderBinding, PeerCapabilities: sessionCaps}
		owner := &api{localapi.New(j.Socket, "")}
		if err := owner.request("POST", path+"/native-session", binding, nil); err != nil {
			return fmt.Errorf("bind provider session: %w", err)
		}
	}
	finishSource = source.publish(ctx, a, path, ref, s)
	if resume := j.Worker.Reattach; resume != nil {
		registration := struct {
			service.ReattachSpec
			PromptCapabilities  service.PromptCapabilities
			SessionCapabilities service.SessionCapabilities `json:"session_capabilities"`
		}{*resume, promptCaps, sessionCaps}
		if err := publishWorkerControl(ctx, a, path+"/control/reattached", registration); err != nil {
			return err
		}
		s.line("Reattached to the original provider session.")
	} else {
		showAssignment(s, j)
		s.event("user", "", "", j.Worker.Task)
		if managed {
			registration := struct {
				PromptCapabilities  service.PromptCapabilities
				SessionCapabilities service.SessionCapabilities `json:"session_capabilities"`
				ProviderSession     *service.NativeSession      `json:"provider_session,omitempty"`
			}{PromptCapabilities: promptCaps, SessionCapabilities: sessionCaps}
			if ref.GetHarnessInstance() == service.LocalClaudeHarness {
				registration.ProviderSession = &nativeSession
			}
			if err := a.request("POST", path+"/control/ready", registration, nil); err != nil {
				return err
			}
		}
	}
	go terminalInput(j, a, s)
	observeCtx, stopObserve := context.WithCancel(ctx)
	if protocolVersion == 2 {
		source.v2 = &acpV2Inputs{api: a, path: path}
		go func() {
			if err := runACPControl(observeCtx, client, a, s, path, ref, service.ACPSessionPermissionScope, false, false, capabilities, true); err != nil && observeCtx.Err() == nil {
				s.line("Provider permission delivery is uncertain.")
			}
		}()
	}
	updates, observeDone, streamLife := workerObservations(observeCtx, client, ref, source, s)
	defer func() { stopObserve(); <-observeDone }()

	turnID, prompt, messageID := "initial-"+j.Worker.ID, j.Worker.Task, ""
	var parts []service.PromptPart
	var lastFinishedState string
	if j.Worker.Reattach != nil {
		next, ok := waitForFollowUp(streamLife, a, path)
		if !ok {
			cause := context.Cause(streamLife)
			if ctx.Err() == nil && errors.Is(cause, errACPDisconnected) {
				return publishACPProviderExit(ctx, a, path, ref, "idle", cause)
			}
			return cause
		}
		lastFinishedState = "idle"
		turnID, prompt, messageID, parts = next.ID, next.Text, next.ID, next.Parts
		entry := acpFollowUpEvent(next)
		s.line("You: " + entry.Text)
		s.recordEvent(entry)
	}
	for {
		request := acpPromptRequest(ref, turnID, prompt, parts)
		state, observedTurnEnd, turnErr := "failed", false, context.Cause(streamLife)
		if lastFinishedState != "" && ctx.Err() == nil && idleACPExit(ref, turnErr) {
			return publishACPProviderExit(ctx, a, path, ref, lastFinishedState, turnErr)
		}
		if turnErr == nil {
			state, observedTurnEnd, turnErr = runACPTurn(ctx, client, request, source, a, s, path, managed, capabilities, updates)
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if !managed {
			return turnErr
		}
		if j.SSH != nil && errors.Is(turnErr, errACPDisconnected) {
			s.line("SSH disconnected. The original request and conversation are available for reconciliation.")
			s.flush()
			return publishWorkerControl(ctx, a, path+"/control/finish", map[string]string{
				"state": "disconnected", "message_id": messageID,
			})
		}
		outcome := map[string]any{"state": state, "message_id": messageID, "observed_turn_end": observedTurnEnd}
		switch state {
		case "max_tokens", "max_turn_requests", "refusal":
			outcome["stop_reason"] = state
			state, outcome["state"] = "idle", "idle"
		case "completed":
			outcome["stop_reason"] = "end_turn"
		case "idle":
			if observedTurnEnd {
				outcome["stop_reason"] = "cancelled"
			}
		}
		if turnErr != nil {
			outcome["error"] = turnErr.Error()
			if !observedTurnEnd && (errors.Is(turnErr, errACPObservationGap) || errors.Is(turnErr, errACPDisconnected)) {
				outcome["delivery_unknown"] = true
			}
		}
		s.flush()
		if err := publishWorkerControl(ctx, a, path+"/control/finish", outcome); err != nil {
			return err
		}
		if turnErr != nil {
			return turnErr
		}
		lastFinishedState = state
		next, ok := waitForFollowUp(streamLife, a, path)
		if !ok {
			cause := context.Cause(streamLife)
			if ctx.Err() == nil && idleACPExit(ref, cause) {
				return publishACPProviderExit(ctx, a, path, ref, lastFinishedState, cause)
			}
			return cause
		}
		turnID, prompt, messageID, parts = next.ID, next.Text, next.ID, next.Parts
		entry := acpFollowUpEvent(next)
		s.line("You: " + entry.Text)
		s.recordEvent(entry)
	}
}

func idleACPExit(ref *model.SessionRef, cause error) bool {
	return errors.Is(cause, errACPObservationGap) ||
		ref.GetHarnessInstance() == service.LocalClaudeHarness && errors.Is(cause, errACPDisconnected)
}

func publishACPProviderExit(ctx context.Context, a *api, path string, ref *model.SessionRef, state string, cause error) error {
	report := map[string]string{
		"harness_instance": ref.GetHarnessInstance(), "session_id": ref.GetSessionId(), "last_state": state,
	}
	if errors.Is(cause, errACPObservationGap) {
		report["reason"] = "observation_gap"
	}
	return publishWorkerControl(ctx, a, path+"/control/provider-exit", report)
}

func openSessionRuntime(j job, config runtime.Config) (harness.Runtime, error) {
	if j.BuiltinInstance == "" {
		return runtime.New(config)
	}
	adapter, err := boundBuiltin(j.BuiltinInstance)
	if err != nil {
		return nil, err
	}
	config.ReadHistory = builtinHistory(adapter, config.WorkingDirectory)
	session, err := adapter.Open(config)
	if err == nil && session == nil {
		return nil, fmt.Errorf("built-in adapter %s returned no runtime", j.BuiltinInstance)
	}
	return session, err
}

func planningConfig(j job) (runtime.Config, error) {
	if j.Codex != nil {
		return j.Codex.config(j)
	}
	if j.RegisteredACP != nil || j.BuiltinInstance != "" {
		profile := j.RegisteredACP
		config := runtime.Config{
			HarnessInstance: j.BuiltinInstance, WorkingDirectory: j.Worker.Path, OncePermissionsOnly: true,
		}
		if profile != nil {
			config.HarnessInstance = profile.instance(j.Harness)
			config.Command, config.Args, config.Env = profile.Command, profile.Args, j.RegisteredEnv
		}
		if profile == nil || !profile.OmitCommanderMCP {
			servers, _, _ := agentPolicy(j)
			commander := servers["commander"]
			config.MCPServers = []runtime.MCPServer{{Name: "commander", Command: commander.Command, Args: commander.Args, Env: commander.Env}}
		}
		return config, nil
	}
	if j.Harness != "claude" {
		return runtime.Config{}, fmt.Errorf("unsupported managed planning profile %q", j.Harness)
	}
	servers, instructions, allowed := agentPolicy(j)
	builtins := []string{"Read", "Grep", "Glob"}
	if j.Worker.CodingSource != nil {
		builtins = append(builtins, "Edit", "Write")
	}
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
		HarnessInstance:     service.LocalClaudeHarness, WorkingDirectory: j.Worker.Path, Command: j.Adapter,
		SessionMeta: map[string]any{
			"systemPrompt": map[string]string{"append": instructions},
			"claudeCode": map[string]any{"options": map[string]any{
				"tools": builtins, "allowedTools": allowedTools, "disallowedTools": disallowed,
				"strictMcpConfig": true, "settingSources": []string{},
				"allowDangerouslySkipPermissions": false, "mcpServersDelivery": "initialize",
			}},
		},
	}

	if os.Getenv("AGENT_COMMANDER_ACP_SYSTEM_PROMPT") == "standard" {
		config.SystemPromptAppend = instructions
	}
	for name, srv := range servers {
		config.MCPServers = append(config.MCPServers, runtime.MCPServer{Name: name, Command: srv.Command, Args: srv.Args, Env: srv.Env})
	}
	return config, nil
}

type acpUpdate struct {
	event *model.Observation
	err   error
	ended chan struct{}
}

func acpOpenRequest(j job, instance, cwd string) *model.OpenRequest {
	req := &model.OpenRequest{HarnessInstance: instance, WorkingDirectory: cwd}
	if j.Harness == "claude" && j.RegisteredACP == nil && j.BuiltinInstance == "" && j.Codex == nil {
		// The SDK sets the session's model over ACP before accepting its first turn.
		req.Model = managedClaudeModel
	}
	return req
}

func acpPromptRequest(ref *model.SessionRef, turnID, text string, parts []service.PromptPart) *model.SendRequest {
	request := &model.SendRequest{Session: ref, OperationId: turnID}
	if len(parts) == 0 {
		request.Text = text
		return request
	}
	request.Parts = make([]*model.PromptPart, 0, len(parts))
	for _, part := range parts {
		item := &model.PromptPart{}
		switch part.Type {
		case "text":
			item.Content = &model.PromptPart_Text{Text: part.Text}
		case "image":
			item.Content = &model.PromptPart_Image{Image: &model.PromptMedia{MimeType: part.MIMEType, Data: part.Data}}
		case "audio":
			item.Content = &model.PromptPart_Audio{Audio: &model.PromptMedia{MimeType: part.MIMEType, Data: part.Data}}
		case "resource_link":
			item.Content = &model.PromptPart_ResourceLink{ResourceLink: &model.PromptResourceLink{Uri: part.URI, Name: part.Name, MimeType: part.MIMEType}}
		case "resource":
			resource := &model.PromptResource{Uri: part.URI, MimeType: part.MIMEType}
			if part.ResourceText != nil {
				resource.Body = &model.PromptResource_Text{Text: *part.ResourceText}
			} else {
				resource.Body = &model.PromptResource_Blob{Blob: part.Data}
			}
			item.Content = &model.PromptPart_Resource{Resource: resource}
		}
		request.Parts = append(request.Parts, item)
	}
	return request
}

func acpFollowUpEvent(message service.ClaimedWorkerFollowUp) service.ConsoleEvent {
	entry := service.ConsoleEvent{Kind: "user", Text: message.Text}
	if len(message.Parts) == 0 {
		return entry
	}
	var preview strings.Builder
	var mediaCount int
	for i, part := range message.Parts {
		if part.Type == "text" {
			preview.WriteString(part.Text)
		} else {
			fmt.Fprintf(&preview, "[ACP %s] %s", part.Type, part.MIMEType)
			mediaCount++
			if entry.ACP == nil {
				entry.ACP = acpprocessor.Reference("live", promptPartCursor(message.ID, i), service.LivePromptMediaPartKind, "")
				entry.ACP.TurnID = message.ID
				entry.ACP.ContentType = part.Type
				if len(part.MIMEType) <= 128 {
					entry.ACP.MIMEType = part.MIMEType
				}
			}
		}
	}
	if entry.ACP != nil {
		entry.ACP.ItemCount = &mediaCount
	} else if len(message.Parts) > 1 {
		entry.ACP = acpprocessor.Reference("live", "prompt-"+message.ID, service.LiveTextPromptKind, "")
		entry.ACP.TurnID, entry.ACP.ContentType = message.ID, "text"
	}
	entry.Text = preview.String()
	return entry
}

// One subscription owns each bound session, including the time between prompts.
// Only turn events and terminal errors need the active turn's control loop.
func workerObservations(ctx context.Context, client *agentacp.Sessions, ref *model.SessionRef, source *acpSourcePublisher, screen *screen) (<-chan acpUpdate, <-chan struct{}, context.Context) {
	updates := make(chan acpUpdate, 64)
	done := make(chan struct{})
	life, ended := context.WithCancelCause(ctx)
	go func() {
		cause := errACPDisconnected
		defer close(done)
		defer close(updates)
		defer func() {
			ended(cause)
			if ctx.Err() == nil && !errors.Is(cause, errACPObservationGap) {
				message := "Provider observation stream ended: " + cause.Error()
				screen.line(message)
				screen.event("output", "", "", message)
			}
		}()
		for event, err := range client.Observe(ctx, &model.ObserveRequest{Session: ref}) {
			if err != nil && ctx.Err() == nil {
				cause = err
				if !errors.Is(err, errACPDisconnected) {
					cause = errors.New("the provider observation stream failed")
				}
				err = cause
			}
			if err == nil && !sameSession(event.GetSession(), ref) {
				cause = errors.New("observation does not belong to the selected session")
				err = cause
			}
			if err == nil && source.portable && event.GetGap() == nil && event.GetCursor() == "" {
				cause = errors.New("built-in adapter returned an observation without a cursor")
				err = cause
			}

			if err == nil && event.GetGap() != nil {
				// Compiled adapters use their own retention contracts. Only the
				// bundled ACP runtime guarantees continuity for this marker.
				recoverable := !source.portable && runtime.IsObservationOnlyGap(event)
				if recoverable {
					if source.activeTurn.Load() {
						select {
						case updates <- acpUpdate{event: event}:
						case <-ctx.Done():
							return
						}
					} else {
						source.showObservationGap(ctx, screen, event, true)
					}
					continue
				}
				source.showObservationGap(ctx, screen, event, false)
				cause, err = errACPObservationGap, errACPObservationGap
			}
			if err == nil && source.v2 != nil && source.v2.handles(event) {
				if err := source.v2.observe(ctx, source, screen, event); err != nil {
					cause = err
					return
				}
				continue
			}
			if err == nil && event.GetTurnId() == "" && event.GetGap() == nil {
				if source.portable && source.takeIdle(idleKey(event.Session, event.Cursor)) {
					continue
				}
				activity := source.captureObservation(ctx, event)
				if activity != nil {
					entry := idleSourcedEvent(event, activity)
					if source.v2 != nil {
						if message, ok := acpV2Message(event, activity); ok {
							entry = message
						}
					}
					screen.line(previewText(entry.TerminalText()))
					screen.recordEvent(entry)
				}
				continue
			}
			packet := acpUpdate{event: event, err: err}
			if err == nil && event.GetTurnEnded() != nil {
				packet.ended = make(chan struct{})
			}
			select {
			case updates <- packet:
			case <-ctx.Done():
				return
			}
			if packet.ended != nil {
				select {
				case <-packet.ended:
				case <-ctx.Done():
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()
	return updates, done, life
}

func runACPTurn(ctx context.Context, client *agentacp.Sessions, request *model.SendRequest, source *acpSourcePublisher, a *api, s *screen, path string, managed bool, capabilities *model.Capabilities, updates <-chan acpUpdate) (string, bool, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	ref, turnID := request.Session, request.OperationId
	source.activeTurn.Store(true)
	defer source.activeTurn.Store(false)
	localClaude := managed && ref.GetHarnessInstance() == service.LocalClaudeHarness
	sent, err := client.Send(ctx, request)
	if err = accepted(turnID, sent.GetReceipt(), err); err != nil {
		return "failed", false, err
	}
	var controlErrors <-chan error
	if a != nil && (managed || capabilities.GetCanAnswer()) {
		errs := make(chan error, 1)
		done := make(chan struct{})
		defer func() { cancel(); <-done }()
		go func() {
			defer close(done)
			controlCtx, stopControl := context.WithCancel(ctx)
			defer stopControl()
			if err := runACPControl(controlCtx, client, a, s, path, ref, turnID, managed, localClaude, capabilities, source.v2 != nil); err != nil {
				errs <- err
			}
		}()
		controlErrors = errs
	}
	source.capturePrompt(ctx, request)
	var text strings.Builder
	var textTimer *time.Timer
	var textDeadline <-chan time.Time
	firstText := true
	flushText := func() {
		if text.Len() > 0 {
			s.event("text", "", "", text.String())
			text.Reset()
		}
	}
	scheduleText := func() {
		if textDeadline != nil {
			return
		}
		const maxCoalescing = 25 * time.Millisecond
		if textTimer == nil {
			textTimer = time.NewTimer(maxCoalescing)
		} else {
			textTimer.Reset(maxCoalescing)
		}
		textDeadline = textTimer.C
	}
	defer func() {
		if textTimer != nil {
			textTimer.Stop()
		}
		flushText()
	}()
	for {
		select {
		case <-ctx.Done():
			return "idle", false, ctx.Err()
		case err := <-controlErrors:
			return "failed", false, err
		case <-textDeadline:
			textDeadline = nil
			flushText()
			s.publishAvailable()
		case update, ok := <-updates:
			if update.err != nil {
				return "failed", false, update.err
			}
			if !ok {
				return "failed", false, errACPDisconnected
			}
			e := update.event
			if e.GetGap() != nil {
				flushText()
				source.showObservationGap(ctx, s, e, true)
				continue
			}
			if update.ended != nil {
				if e.TurnId == turnID {
					defer close(update.ended)
				} else {
					close(update.ended)
				}
			}
			portableRef := source.captureObservation(ctx, e)
			if ext := paramsSource(e); ext != nil && portableRef == nil && ctx.Err() == nil {
				return "failed", false, errors.New("could not publish selected session update source")
			}
			if e.GetTurnId() != turnID {
				continue
			}
			if localClaude {
				s.recordClaudeProgress(claudeProgressPhase(e))
			}
			if source.v2 != nil {
				if entry, ok := acpV2Message(e, portableRef); ok {
					flushText()
					s.write(entry.Text)
					s.recordEvent(entry)
					if entry.Kind == "text" && entry.Text != "" {
						if firstText {
							firstText = false
							s.publishAvailable()
						} else {
							scheduleText()
						}
					}
					continue
				}
			}
			switch {
			case e.GetText() != nil && e.GetText().Speaker == model.Speaker_SPEAKER_ASSISTANT:
				value := consoleText(e.GetText().Text)
				s.write(value)
				if ref := sourceReference(source.take(e.Cursor), portableRef); ref != nil || firstText {
					if value == "" && ref == nil {
						continue
					}
					flushText()
					s.recordEvent(service.ConsoleEvent{Kind: "text", Text: value, ACP: ref})
					if firstText && value != "" {
						firstText = false
						s.publishAvailable()
					} else {
						scheduleText()
					}
					continue
				}
				if value != "" {
					scheduleText()
					text.WriteString(value)
					if strings.HasSuffix(value, "\n") || text.Len() >= 8192 {
						flushText()
					}
				}
			case e.GetTool() != nil:
				flushText()
				event := consoleTool(e.GetTool())
				wire := source.takeWire(e.Cursor)
				if event.Kind == "tool_call" {
					if wire.toolCallID == event.ToolID {
						event.CommanderInput = wire.commanderInput
					}
					if event.CommanderInput == "" {
						event.CommanderInput = commanderInputFromACP(e, event.Name)
					}
				}
				event.ACP = sourceReference(wire.Activity, portableRef)
				s.line(previewText(event.TerminalText()))
				values := wire.detail
				if values == nil || values.Key != e.GetTool().GetCallId() {
					values = observedToolDetail(e)
				}
				if event.Kind == "tool_result" {
					if values == nil {
						values = &service.ToolDetail{Kind: "tool"}
					}
					if values.Result == "" {
						values.Result = e.GetTool().GetSummary()
					}
				}
				s.recordDetailed(event, values)
			case e.GetText() != nil && e.GetText().Speaker == model.Speaker_SPEAKER_USER:
				// Actual peer chunks have a wire identity. The SDK's local prompt echo is
				// already recorded for the initial assignment or accepted follow-up.
				ref := source.take(e.Cursor)
				if ref == nil && paramsSource(e) != nil {
					ref = portableRef
				}
				if ref != nil {
					flushText()
					event := service.ConsoleEvent{Kind: "user", Text: e.GetText().Text, ACP: ref}
					s.line(previewText(event.Text))
					s.recordEvent(event)
				}
			case e.GetExtension() != nil || typedObservation(e):
				flushText()
				event := acpExtensionEvent(e, "live")
				if event.ACP == nil {
					event.ACP = portableRef
				} else if portableRef != nil {
					event.ACP.Cursor = portableRef.Cursor
				}
				if event.ACP != nil {
					event.ACP.TurnID = e.TurnId
				}
				s.line(event.TerminalText())
				s.recordDetailed(event, planDetail(e))
			case e.GetText() != nil && e.GetText().Speaker == model.Speaker_SPEAKER_SYSTEM:
				flushText()
				value := consoleText(e.GetText().Text)
				s.line(previewText(value))
				s.recordEvent(service.ConsoleEvent{Kind: "output", Text: value, ACP: portableRef})
			case e.GetInput() != nil:
				flushText()
				if !capabilities.GetCanAnswer() {
					return "failed", false, errors.New("provider requested an answer without advertising support for answers")
				}
				request := e.GetInput()
				if request.RequestId == "" || len(request.Choices) == 0 {
					return "failed", false, errors.New("provider requested an unsupported form of input")
				}
				choices := make([]service.QuestionChoice, 0, len(request.Choices))
				for _, option := range request.Choices {
					choices = append(choices, service.QuestionChoice{ID: option.Id, Label: option.Label})
				}
				var q service.Question
				if err := a.requestContext(ctx, "POST", path+"/questions", map[string]any{
					"question": request.Prompt, "choices": choices,
					"idempotency_key": request.RequestId, "provider_turn": turnID, "provider_request": request.RequestId,
					"provider_tool_call_id": acpPermissionToolCallID(e, false),
				}, &q); err != nil {
					return "failed", false, err
				}
				if q.Status == "cancelled" {
					continue
				}
				s.line(q.ID + " · " + q.Question)
				if portableRef != nil {
					s.recordEvent(service.ConsoleEvent{Kind: "output", Text: "[Provider event: Permission requested] " + q.Question, ACP: portableRef})
				}
			case e.GetTurnEnded() != nil:
				source.activeTurn.Store(false)
				flushText()
				observedTurnEnd := recordACPTurnEnd(s, e, portableRef)
				reason := e.GetTurnEnded().Reason
				if acpDisconnected(reason) {
					return "failed", false, errACPDisconnected
				}
				switch reason {
				case "end_turn":
					s.line("")
					return "completed", observedTurnEnd, nil
				case "cancelled":
					s.line("Turn interrupted.")
					return "idle", observedTurnEnd, nil
				case "max_tokens", "max_turn_requests", "refusal":
					s.line("Turn stopped: " + reason + ". This conversation is ready for a follow-up.")
					return reason, observedTurnEnd, nil
				default:
					return "failed", observedTurnEnd, fmt.Errorf("provider stopped the turn: %s", reason)
				}
			}
		}
	}
}

// recordACPTurnEnd keeps a genuine peer result for the local transcript. The
// existing console event remains the anchor when it has a source reference.
func recordACPTurnEnd(s *screen, event *model.Observation, ref *acpprocessor.Activity) bool {
	original := event.GetSourceRecord()
	sourceType := original.GetType()
	observed := sourceType == "acp.prompt_result" || sourceType == runtime.ACPV2TurnResultSource
	reason := event.GetTurnEnded().GetReason()
	var detail *service.ToolDetail
	if observed && event.GetTurnId() != "" && reason != "" && !acpDisconnected(reason) {
		detail = &service.ToolDetail{
			Kind:          "turn_end",
			Key:           "turn-end-" + event.GetTurnId(),
			TurnEndDetail: &service.TurnEndDetail{StopReason: previewPrefix(reason, 256)},
		}
	}
	if ref != nil {
		if detail != nil {
			detail.Key = consoleToolID(detail.Key)
		}
		if sourceType == "acp.prompt_result" {
			ref.TurnTokens = acpprocessor.PromptResultTokens(original.GetData())
		}
		s.recordDetailed(service.ConsoleEvent{Kind: "output", Text: "[Provider event: Turn ended]", ACP: ref}, detail)
	} else if detail != nil {
		s.recordDetail(*detail)
	}
	return observed
}

func runACPControl(ctx context.Context, client *agentacp.Sessions, a *api, s *screen, path string,
	ref *model.SessionRef, turnID string, managed, localClaude bool, capabilities *model.Capabilities, backgroundPermissions bool) error {
	answered := make(map[string]bool)
	interruptAttempted := false
	for feed := range a.watchControl(ctx, path, turnID) {
		if localClaude && feed.ProviderAvailability == "checking" {
			_ = a.requestContext(ctx, "POST", path+"/control/reconcile", map[string]any{
				"session": service.NativeSession{HarnessInstance: ref.GetHarnessInstance(), SessionID: ref.GetSessionId()},
				"turn_id": turnID, "generation": feed.Generation,
			}, nil)
		} else if managed && capabilities.GetCanInterrupt() && !interruptAttempted && feed.InterruptRequested {
			claim := map[string]any{"generation": feed.Generation}
			if !backgroundPermissions {
				claim["permission_turn_id"] = turnID
			}
			operationID := "interrupt-" + turnID
			if feed.InterruptID != "" {
				claim["id"], claim["turn_id"] = feed.InterruptID, turnID
				operationID = feed.InterruptID
			}
			if a.requestContext(ctx, "POST", path+"/control/interrupt/claim", claim, nil) == nil {
				interruptAttempted = true
				result, err := client.Interrupt(ctx, &model.InterruptRequest{Session: ref, OperationId: operationID, TurnId: turnID})
				phase := "sent"
				if err = accepted(operationID, result.GetReceipt(), err); err != nil {
					phase = "unconfirmed"
					if ctx.Err() == nil {
						s.line("Interrupt could not be confirmed: " + err.Error())
					}
				}
				if feed.InterruptID != "" {
					claim["phase"] = phase
					delete(claim, "permission_turn_id")
					reportCtx, cancelReport := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
					err := publishWorkerControl(reportCtx, a, path+"/control/interrupt/report", claim)
					cancelReport()
					if err != nil && ctx.Err() == nil {
						s.line("Interrupt evidence could not be saved: " + err.Error())
					}
				}
			}
		}
		if interruptAttempted {
			continue
		}
		for _, q := range feed.Answers {
			if answered[q.ID] {
				continue
			}
			id := "answer-" + q.ID
			answer, err := client.Answer(ctx, &model.AnswerRequest{
				Session: ref, OperationId: id, RequestId: q.ProviderRequest,
				Answer: &model.AnswerRequest_OptionId{OptionId: q.Choice},
			})
			if answer.GetReceipt().GetStatus() == model.DeliveryStatus_DELIVERY_STATUS_UNKNOWN {
				return errACPDisconnected
			}
			if err = accepted(id, answer.GetReceipt(), err); err != nil {
				if turnID != service.ACPSessionPermissionScope || ctx.Err() != nil {
					return err
				}
				s.line("Provider permission is no longer available for reply.")
			}
			answered[q.ID] = true
		}
	}
	return nil
}

func acpDisconnected(reason string) bool {
	if reason == "adapter disconnected" {
		return true
	}
	// A shutdown can surface as the prompt RPC error before the SDK observes
	// the adapter exit. Match the transport detail, not every internal error.
	raw, ok := strings.CutPrefix(reason, "session/prompt: ")
	if !ok {
		return false
	}
	var failure struct {
		Code int
		Data struct{ Error string }
	}
	return json.Unmarshal([]byte(raw), &failure) == nil && failure.Code == -32603 &&
		failure.Data.Error == "peer disconnected before response"
}

func consoleTool(tool *model.ToolActivity) service.ConsoleEvent {
	summary := tool.GetSummary()
	// Passive vendor APIs can put the full structured tool payload in Summary.
	// Keep a large JSON record intact in scoped history instead of copying a
	// clipped attachment prefix into the terminal and workspace stream.
	if len(summary) > maxConsoleEventBytes {
		trimmed := strings.TrimSpace(summary)
		if (strings.HasPrefix(trimmed, "{") || strings.HasPrefix(trimmed, "[")) && json.Valid([]byte(trimmed)) {
			summary = "[Large tool payload omitted from console preview]"
		}
	}
	event := service.ConsoleEvent{ToolID: tool.CallId, Name: strings.TrimPrefix(tool.Name, "mcp__commander__"),
		Phase: tool.Phase, Text: summary}
	switch tool.Phase {
	case "failed", "declined", "cancelled", "interrupted":
		event.Kind = "tool_result"
		if event.Text == "" {
			event.Text = event.ToolFailure()
		} else {
			event.Text = event.ToolFailure() + "\n" + event.Text
		}
	case "completed":
		event.Kind = "tool_result"
	default:
		event.Kind = "tool_update"
		if event.Name != "" {
			event.Kind = "tool_call"
		}
	}
	return event
}

func (s *screen) recordTool(tool *model.ToolActivity) {
	event := consoleTool(tool)
	s.line(previewText(event.TerminalText()))
	s.recordEvent(event)
}

func extensionText(extension *model.Extension) string {
	title := fmt.Sprintf("[Provider event: %s · %s]", extension.GetType(), extension.GetMediaType())
	data := extension.GetData()
	if len(data) == 0 {
		return title
	}
	if len(title)+1+len(data) <= maxConsoleEventBytes && json.Valid(data) {
		return title + "\n" + string(data)
	}
	const base64Prefix = "\nBase64: "
	if len(title)+len(base64Prefix)+base64.StdEncoding.EncodedLen(len(data)) <= maxConsoleEventBytes {
		return title + base64Prefix + base64.StdEncoding.EncodeToString(data)
	}
	return title + "\n[Large provider payload omitted from console preview]"
}

func accepted(operation string, receipt *model.Receipt, err error) error {
	if err != nil {
		return err
	}
	if receipt.GetOperationId() != operation {
		return errors.New("provider returned a receipt for a different operation")
	}
	switch receipt.GetStatus() {
	case model.DeliveryStatus_DELIVERY_STATUS_ACCEPTED, model.DeliveryStatus_DELIVERY_STATUS_DELIVERED:
		return nil
	default:
		return fmt.Errorf("provider delivery %s: %s", receipt.GetStatus(), receipt.GetDetail())
	}
}

package provider

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	agentacp "agent-acp.local/sdks/go"
	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/nativehistory"
	"agent-acp.local/sdks/go/runtime"

	"agentcommander/internal/acpprocessor"
	"agentcommander/internal/service"
)

// openNativeHistory binds the persisted handle to its provider's passive
// reader. Historical permissions are text only. Only live requests are actionable.
type historyReader func(context.Context, *model.ReadHistoryRequest) (*model.ReadHistoryResponse, error)

var acpHistoryReaders = map[string]func(directory, cwd string) historyReader{
	"pi-jsonl-v3": piHistoryReader,
}

func (l *Local) openNativeHistory(native service.NativeSession, cwd string) (*runtime.Runtime, *model.ReadHistoryRequest, error) {
	config := runtime.Config{HarnessInstance: native.HarnessInstance, WorkingDirectory: cwd}
	name, local := strings.CutPrefix(native.HarnessInstance, "local-")
	reader := nativehistory.ForHarness(name, cwd)
	if strings.HasPrefix(native.HarnessInstance, "local-builtin:") {
		adapter, err := boundBuiltin(native.HarnessInstance)
		if err != nil {
			return nil, nil, err
		}
		reader = builtinHistory(adapter, cwd)
	} else if profileName, external := strings.CutPrefix(name, "profile-"); local && external {
		id, _, _ := strings.Cut(profileName, ":history-")
		profile := l.acpProfiles[id]
		if profile.History != nil && profile.instance(id) == native.HarnessInstance {
			if open := acpHistoryReaders[profile.History.Format]; open != nil {
				reader = open(profile.History.Directory, cwd)
			}
		}
	} else if strings.HasPrefix(native.HarnessInstance, "local-managed-codex-") {
		p, err := configuredManagedCodex()
		if err != nil || native.HarnessInstance != p.instance() {
			return nil, nil, errors.New("native history is unavailable for this managed Codex profile")
		}
		reader = p.readHistory(cwd)
	} else if !local {
		p, err := configuredSSHProfile()
		if err != nil || native.HarnessInstance != p.harnessInstance() || cwd != p.Checkout {
			return nil, nil, errors.New("native history is unavailable for this SSH binding")
		}
		reader = p.readHistory(cwd)
	}
	if reader == nil {
		return nil, nil, errors.New("native history is unavailable for this harness")
	}
	config.ReadHistory = reader
	rt, err := runtime.New(config)
	if err != nil {
		return nil, nil, err
	}
	return rt, &model.ReadHistoryRequest{Session: &model.SessionRef{HarnessInstance: native.HarnessInstance, SessionId: native.SessionID}}, nil
}

// ReadNativeHistoryPage exposes the SDK observation schema, including provider
// extensions that have no equivalent in the workspace's text projection.
func (l *Local) ReadNativeHistoryPage(ctx context.Context, native service.NativeSession, cwd, cursor string, limit uint32) (json.RawMessage, error) {
	page, err := l.readHistoryPage(ctx, native, cwd, cursor, limit)
	if err != nil {
		return nil, err
	}
	return marshalHistoryPage(page)
}

func (l *Local) readHistoryPage(ctx context.Context, native service.NativeSession, cwd, cursor string, limit uint32) (*model.ReadHistoryResponse, error) {
	if l.RequiresStoppedHistory(native) {
		snapshot, err := l.loadReplaySnapshot(ctx, native, cwd)
		if errors.Is(err, runtime.ErrReplaySnapshotLimit) {
			return replayLimitPage(native), nil
		}
		if err != nil {
			return nil, err
		}
		return snapshot.Page(cursor, limit)
	}
	rt, request, err := l.openNativeHistory(native, cwd)
	if err != nil {
		return nil, err
	}
	defer rt.Close()
	request.Cursor, request.Limit = cursor, limit
	return agentacp.New(rt).ReadHistory(ctx, request)
}

const providerProjectionPageSize = 128

// ReadNativeHistoryRecord reads the same SDK page used to build the chat
// preview and serializes only the selected record. The page hint conveys
// neither session authority nor the identity of a neighboring record.
func (l *Local) ReadNativeHistoryRecord(ctx context.Context, native service.NativeSession, cwd, pageCursor, recordCursor string) (json.RawMessage, error) {
	if l.RequiresStoppedHistory(native) {
		snapshot, err := l.loadReplaySnapshot(ctx, native, cwd)
		if errors.Is(err, runtime.ErrReplaySnapshotLimit) {
			return marshalHistoryPage(replayLimitPage(native))
		}
		if err != nil {
			return nil, err
		}
		record, err := snapshot.Record(recordCursor)
		if err != nil {
			record = missingHistoryRecord(native)
		}
		return marshalHistoryPage(&model.ReadHistoryResponse{Observations: []*model.Observation{record}})
	}
	page, err := l.readHistoryPage(ctx, native, cwd, pageCursor, providerProjectionPageSize)
	if err != nil {
		return nil, err
	}
	return marshalHistoryPage(selectHistoryRecord(page, native, recordCursor))
}

func selectHistoryRecord(page *model.ReadHistoryResponse, native service.NativeSession, cursor string) *model.ReadHistoryResponse {
	var match, gap *model.Observation
	for _, record := range page.GetObservations() {
		session := record.GetSession()
		if session.GetSessionId() != native.SessionID || session.GetHarnessInstance() != native.HarnessInstance {
			continue
		}
		if record.GetGap() != nil {
			gap = record
			continue
		}
		if record.GetCursor() == cursor && cursor != "" {
			if match != nil {
				match, gap = nil, nil
				break
			}
			match = record
		}
	}
	if match == nil {
		match = gap
	}
	if match == nil {
		match = missingHistoryRecord(native)
	}
	return &model.ReadHistoryResponse{Observations: []*model.Observation{match}}
}

func missingHistoryRecord(native service.NativeSession) *model.Observation {
	return &model.Observation{
		Session: &model.SessionRef{HarnessInstance: native.HarnessInstance, SessionId: native.SessionID},
		Event:   &model.Observation_Gap{Gap: &model.HistoryGap{Reason: "The selected record is no longer available on this provider history page."}},
	}
}

func (l *Local) ReadConsoleHistory(ctx context.Context, native service.NativeSession, cwd string) ([]service.ConsoleEvent, error) {
	if l.RequiresStoppedHistory(native) {
		snapshot, err := l.loadReplaySnapshot(ctx, native, cwd)
		if errors.Is(err, runtime.ErrReplaySnapshotLimit) {
			return []service.ConsoleEvent{{Kind: "output", Text: replayLimitReason, Sequence: 1}}, nil
		}
		if err != nil {
			return nil, err
		}
		return projectConsoleHistory(func(cursor string) (*model.ReadHistoryResponse, error) {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			return snapshot.Page(cursor, providerProjectionPageSize)
		})
	}
	rt, request, err := l.openNativeHistory(native, cwd)
	if err != nil {
		return nil, err
	}
	defer rt.Close()
	sessions := agentacp.New(rt)
	request.Limit = providerProjectionPageSize
	return projectConsoleHistory(func(cursor string) (*model.ReadHistoryResponse, error) {
		request.Cursor = cursor
		return sessions.ReadHistory(ctx, request)
	})
}

func projectConsoleHistory(read func(cursor string) (*model.ReadHistoryResponse, error)) ([]service.ConsoleEvent, error) {
	var pageCursor string
	var events []service.ConsoleEvent
	var prompt historyPrompt
	sequence, bytes := 0, 0
	appendEvent := func(event service.ConsoleEvent) {
		event = previewConsoleEvent(event)
		sequence++
		event.Sequence = sequence
		events = append(events, event)
		bytes += len(event.Text)
		for len(events) > 128 || bytes > 64<<10 {
			bytes -= len(events[0].Text)
			events[0] = service.ConsoleEvent{}
			events = events[1:]
		}
	}
	for {
		page, err := read(pageCursor)
		if err != nil {
			return nil, err
		}
		for _, obs := range page.Observations {
			if row, handled := prompt.observe(obs, pageCursor); handled {
				if row.ACP != nil {
					appendEvent(row)
				}
				continue
			}
			event := service.ConsoleEvent{}
			switch {
			case obs.GetText() != nil:
				event.Text = obs.GetText().GetText()
				switch obs.GetText().Speaker {
				case model.Speaker_SPEAKER_USER:
					event.Kind = "user"
				case model.Speaker_SPEAKER_ASSISTANT:
					event.Kind = "text"
				default:
					event.Kind = "output"
				}
			case obs.GetTool() != nil:
				event = retainedToolEvent(obs.GetTool())
			case obs.GetInput() != nil:
				event.Kind, event.Text = "output", "Past request: "+obs.GetInput().Prompt
			case obs.GetTurnEnded() != nil && obs.GetSourceCursor() != "":
				event.Kind, event.Text = "output", "Turn ended"
				if reason := obs.GetTurnEnded().GetReason(); reason != "" {
					event.Text += " · " + reason
				}
			case obs.GetGap() != nil:
				event.Kind, event.Text = "output", obs.GetGap().Reason
			case obs.GetExtension() != nil:
				if obs.GetExtension().GetType() == runtime.ACPReplaySource {
					update, _ := acpprocessor.ExtensionUpdate(obs.GetExtension())
					// The replay adapter follows a portable text/tool observation
					// with its source record, including across page boundaries.
					// Attach its identity once, preserving the existing preview row.
					if len(events) > 0 && linkReplaySource(&events[len(events)-1], &update, obs.Cursor) {
						continue
					}
					event = acpActivityEvent(&update, "provider", obs.Cursor)
				} else {
					if len(events) > 0 {
						linkPiToolResult(&events[len(events)-1], obs)
					}
					event = acpExtensionEvent(obs, "provider")
				}
			default:
				continue
			}
			if cursor := obs.GetSourceCursor(); cursor != "" {
				if ext := paramsSource(obs); ext.GetType() == runtime.ACPUpdateParamsSource {
					inner, err := acpprocessor.ScopedUpdate(ext.Data, obs.GetSession().GetSessionId())
					if err != nil {
						return nil, err
					}
					decoded := acpprocessor.Decode(inner)
					event.ACP = decoded.Activity("provider", cursor)
				} else {
					event.ACP = acpprocessor.Reference("provider", cursor, "provider_record", "")
				}
				event.ACP.TurnID = obs.GetTurnId()
			} else if event.ACP == nil && obs.GetExtension() != nil && obs.Cursor != "" {
				// Some adapters retain the original as the extension itself. A
				// bounded preview still opens that row's exact SDK observation.
				event.ACP = acpprocessor.Reference("provider", obs.Cursor, "provider_record", "")
				event.ACP.PageCursor, event.ACP.TurnID = pageCursor, obs.GetTurnId()
			}
			if call, ok := retainedCodexCall(obs, &event); ok {
				appendEvent(call)
			}
			appendEvent(event)
		}
		if page.NextCursor == "" {
			return events, nil
		}
		if page.NextCursor == pageCursor {
			return nil, errors.New("native history cursor did not advance")
		}
		pageCursor = page.NextCursor
	}
}

// Codex can retain both the invocation and the outcome in a single item. Give
// each its AG-UI role when the original identifies a call and its arguments.
// Standalone outputs continue to render with their original result identity.
func retainedCodexCall(obs *model.Observation, result *service.ConsoleEvent) (service.ConsoleEvent, bool) {
	source := obs.GetSourceRecord()
	if source.GetType() != "codex.history.item" || result.Kind != "tool_result" || result.ToolID == "" {
		return service.ConsoleEvent{}, false
	}
	var item struct {
		Type, ID                  string
		Arguments                 json.RawMessage
		Result, Error             json.RawMessage
		Command, AggregatedOutput *string
	}
	if json.Unmarshal(source.Data, &item) != nil || item.ID != result.ToolID {
		return service.ConsoleEvent{}, false
	}
	call := service.ConsoleEvent{Kind: "tool_call", ToolID: result.ToolID, Name: result.Name, ACP: result.ACP}
	switch item.Type {
	case "mcpToolCall", "dynamicToolCall":
		if len(item.Arguments) == 0 {
			return service.ConsoleEvent{}, false
		}
		call.Text = historyToolSummary(string(item.Arguments))
		// A failure or partial result keeps the complete preview from consoleTool.
		if len(item.Result) > 0 && string(item.Result) != "null" && (len(item.Error) == 0 || string(item.Error) == "null") &&
			result.ToolFailure() == "" {
			if cleaned, changed := historyMediaPreview(item.Result); changed {
				result.Text = cleaned
			} else if len(item.Result) <= maxConsoleEventBytes {
				result.Text = string(item.Result)
			}
		}
	case "commandExecution":
		if item.Command == nil {
			return service.ConsoleEvent{}, false
		}
		call.Text = *item.Command
		if item.AggregatedOutput != nil && result.ToolFailure() == "" {
			result.Text = *item.AggregatedOutput
		}
	default:
		return service.ConsoleEvent{}, false
	}
	return call, true
}

func linkReplaySource(event *service.ConsoleEvent, update *acpprocessor.Update, cursor string) bool {
	if event.ACP != nil {
		return false
	}
	v := &update.Value
	matches := v.UserMessageChunk != nil && event.Kind == "user" ||
		v.AgentMessageChunk != nil && event.Kind == "text"
	if event.Kind == "tool_call" || event.Kind == "tool_update" || event.Kind == "tool_result" {
		var toolID string
		switch {
		case v.ToolCall != nil:
			toolID = string(v.ToolCall.ToolCallId)
		case v.ToolCallUpdate != nil:
			toolID = string(v.ToolCallUpdate.ToolCallId)
		}
		matches = toolID != "" && event.ToolID == previewConsoleEvent(service.ConsoleEvent{ToolID: toolID}).ToolID
	}
	if matches {
		event.ACP = update.Activity("provider", cursor)
	}
	return matches
}

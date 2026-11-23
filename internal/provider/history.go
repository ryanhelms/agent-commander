package provider

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"unicode/utf8"

	agentacp "agent-acp.local/sdks/go"
	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/nativehistory"
	"agent-acp.local/sdks/go/runtime"

	"google.golang.org/protobuf/encoding/protojson"

	"agentcommander/internal/service"
)

// ReadConsoleHistory binds the persisted handle to its provider's passive
// reader. Historical permissions are text only. Only live requests are actionable.
func (l *Local) openNativeHistory(native service.NativeSession, cwd string) (*runtime.Runtime, *model.ReadHistoryRequest, error) {
	name, local := strings.CutPrefix(native.HarnessInstance, "local-")
	reader := nativehistory.ForHarness(name, cwd)
	if strings.HasPrefix(native.HarnessInstance, "local-managed-codex-") {
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
	rt, err := runtime.New(runtime.Config{HarnessInstance: native.HarnessInstance, WorkingDirectory: cwd, ReadHistory: reader})
	if err != nil {
		return nil, nil, err
	}
	return rt, &model.ReadHistoryRequest{Session: &model.SessionRef{HarnessInstance: native.HarnessInstance, SessionId: native.SessionID}}, nil
}

// ReadNativeHistoryPage exposes the SDK observation schema, including provider
// extensions that have no equivalent in the workspace's text projection.
func (l *Local) ReadNativeHistoryPage(ctx context.Context, native service.NativeSession, cwd, cursor string, limit uint32) (json.RawMessage, error) {
	rt, request, err := l.openNativeHistory(native, cwd)
	if err != nil {
		return nil, err
	}
	defer rt.Close()
	request.Cursor, request.Limit = cursor, limit
	page, err := agentacp.New(rt).ReadHistory(ctx, request)
	if err != nil {
		return nil, err
	}
	return (protojson.MarshalOptions{EmitDefaultValues: true}).Marshal(page)
}

func (l *Local) ReadConsoleHistory(ctx context.Context, native service.NativeSession, cwd string) ([]service.ConsoleEvent, error) {
	rt, request, err := l.openNativeHistory(native, cwd)
	if err != nil {
		return nil, err
	}
	defer rt.Close()
	sessions := agentacp.New(rt)
	request.Limit = 128
	var events []service.ConsoleEvent
	sequence, bytes := 0, 0
	for {
		page, err := sessions.ReadHistory(ctx, request)
		if err != nil {
			return nil, err
		}
		for _, obs := range page.Observations {
			event := service.ConsoleEvent{}
			switch {
			case obs.GetText() != nil:
				event.Kind, event.Text = "text", obs.GetText().GetText()
				if obs.GetText().Speaker == model.Speaker_SPEAKER_USER {
					event.Kind = "user"
				}
			case obs.GetTool() != nil:
				tool := obs.GetTool()
				event.Kind, event.ToolID, event.Name, event.Text = "tool_call", tool.CallId, tool.Name, tool.Summary
				if tool.Phase == "completed" || tool.Phase == "failed" {
					event.Kind = "tool_result"
				}
			case obs.GetInput() != nil:
				event.Kind, event.Text = "text", "Past request: "+obs.GetInput().Prompt
			case obs.GetGap() != nil:
				event.Kind, event.Text = "text", obs.GetGap().Reason
			default:
				continue
			}
			event.Text = consoleText(event.Text)
			if len(event.Text) > 16<<10 {
				end := 16 << 10
				for !utf8.RuneStart(event.Text[end]) {
					end--
				}
				event.Text = event.Text[:end] + "\n[Output shortened]"
			}
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
		if page.NextCursor == "" {
			return events, nil
		}
		if page.NextCursor == request.Cursor {
			return nil, errors.New("native history cursor did not advance")
		}
		request.Cursor = page.NextCursor
	}
}

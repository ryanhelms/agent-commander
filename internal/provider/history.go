package provider

import (
	"context"
	"errors"
	"strings"
	"unicode/utf8"

	agentacp "agent-acp.local/sdks/go"
	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/nativehistory"
	"agent-acp.local/sdks/go/runtime"

	"agentcommander/internal/service"
)

// ReadConsoleHistory binds the persisted handle to its provider's passive
// reader. Historical permissions are text only. Only live requests are actionable.
func (*Local) ReadConsoleHistory(ctx context.Context, native service.NativeSession, cwd string) ([]service.ConsoleEvent, error) {
	name, local := strings.CutPrefix(native.HarnessInstance, "local-")
	reader := nativehistory.ForHarness(name, cwd)
	if !local || reader == nil {
		return nil, errors.New("native history is unavailable for this harness")
	}
	rt, err := runtime.New(runtime.Config{HarnessInstance: native.HarnessInstance, WorkingDirectory: cwd, ReadHistory: reader})
	if err != nil {
		return nil, err
	}
	defer rt.Close()
	sessions := agentacp.New(rt)
	request := &model.ReadHistoryRequest{Session: &model.SessionRef{HarnessInstance: native.HarnessInstance, SessionId: native.SessionID}, Limit: 128}
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

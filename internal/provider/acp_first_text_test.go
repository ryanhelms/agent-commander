package provider

import (
	"context"
	"testing"
	"time"

	agentacp "agent-acp.local/sdks/go"
	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"
)

func TestACPFirstStructuredTextPrecedesPromptCompletion(t *testing.T) {
	cwd := t.TempDir()
	rt, err := compiledFixture.Open(runtime.Config{HarnessInstance: compiledFixtureInstance, WorkingDirectory: cwd})
	if err != nil {
		t.Fatal(err)
	}
	defer rt.Close()
	client := agentacp.New(rt)
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	opened, err := client.Open(ctx, &model.OpenRequest{HarnessInstance: compiledFixtureInstance, WorkingDirectory: cwd})
	if err != nil {
		t.Fatal(err)
	}
	ref := opened.Session.Ref
	request := &model.SendRequest{Session: ref, OperationId: "time-to-text", Text: readerScenario.Prompt}
	source := newACPSourcePublisher()
	updates := make(chan acpUpdate, 1)
	screen := &screen{batches: make(chan outputBatch, 2)}
	done := make(chan error, 1)
	go func() {
		_, _, err := runACPTurn(ctx, client, request, source, nil, screen, "", false, nil, updates)
		done <- err
	}()
	t.Cleanup(func() {
		cancel()
		<-done
	})
	sendText := func(text string) {
		updates <- acpUpdate{event: &model.Observation{
			TurnId: request.OperationId, Session: ref,
			Event: &model.Observation_Text{Text: &model.TextUpdate{Speaker: model.Speaker_SPEAKER_ASSISTANT, Text: text}},
		}}
	}
	nextText := func(want string) {
		t.Helper()
		select {
		case batch := <-screen.batches:
			if len(batch.Events) != 1 || batch.Events[0].Kind != "text" || batch.Events[0].Text != want {
				t.Fatalf("unexpected structured text: %+v, want %q", batch.Events, want)
			}
		case <-time.After(time.Second):
			t.Fatalf("structured text %q waited for a prompt result or newline", want)
		}
	}
	sendText("first token")
	nextText("first token")
	sendText(" later token")
	nextText(" later token")
	sendText(" complete line\n")
	nextText(" complete line\n")
	sendText(" one")
	sendText(" two")
	nextText(" one two")
}

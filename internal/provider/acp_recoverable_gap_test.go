package provider

import (
	"context"
	"testing"
	"time"

	agentacp "agent-acp.local/sdks/go"
	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"
)

func TestWorkerKeepsOriginalTurnAfterVerifiedOutputGap(t *testing.T) {
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
	source := newACPSourcePublisher()
	source.activeTurn.Store(true)
	updates, done, life := workerObservations(ctx, client, ref, source, &screen{})
	defer func() { cancel(); <-done }()
	direct := rt.(*fixtureRuntime)
	direct.mu.Lock()
	session := direct.sessions[ref.SessionId]
	session.append(&model.Observation{
		SourceRecord: &model.Extension{Type: "acp.observation_only_gap", Data: []byte("{}")},
		Event:        &model.Observation_Gap{Gap: &model.HistoryGap{Reason: "output window expired"}},
	})
	// The control packet following the gap belongs to the preexisting turn.
	session.turn = "original"
	session.append(&model.Observation{
		Event: &model.Observation_TurnEnded{TurnEnded: &model.TurnEnded{Reason: "cancelled"}},
	})
	direct.mu.Unlock()

	select {
	case gap := <-updates:
		if gap.err != nil || !runtime.IsObservationOnlyGap(gap.event) {
			t.Fatalf("verified output gap closed or altered the turn: %+v", gap)
		}
	case <-ctx.Done():
		t.Fatal("verified gap did not reach the active turn")
	}
	select {
	case last := <-updates:
		if last.ended == nil || last.err != nil || last.event.GetTurnId() != "original" || last.event.GetTurnEnded().GetReason() != "cancelled" {
			t.Fatalf("original terminal evidence was unavailable after the gap: %+v", last)
		}
		close(last.ended)
	case <-ctx.Done():
		t.Fatal("turn evidence did not follow the gap")
	}
	if life.Err() != nil {
		t.Fatalf("live observer closed after verified output loss: %v", context.Cause(life))
	}
}

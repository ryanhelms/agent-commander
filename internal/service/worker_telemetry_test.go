package service

import (
	"encoding/json"
	"testing"

	"agentcommander/internal/acpprocessor"
)

func TestWorkerTelemetryRetainsLatestReportedReadings(t *testing.T) {
	worker := &Worker{ID: "selected", NativeSession: &NativeSession{SessionID: "selected-session"}}
	run := &Run{ID: "run", Workers: []*Worker{worker}}
	var projection workspaceProjection
	projection.incrementalReaders = 1
	projection.rebuild([]*Run{run})

	usage := &acpprocessor.Usage{Used: 3200, Size: 16000}
	worker.observeTelemetry(&acpprocessor.Activity{Source: "live", Kind: "usage_update", Usage: usage})
	tokens := acpprocessor.PromptResultTokens([]byte(`{"usage":{"inputTokens":0,"thoughtTokens":24}}`))
	if tokens == nil || tokens.OutputTokens != nil || tokens.InputTokens == nil || *tokens.InputTokens != 0 {
		t.Fatalf("missing and reported zero must remain distinct: %+v", tokens)
	}
	worker.observeTelemetry(&acpprocessor.Activity{Source: "live", Kind: "acp.prompt_result", TurnTokens: tokens})
	worker.observeTelemetry(&acpprocessor.Activity{Source: "provider", Kind: "usage_update", Usage: &acpprocessor.Usage{Used: 42}})
	projection.updateWorker(worker, "", nil)
	if got := worker.Telemetry; got == nil || got.Context != usage || got.TurnTokens != tokens {
		t.Fatalf("unexpected telemetry: %+v", got)
	}
	var encoded struct {
		Telemetry *WorkerTelemetry
	}
	if err := json.Unmarshal(projection.workers[worker.ID].attributes, &encoded); err != nil ||
		encoded.Telemetry == nil || encoded.Telemetry.Context == nil || encoded.Telemetry.Context.Used != 3200 ||
		encoded.Telemetry.TurnTokens == nil || encoded.Telemetry.TurnTokens.ThoughtTokens == nil ||
		*encoded.Telemetry.TurnTokens.ThoughtTokens != 24 {
		t.Fatalf("workspace projection omitted telemetry: %+v (%v)", encoded, err)
	}
	s := &service{state: database{Runs: []*Run{run}}}
	if s.durableState().Runs[0].Workers[0].Telemetry != nil || worker.Telemetry == nil {
		t.Fatal("live telemetry must stay outside durable state")
	}
}

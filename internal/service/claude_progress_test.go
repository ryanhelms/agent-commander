package service

import (
	"encoding/json"
	"testing"
)

func TestClaudeProgressKeepsTheOriginalObservationAcrossOutputBatches(t *testing.T) {
	f := newFixture(t)
	parent := f.run()
	worker := f.delegate(parent, "progress-worker")
	sibling := f.delegate(parent, "progress-sibling")
	path := "/v1/workers/" + worker.ID
	f.call("POST", path+"/native-session", "", NativeSession{"local-claude", "claude-progress"}, 200, "")
	f.call("POST", "/v1/workers/"+sibling.ID+"/native-session", "", NativeSession{"fixture", "other-progress"}, 200, "")

	readProgress := func(id string) map[string]string {
		t.Helper()
		var run struct {
			Workers []struct {
				ID       string
				Progress map[string]string `json:"claude_progress"`
			}
		}
		data := f.call("GET", "/v1/runs/"+parent.RunID+"?view=ag-ui", "", nil, 200, "")
		if err := json.Unmarshal(data, &run); err != nil {
			t.Fatal(err)
		}
		for _, current := range run.Workers {
			if current.ID == id {
				return current.Progress
			}
		}
		t.Fatalf("missing worker %s", id)
		return nil
	}
	progress := func(time, phase string) map[string]string {
		return map[string]string{"updated_at": time, "phase": phase}
	}
	batch := map[string]any{"stream_id": "progress-runner", "batch": 1, "text": "starting\n"}
	f.call("POST", path+"/output", worker.Token, batch, 200, "")
	if got := readProgress(worker.ID); got != nil {
		t.Fatalf("starting output recorded Claude progress: %v", got)
	}
	batch["batch"] = 2
	delete(batch, "text")
	const observedAt = "2026-11-24T18:02:03.123Z"
	batch["claude_progress"] = progress(observedAt, "tool_pending")
	f.call("POST", path+"/output", worker.Token, batch, 200, "")
	f.call("POST", path+"/output", worker.Token, batch, 200, "")
	if got := readProgress(worker.ID); got["phase"] != "tool_pending" || got["updated_at"] != observedAt {
		t.Fatalf("workspace lost the pending phase or its observation time: %v", got)
	}

	batch["batch"] = 3
	delete(batch, "claude_progress")
	batch["text"] = "local terminal diagnostic\n"
	f.call("POST", path+"/output", worker.Token, batch, 200, "")
	batch["batch"] = 4
	batch["claude_progress"] = progress("2026-11-24T18:02:01.345Z", "thinking")
	f.call("POST", path+"/output", worker.Token, batch, 200, "")
	if got := readProgress(worker.ID); got["phase"] != "tool_pending" || got["updated_at"] != observedAt {
		t.Fatalf("quiet output or an older observation changed progress: %v", got)
	}

	batch["batch"] = 1
	f.call("POST", "/v1/workers/"+sibling.ID+"/output", sibling.Token, batch, 200, "")
	if got := readProgress(sibling.ID); got != nil {
		t.Fatalf("non-Claude session recorded Claude progress: %v", got)
	}

	batch["batch"] = 5
	const resumedAt = "2026-11-24T18:03:05.456Z"
	batch["claude_progress"] = progress(resumedAt, "responding")
	f.call("POST", path+"/output", worker.Token, batch, 200, "")
	if got := readProgress(worker.ID); got["phase"] != "responding" || got["updated_at"] != resumedAt {
		t.Fatalf("new Claude progress failed to replace the pending phase: %v", got)
	}
}

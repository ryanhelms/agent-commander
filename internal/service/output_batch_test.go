package service

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunnerOutputReceiptsAndNativeRecovery(t *testing.T) {
	for _, native := range []bool{false, true} {
		name := "legacy"
		if native {
			name = "native"
		}
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			w := f.run()
			path := "/v1/workers/" + w.ID
			if native {
				f.call("POST", path+"/native-session", "", NativeSession{"fixture", "session-one"}, 200, "")
			}
			stateFile := filepath.Join(f.dir, "state.json")
			before, err := os.Stat(stateFile)
			if err != nil {
				t.Fatal(err)
			}
			batch := workerOutput{Stream: "runner-1", Batch: 1, Text: "first\n",
				Events: []ConsoleEvent{{Kind: "text", Text: "first"}}}
			post := func(code int) { f.call("POST", path+"/output", w.Token, batch, code, "") }
			post(200)
			post(200)
			batch.Text = "changed\n"
			post(409)
			batch.Batch = 3
			post(409)
			after, err := os.Stat(stateFile)
			if err != nil || os.SameFile(before, after) != native {
				t.Fatalf("unexpected state file replacement for %s output: %v", name, err)
			}
			readWorker := func() *Worker {
				var run Run
				if err := json.Unmarshal(f.call("GET", "/v1/runs/"+w.RunID, "", nil, 200, ""), &run); err != nil {
					t.Fatal(err)
				}
				return run.Workers[0]
			}
			if got := readWorker(); got.Output != "first\n" || len(got.Console) != 1 {
				t.Fatal("retry or out-of-order batch altered the projection", got.Console, got.Output)
			}
			f.api, err = New(f.dir, f.p)
			if err != nil {
				t.Fatal(err)
			}
			if !native {
				batch.Batch, batch.Text = 1, "first\n"
				post(200)
			}
			batch.Batch, batch.Text = 2, "second\n"
			batch.Events[0].Text = "second"
			post(200)
			got := readWorker()
			if native {
				if got.Output != "second\n" || len(got.Console) != 2 || !strings.Contains(got.Console[0].Text, "restart") {
					t.Fatal("native restart did not report the missing preview", got.Console)
				}
			} else if got.Output != "first\nsecond\n" || len(got.Console) != 2 {
				t.Fatal("durable retry duplicated or lost output", got.Console)
			}
		})
	}
}

func TestRunnerOutputRejectsRetiredStream(t *testing.T) {
	f := newFixture(t)
	w := f.run()
	path := "/v1/workers/" + w.ID + "/output"
	first := workerOutput{Stream: "a", Batch: 1, Text: "A"}
	f.call("POST", path, w.Token, first, 200, "")
	f.call("GET", path, "", nil, 403, "")
	var binding struct {
		Stream string `json:"stream_id"`
	}
	if err := json.Unmarshal(f.call("GET", path, w.Token, nil, 200, ""), &binding); err != nil || binding.Stream != "a" {
		t.Fatal(binding, err)
	}
	second := workerOutput{Stream: "b", Batch: 1, Replaces: binding.Stream, Text: "B"}
	f.call("POST", path, w.Token, second, 200, "")
	f.call("POST", path, w.Token, first, 409, "")
	second.Batch, second.Replaces, second.Text = 2, "", "C"
	f.call("POST", path, w.Token, second, 200, "")
}

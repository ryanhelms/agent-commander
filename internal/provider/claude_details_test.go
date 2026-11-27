package provider

import (
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"agentcommander/internal/service"
)

func TestClaudeJobAndTurnRecords(t *testing.T) {
	file, err := os.Open("testdata/claude-jobs.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	s := &screen{}
	if err := render(file, s); err != nil {
		t.Fatal(err)
	}
	var shell, agent, turns []service.ToolDetail
	var thought service.ToolDetail
	for _, d := range s.details {
		switch d.Key {
		case "job-shell":
			shell = append(shell, d)
		case "job-agent":
			agent = append(agent, d)
		default:
			switch d.Kind {
			case "turn_end":
				turns = append(turns, d)
			case "thought":
				thought = d
			}
		}
	}
	if len(shell) != 3 || shell[0].JobKind != "command" || shell[0].ToolUseID != "shell" || shell[0].Title != "Check sample" ||
		shell[0].State != "running" || shell[0].EndedAt != "" || shell[0].StartedAt == "" {
		t.Fatalf("command records: %+v", shell)
	}
	for _, d := range shell[1:] {
		if d.State != "completed" || d.EndedAt != "2026-01-02T03:04:07Z" || d.StartedAt != shell[0].StartedAt {
			t.Fatalf("command end: %+v", d)
		}
	}
	if shell[2].Result != `Background command "Check sample" completed (exit code 0)` {
		t.Fatal(shell[2].Result)
	}
	if len(agent) != 6 {
		t.Fatalf("got %d agent snapshots", len(agent))
	}
	for i, want := range []struct{ state, name, arg string }{
		{"running", "", ""}, {"running", "Read", "sample.go"}, {"running", "Grep", "sample"},
		{"running", "Read", "sample.go"}, {"running", "", ""}, {"unknown", "", ""},
	} {
		d := agent[i]
		if d.Kind != "job" || d.ToolUseID != "agent" || d.Title != "Inspect sample" || d.JobKind != "agent" ||
			d.StartedAt == "" || d.EndedAt != "" || d.State != want.state || d.OpenToolName != want.name || d.OpenToolArg != want.arg {
			t.Fatalf("agent snapshot %d: %+v, %+v", i, d, d.JobDetail)
		}
	}
	if len(turns) != 2 || turns[0].Key == turns[1].Key || turns[0].StopReason != "end_turn" || turns[0].TerminalReason != "completed" ||
		turns[0].DurationMS == nil || *turns[0].DurationMS != 5320 || turns[1].DurationMS == nil || *turns[1].DurationMS != 9 ||
		turns[0].IsError == nil || *turns[0].IsError || turns[1].StopReason != "" || turns[1].TerminalReason != "" {
		t.Fatalf("turns: %+v", turns)
	}
	if thought.StartedAt != "2026-01-02T03:04:05.733Z" || thought.EndedAt != "2026-01-02T03:04:06.79Z" || thought.Result != "" {
		t.Fatalf("timed, empty thought: %+v", thought)
	}
	var prose []string
	for _, e := range s.events {
		if e.Kind == "text" {
			prose = append(prose, e.Text)
		}
	}
	if len(s.events) != 9 || !reflect.DeepEqual(prose, []string{"Child prose.", "Done."}) || *turns[0].Event != len(s.events)-1 {
		t.Fatalf("console or turn position changed: %+v", s.events)
	}
}

func TestClaudeUnfinishedJob(t *testing.T) {
	const start = `{"type":"system","subtype":"task_started","task_id":"t","tool_use_id":"b","description":"Check","task_type":"local_bash","is_backgrounded":true}`
	for _, tc := range []struct {
		name, tail, state string
		wantErr           bool
	}{
		{"EOF", "", "unknown", true},
		{"malformed", "broken", "unknown", true},
		{"turn failure", `{"type":"result","is_error":true}`, "unknown", true},
		{"clean exit", `{"type":"result","is_error":false}`, "unknown", false},
		{"wrong tool", `{"type":"system","subtype":"task_notification","task_id":"t","tool_use_id":"other","status":"completed"}`, "unknown", true},
		{"wrong task", `{"type":"system","subtype":"task_updated","task_id":"other","patch":{"status":"completed"}}`, "unknown", true},
		{"notification", `{"type":"system","subtype":"task_notification","task_id":"t","tool_use_id":"b","status":"completed","summary":"done"}`, "completed", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := &screen{}
			err := render(strings.NewReader(start+"\n"+tc.tail), s)
			if (err != nil) != tc.wantErr || len(s.events) != 0 {
				t.Fatalf("err %v; console %+v", err, s.events)
			}
			var job service.ToolDetail
			for _, d := range s.details {
				if d.Kind == "job" {
					job = d
				}
			}
			if job.JobDetail == nil || job.State != tc.state || (job.EndedAt == "") != (tc.state == "unknown") {
				t.Fatalf("last job: %+v", job)
			}
			if tc.state == "completed" {
				if _, err := time.Parse(time.RFC3339Nano, job.EndedAt); err != nil || job.Result != "done" {
					t.Fatalf("notification: %+v", job)
				}
			}
		})
	}
}

func TestClaudeThoughtTiming(t *testing.T) {
	for _, tc := range []struct {
		name, meta, start, end string
	}{
		{"zero duration", `"timestamp":"2026-01-02T03:04:06Z","thinking_duration_ms":0`, "2026-01-02T03:04:06Z", "2026-01-02T03:04:06Z"},
		{"no timestamp", `"thinking_duration_ms":20`, "", ""},
		{"invalid timestamp", `"timestamp":"unknown","thinking_duration_ms":20`, "", ""},
		{"no duration", `"timestamp":"2026-01-02T03:04:06Z"`, "", ""},
		{"negative duration", `"timestamp":"2026-01-02T03:04:06Z","thinking_duration_ms":-20`, "", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := &screen{}
			claudeThought([]byte("{"+tc.meta+"}"), "some text", s)
			if len(s.details) != 1 || s.details[0].Result != "some text" || s.details[0].StartedAt != tc.start || s.details[0].EndedAt != tc.end {
				t.Fatalf("thought: %+v", s.details)
			}
		})
	}
}

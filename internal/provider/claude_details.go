package provider

import (
	"encoding/json"
	"math"
	"slices"
	"strings"
	"time"

	"agentcommander/internal/service"
)

// These envelopes add only owner-local details. Decode their optional metadata
// separately so a provider format change cannot suppress existing Console text.
func claudeThought(raw []byte, text string, s *screen) {
	var meta struct {
		Timestamp string `json:"timestamp"`
		Duration  *int64 `json:"thinking_duration_ms"`
	}
	d := service.ToolDetail{Kind: "thought", Result: text}
	if json.Unmarshal(raw, &meta) == nil && meta.Duration != nil && *meta.Duration >= 0 && *meta.Duration <= math.MaxInt64/int64(time.Millisecond) {
		if end, err := time.Parse(time.RFC3339Nano, meta.Timestamp); err == nil {
			d.EndedAt = end.UTC().Format(time.RFC3339Nano)
			d.StartedAt = end.Add(-time.Duration(*meta.Duration) * time.Millisecond).UTC().Format(time.RFC3339Nano)
		}
	}
	if text != "" || d.EndedAt != "" {
		d.Key = "thought-" + newSessionID()
		s.recordDetail(d)
	}
}

func claudeTurnEnd(raw []byte, s *screen) {
	var result struct {
		UUID string `json:"uuid"`
		service.TurnEndDetail
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		// A mismatched optional value can leave a pointer to its zero value.
		result.TurnEndDetail = service.TurnEndDetail{}
	}
	if result.UUID == "" {
		result.UUID = newSessionID()
	}
	result.StopReason = previewPrefix(result.StopReason, 256)
	result.TerminalReason = previewPrefix(result.TerminalReason, 256)
	s.recordDetail(service.ToolDetail{Kind: "turn_end", Key: "turn-end-" + result.UUID, TurnEndDetail: &result.TurnEndDetail})
}

// A single agent can issue several calls before receiving their results.
const maxOpenCallsPerAgent = 16

type claudeOpenCall struct {
	id, name, arg string
}

type claudeJob struct {
	taskID, title, start, end string
	job                       service.JobDetail
	calls                     []claudeOpenCall
}

// Keep the task_id from task_started for updates, which omit tool_use_id.
// Completed jobs can still receive a summary or a more precise end time.
type claudeJobs []*claudeJob

func (j *claudeJob) record(s *screen, summary string) {
	d := j.job
	if i := len(j.calls) - 1; i >= 0 && d.State == "running" {
		d.OpenToolName, d.OpenToolArg = j.calls[i].name, j.calls[i].arg
	}
	s.recordDetail(service.ToolDetail{Kind: "job", Key: "job-" + d.ToolUseID, JobDetail: &d,
		Title: j.title, StartedAt: j.start, EndedAt: j.end, Result: summary})
}

func (j *claudeJob) loseContact(s *screen) {
	if j.job.State == "running" {
		j.job.State = "unknown"
		j.record(s, "")
	}
}

func (jobs *claudeJobs) finish(s *screen) {
	for _, j := range *jobs {
		j.loseContact(s)
	}
}

func (jobs *claudeJobs) task(subtype string, raw []byte, s *screen) {
	switch subtype {
	case "task_started", "task_updated", "task_notification":
	default:
		return
	}
	var event struct {
		TaskID                       string `json:"task_id"`
		ToolUseID                    string `json:"tool_use_id"`
		Type                         string `json:"task_type"`
		Background                   bool   `json:"is_backgrounded"`
		Description, Status, Summary string
		Patch                        struct {
			Status  string
			EndTime int64 `json:"end_time"`
		}
	}
	if json.Unmarshal(raw, &event) != nil || event.TaskID == "" || len(event.TaskID) > 256 {
		return
	}
	id := consoleToolID(event.ToolUseID)
	index := slices.IndexFunc(*jobs, func(j *claudeJob) bool { return event.TaskID == j.taskID })
	if subtype == "task_started" {
		if id == "" || index >= 0 {
			return
		}
		var kind string
		switch {
		case event.Type == "local_agent":
			kind = "agent"
		case event.Type == "local_bash" && event.Background:
			kind = "command"
		default:
			return
		}
		if len(*jobs) == service.MaxToolDetailRecords {
			i := slices.IndexFunc(*jobs, func(j *claudeJob) bool { return j.job.State != "running" })
			if i < 0 {
				i = 0
				(*jobs)[i].loseContact(s)
			}
			*jobs = slices.Delete(*jobs, i, i+1)
		}
		j := &claudeJob{taskID: event.TaskID, title: strings.Clone(previewPrefix(event.Description, 4096)), start: detailNow(),
			job: service.JobDetail{ToolUseID: id, JobKind: kind, State: "running"}}
		*jobs = append(*jobs, j)
		j.record(s, "")
		return
	}
	if index < 0 {
		return
	}
	j := (*jobs)[index]
	if id != "" && id != j.job.ToolUseID {
		return
	}
	status := event.Status
	if subtype == "task_updated" {
		status = event.Patch.Status
	}
	switch status {
	case "completed", "failed", "stopped":
		j.job.State = status
	case "", "running":
		return
	default:
		// A new status word alone is not evidence that a job ended.
		if subtype != "task_notification" && event.Patch.EndTime == 0 {
			return
		}
		j.job.State = "unknown"
	}
	if event.Patch.EndTime > 0 {
		j.end = time.UnixMilli(event.Patch.EndTime).UTC().Format(time.RFC3339Nano)
	} else if j.end == "" {
		j.end = detailNow()
	}
	j.calls = nil
	j.record(s, event.Summary)
}

func (jobs claudeJobs) child(parent string, b contentBlock, s *screen) {
	if parent == "" {
		return
	}
	parent = consoleToolID(parent)
	for _, j := range jobs {
		if j.job.ToolUseID != parent || j.job.JobKind != "agent" || j.job.State != "running" {
			continue
		}
		if b.Type == "tool_use" && b.ID != "" {
			var input struct{ Command, Description string }
			_ = json.Unmarshal(b.Input.raw, &input)
			arg := ""
			for _, v := range []string{b.Input.FilePath, b.Input.Pattern, input.Command, b.Input.Question, b.Input.Name, input.Description} {
				if v != "" {
					arg = strings.Clone(previewPrefix(v, 512))
					break
				}
			}
			id := consoleToolID(b.ID)
			// Redelivery replaces the same open call.
			j.calls = slices.DeleteFunc(j.calls, func(c claudeOpenCall) bool { return c.id == id })
			if len(j.calls) == maxOpenCallsPerAgent {
				j.calls = slices.Delete(j.calls, 0, 1)
			}
			j.calls = append(j.calls, claudeOpenCall{id, strings.Clone(previewPrefix(b.Name, 256)), arg})
		} else if b.Type == "tool_result" {
			id := consoleToolID(b.ToolUseID)
			i := slices.IndexFunc(j.calls, func(c claudeOpenCall) bool { return c.id == id })
			if i < 0 {
				return
			}
			j.calls = slices.Delete(j.calls, i, i+1)
		} else {
			return
		}
		j.record(s, "")
		return
	}
}

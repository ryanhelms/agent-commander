package service

import "time"

const LocalClaudeHarness = "local-claude"

// ClaudeProgress is the latest meaningful observation from a live local ACP
// turn. The runner stamps the observation before publishing its console batch.
type ClaudeProgress struct {
	UpdatedAt time.Time `json:"updated_at"`
	Phase     string    `json:"phase"`
}

func (p *ClaudeProgress) valid() bool {
	if p == nil {
		return true
	}
	if p.UpdatedAt.IsZero() {
		return false
	}
	switch p.Phase {
	case "responding", "thinking", "tool_pending", "tool_running", "tool_completed", "tool_failed",
		"tool_cancelled", "tool_reported", "permission_requested", "turn_completed", "turn_interrupted",
		"turn_failed", "turn_ended":
		return true
	default:
		return false
	}
}

func (w *Worker) observeClaudeProgress(progress *ClaudeProgress) {
	if progress == nil || !w.isLocalClaudeWorker() {
		return
	}
	if w.ClaudeProgress == nil || !progress.UpdatedAt.Before(w.ClaudeProgress.UpdatedAt) {
		w.ClaudeProgress = progress
	}
}

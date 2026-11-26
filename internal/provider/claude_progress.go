package provider

import (
	"time"

	model "agent-acp.local/sdks/go/model"
	"agentcommander/internal/acpprocessor"
	"agentcommander/internal/service"
)

func (s *screen) recordClaudeProgress(phase string) {
	if phase == "" {
		return
	}
	observed := &service.ClaudeProgress{UpdatedAt: time.Now().UTC(), Phase: phase}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.closed {
		s.claudeProgress = observed
	}
}

func claudeProgressPhase(observation *model.Observation) string {
	switch {
	case observation.GetText().GetSpeaker() == model.Speaker_SPEAKER_ASSISTANT && observation.GetText().GetText() != "":
		return "responding"
	case observation.GetTool() != nil:
		switch observation.GetTool().GetPhase() {
		case "pending":
			return "tool_pending"
		case "in_progress":
			return "tool_running"
		case "completed":
			return "tool_completed"
		case "failed":
			return "tool_failed"
		case "declined", "cancelled", "interrupted":
			return "tool_cancelled"
		default:
			return "tool_reported"
		}
	case observation.GetInput() != nil:
		return "permission_requested"
	case observation.GetTurnEnded() != nil:
		switch observation.GetSourceRecord().GetType() {
		case "acp.prompt_error":
			return "turn_failed"
		case "acp.prompt_result":
			switch observation.GetTurnEnded().GetReason() {
			case "end_turn":
				return "turn_completed"
			case "cancelled":
				return "turn_interrupted"
			default:
				return "turn_ended"
			}
		}
	case observation.GetContent() != nil:
		if observation.GetContent().GetThought() {
			return "thinking"
		}
	case observation.GetExtension() != nil:
		if update, ok := acpprocessor.ExtensionUpdate(observation.GetExtension()); ok &&
			update.Disposition == "decoded" && update.Value.AgentThoughtChunk != nil {
			return "thinking"
		}
	}
	return ""
}

package service

import "agentcommander/internal/acpprocessor"

// WorkerTelemetry keeps the most recently reported readings independently of
// the bounded transcript. The original ACP records stay in the scoped source.
type WorkerTelemetry struct {
	Context    *acpprocessor.Usage      `json:"context,omitempty"`
	TurnTokens *acpprocessor.TokenUsage `json:"turnTokens,omitempty"`
}

func (w *Worker) observeTelemetry(activity *acpprocessor.Activity) {
	if w.NativeSession == nil || activity == nil || activity.Source != "live" {
		return
	}
	context := activity.Usage
	tokens := activity.TurnTokens
	hasContext := activity.Kind == "usage_update" && context != nil && context.Used >= 0 && context.Size >= 0
	hasTokens := activity.Kind == "acp.prompt_result" && tokens != nil
	if !hasContext && !hasTokens {
		return
	}
	var next WorkerTelemetry
	if w.Telemetry != nil {
		next = *w.Telemetry
	}
	if hasContext {
		next.Context = context
	}
	if hasTokens {
		next.TurnTokens = tokens
	}
	w.Telemetry = &next
}

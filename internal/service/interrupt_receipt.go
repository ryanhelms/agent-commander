package service

import "net/http"

type WorkerInterrupt struct {
	ID         string `json:"id"`
	TurnID     string `json:"turn_id"`
	Generation int    `json:"generation"`
	Phase      string `json:"phase"`
	Outcome    string `json:"outcome,omitempty"`
}

type interruptTarget struct {
	ID         string `json:"id"`
	TurnID     string `json:"turn_id"`
	Generation int    `json:"generation"`
}

func (receipt *WorkerInterrupt) matches(target interruptTarget) bool {
	return receipt != nil && receipt.ID == target.ID && receipt.TurnID == target.TurnID &&
		receipt.Generation == target.Generation
}

func (s *service) reportWorkerInterrupt(req *http.Request, actor string) (outcome, error) {
	_, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	var report struct {
		interruptTarget
		Phase string `json:"phase"`
	}
	if err := decode(req, &report); err != nil {
		return outcome{}, err
	}
	if report.Phase != "sent" && report.Phase != "unconfirmed" {
		return outcome{}, bad("invalid interrupt dispatch report")
	}
	if w.Control == nil || !w.Control.Interrupt.matches(report.interruptTarget) {
		return outcome{}, conflict("interrupt report does not match the original request")
	}
	receipt := w.Control.Interrupt
	if receipt.Phase == report.Phase {
		return read(w.Control), nil
	}
	if receipt.Phase != "claimed" {
		return outcome{}, conflict("interrupt dispatch has not been claimed")
	}
	receipt.Phase = report.Phase
	return changed(w.Control), nil
}

// closeInterrupt records what was known when the inbox stopped. A request that
// never made it to its runner was cancelled; a claimed request is uncertain.
func (c *WorkerControl) closeInterrupt() {
	receipt := c.Interrupt
	if receipt == nil || receipt.Outcome != "" {
		return
	}
	if receipt.Phase == "accepted" {
		receipt.Outcome = "cancelled"
	} else {
		receipt.Outcome = "unknown"
	}
}

package service

import "net/http"

const (
	providerAvailable = "available"
	providerChecking  = "checking"
	providerExited    = "exited"
)

func (w *Worker) isLocalClaudeWorker() bool {
	return w.Role == "worker" && w.NativeSession != nil && w.NativeSession.HarnessInstance == LocalClaudeHarness
}

func (s *service) reportWorkerProviderExit(req *http.Request, actor string) (outcome, error) {
	r, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	var report struct {
		NativeSession
		LastState string `json:"last_state"`
	}
	if err := decode(req, &report); err != nil {
		return outcome{}, err
	}
	if report.LastState != "completed" && report.LastState != "idle" {
		return outcome{}, bad("provider exit requires the last finished turn state")
	}
	if !w.isLocalClaudeWorker() || *w.NativeSession != report.NativeSession || w.Control == nil {
		return outcome{}, conflict("provider exit does not match the original Claude session")
	}
	if w.ProviderAvailability == providerExited {
		return read(w), nil
	}
	// A claim can reach the service just before the adapter exits, while its
	// acknowledgement never reaches the waiting runner. The last observed
	// turn is still the only known outcome, and the claim becomes uncertain.
	if w.State != report.LastState && w.State != "unknown" {
		claimPending := w.State == "working" && w.Control.hasProcessingMessage()
		if !claimPending {
			return outcome{}, conflict("worker has not finished the reported turn")
		}
	}
	w.State, w.Error = report.LastState, ""
	w.ProviderAvailability = providerExited
	w.Control.ActiveTurnID = ""
	s.stopWorkerInbox(r, w)
	r.cancelQuestions(w.ID)
	r.refreshOutcome()
	return changed(w), nil
}

func (s *service) reconcileWorkerProvider(req *http.Request, actor string) (outcome, error) {
	r, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	var report struct {
		Session    NativeSession `json:"session"`
		TurnID     string        `json:"turn_id"`
		Generation int           `json:"generation"`
	}
	if err := decode(req, &report); err != nil {
		return outcome{}, err
	}
	if !w.isLocalClaudeWorker() || *w.NativeSession != report.Session || w.Control == nil ||
		report.TurnID == "" || w.Control.ActiveTurnID != report.TurnID ||
		w.Control.Generation != report.Generation || r.Status != "running" {
		return outcome{}, conflict("recovery does not match the original Claude turn and control generation")
	}
	if w.ProviderAvailability == providerAvailable && turnActive(w.State) {
		return read(w), nil
	}
	if w.ProviderAvailability != providerChecking || w.State != "unknown" {
		return outcome{}, conflict("this worker is not waiting to recover an active turn")
	}
	w.ProviderAvailability = providerAvailable
	w.State, w.Error = "working", ""
	return changed(w), nil
}

func (w *Worker) providerBlocksControl() bool {
	return w.ProviderAvailability == providerExited || w.ProviderAvailability == providerChecking || w.ProviderAvailability == providerReattaching
}

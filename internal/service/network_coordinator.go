package service

import "net/http"

// networkCoordinator runs under the same service lock and actor-token verifier
// as the local API. A connection to the owner socket alone cannot attest a run.
func (s *service) networkCoordinator(req *http.Request, actor string) (outcome, error) {
	if actor == "" || len(req.Header.Values("Authorization")) != 1 ||
		len(req.Header.Values("X-Commander-Run")) != 1 || len(req.Header.Values("X-Commander-Worker")) != 1 || actor != req.Header.Get("X-Commander-Worker") {
		return outcome{}, denied()
	}
	run, worker := s.worker(actor)
	if run == nil || worker == nil || run.ID != req.Header.Get("X-Commander-Run") || run.Status != "running" || run.CoordinatorID != actor || worker.Role != "coordinator" {
		return outcome{}, denied()
	}
	switch worker.State {
	case "starting", "working", "waiting", "idle":
		return read(map[string]string{"run": run.ID, "worker": worker.ID}), nil
	default:
		return outcome{}, denied()
	}
}

package service

import "net/http"

func (s *service) workerSSHLink(req *http.Request, actor string) (outcome, error) {
	if actor != "" {
		return outcome{}, denied()
	}
	_, worker := s.worker(req.PathValue("worker"))
	if worker == nil {
		return outcome{}, missing("worker")
	}
	if worker.Host == "" || worker.Host == "localhost" {
		return outcome{}, conflict("worker has no SSH connection")
	}
	var input struct{ Connection string }
	if err := decode(req, &input); err != nil {
		return outcome{}, err
	}
	if input.Connection != "connected" && input.Connection != "reconnecting" {
		return outcome{}, bad("invalid SSH link state")
	}
	if worker.Connection == input.Connection || ended(worker.State) || worker.State == "stopping" {
		return read(worker), nil
	}
	worker.Connection = input.Connection
	return changed(worker), nil
}

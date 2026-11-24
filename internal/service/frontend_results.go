package service

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
)

type frontendResults struct {
	Worker    string         `json:"worker"`
	Operation string         `json:"operation"`
	Actor     string         `json:"actor"`
	Calls     []frontendCall `json:"calls"`
}

func (s *service) frontendResultPath(operation string) string {
	return filepath.Join(filepath.Dir(s.path), "frontend-results", digest(operation)+".json")
}

// saveFrontendResult runs with the state lock held. Keep the original
// invocation order and only publish calls whose results have been accepted.
func (s *service) saveFrontendResult(worker string, round *frontendRound, accepted frontendCall) error {
	path := s.frontendResultPath(round.operation)
	record := frontendResults{Worker: worker, Operation: round.operation, Actor: round.actor}
	for _, call := range round.calls {
		if call.ID == accepted.ID {
			call = accepted
		}
		if call.Result != nil {
			record.Calls = append(record.Calls, call)
		}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	return writeStateJSON(path, record)
}

func (s *service) savedFrontendResults(worker, operation, actor string) ([]frontendCall, error) {
	file, err := os.Open(s.frontendResultPath(operation))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()
	// Each turn has at most eight calls. Allow for JSON escaping at the
	// existing argument and result size limits.
	const maxBytes = 3 << 20
	data, err := io.ReadAll(io.LimitReader(file, maxBytes+1))
	if err != nil {
		return nil, err
	}
	var record frontendResults
	if len(data) > maxBytes || json.Unmarshal(data, &record) != nil || record.Operation != operation || len(record.Calls) > 8 {
		return nil, errors.New("invalid frontend result record")
	}
	if record.Worker != worker || record.Actor != actor {
		return nil, nil
	}
	for _, call := range record.Calls {
		if call.Result == nil || call.ID == "" || call.Result.ToolCallID != call.ID {
			return nil, errors.New("invalid frontend call receipt")
		}
	}
	return record.Calls, nil
}

package service

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
)

type workerOutput struct {
	Stream         string          `json:"stream_id"`
	Replaces       string          `json:"replaces_stream_id,omitempty"`
	Batch          uint64          `json:"batch"`
	Text           string          `json:"text"`
	Events         []ConsoleEvent  `json:"events"`
	ClaudeProgress *ClaudeProgress `json:"claude_progress,omitempty"`
	// Details never enter the console; see tool_details.go.
	Details []ToolDetail `json:"details,omitempty"`
}

type outputReceipt struct {
	Stream string `json:"stream"`
	Batch  uint64 `json:"batch"`
	Hash   string `json:"sha256"`
}

func (in *workerOutput) receipt(req *http.Request) outputReceipt {
	if in.Stream == "" {
		return outputReceipt{}
	}
	body, _ := req.Context().Value(bodyKey{}).([]byte)
	sum := sha256.Sum256(body)
	return outputReceipt{Stream: in.Stream, Batch: in.Batch, Hash: hex.EncodeToString(sum[:])}
}

// A runner has one outstanding upload. An identical retry after a lost HTTP
// acknowledgement recovers its receipt without appending the batch twice.
func (s *service) lastOutputReceipt(w *Worker) outputReceipt {
	previous := s.state.OutputBatches[w.ID]
	if w.NativeSession != nil {
		if live, ok := s.liveOutputBatches[w.ID]; ok {
			previous = live
		}
	}
	return previous
}

func (s *service) outputStream(req *http.Request, actor string) (outcome, error) {
	_, w, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	return read(map[string]string{"stream_id": s.lastOutputReceipt(w).Stream}), nil
}

func (s *service) checkOutputBatch(req *http.Request, w *Worker, in *workerOutput) (outputReceipt, bool, error) {
	previous := s.lastOutputReceipt(w)
	if (in.Stream == "") != (in.Batch == 0) || len(in.Stream) > 128 ||
		len(in.Replaces) > 128 || (in.Replaces != "" && in.Batch != 1) {
		return previous, false, bad("invalid runner output stream or batch")
	}
	if previous.Stream == "" && in.Batch > 1 && w.NativeSession == nil {
		return previous, false, conflict("the first runner output batch must be one")
	}
	if in.Stream == "" || previous.Stream == "" {
		return previous, false, nil
	}
	if previous.Stream != in.Stream {
		if in.Batch != 1 || in.Replaces != previous.Stream {
			return previous, false, conflict("runner output stream changed before its first batch")
		}
	} else if in.Batch == previous.Batch && in.receipt(req).Hash == previous.Hash {
		return previous, true, nil
	} else if in.Batch <= previous.Batch || in.Batch-previous.Batch != 1 {
		return previous, false, conflict("runner output batch is out of order or differs from its receipt")
	}
	return previous, false, nil
}

package service

import (
	"net/http"
	"strconv"
	"time"

	model "agent-acp.local/sdks/go/model"
	"agentcommander/internal/acpprocessor"
	"agentcommander/internal/hosted"
	"google.golang.org/protobuf/encoding/protojson"
)

type sourceWake struct {
	changed chan struct{}
	readers int
}

func (s *liveSourceStore) wait(worker string) *sourceWake {
	if s.waiters == nil {
		s.waiters = make(map[string]*sourceWake)
	}
	wake := s.waiters[worker]
	if wake == nil {
		wake = &sourceWake{changed: make(chan struct{})}
		s.waiters[worker] = wake
	}
	wake.readers++
	return wake
}

func (s *liveSourceStore) release(worker string, wake *sourceWake) {
	wake.readers--
	if wake.readers == 0 && s.waiters[worker] == wake {
		delete(s.waiters, worker)
	}
}

func (s *liveSourceStore) wake(worker string) {
	if wake := s.waiters[worker]; wake != nil {
		delete(s.waiters, worker)
		close(wake.changed)
	}
}

// tail uses the history reader's epoch and position to preserve the same expiry
// behavior. The final page still carries a checkpoint for a future arrival.
func (s *liveSourceStore) tail(worker string, ref NativeSession, cursor string) (*model.ReadHistoryResponse, string, error) {
	window := s.windows[worker]
	if window == nil && cursor == "" {
		return nil, "", nil
	}
	page, err := s.page(worker, ref, "", "", cursor, LiveSourceBatchRecords)
	if err != nil || window == nil {
		return page, "", err
	}
	checkpoint := page.NextCursor
	if checkpoint == "" {
		checkpoint = worker + "." + window.epoch + "." + strconv.FormatUint(window.removed+uint64(len(window.records)), 10)
	}
	return page, checkpoint, nil
}

func (s *service) streamLiveSource(w http.ResponseWriter, req *http.Request) {
	if _, hasToken := req.Header["Authorization"]; hasToken {
		respondError(w, denied())
		return
	}
	if access := hosted.From(req.Context()); access != nil && !access.Allowed() {
		respondError(w, denied())
		return
	}
	cursor := req.URL.Query().Get("after")
	if last := req.Header.Get("Last-Event-ID"); last != "" {
		// EventSource retains the original URL across reconnects. Its last
		// committed event is the more recent checkpoint.
		cursor = last
	}
	if len(cursor) > acpprocessor.ProviderCursorLimit {
		respondError(w, bad("live source cursor exceeds size limit"))
		return
	}
	workerID := req.PathValue("worker")
	s.mu.Lock()
	_, worker := s.worker(workerID)
	if worker == nil {
		s.mu.Unlock()
		respondError(w, missing("worker"))
		return
	}
	if worker.NativeSession == nil {
		s.mu.Unlock()
		respondError(w, &apiError{http.StatusNotImplemented, "worker has no native source binding"})
		return
	}
	ref := *worker.NativeSession
	page, checkpoint, err := s.liveSource.tail(workerID, ref, cursor)
	s.mu.Unlock()
	if err != nil {
		respondError(w, err)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store, no-transform")
	controller := http.NewResponseController(w)
	write := func(frame []byte) error {
		_ = controller.SetWriteDeadline(time.Now().Add(8 * time.Second))
		if _, err := w.Write(frame); err != nil {
			return err
		}
		return controller.Flush()
	}
	if write([]byte(": live ACP source\n\n")) != nil {
		return
	}
	heartbeat := time.NewTicker(5 * time.Second)
	defer heartbeat.Stop()
	marshal := protojson.MarshalOptions{EmitDefaultValues: true}
	for {
		if access := hosted.From(req.Context()); access != nil && !access.Allowed() {
			return
		}
		if page != nil && len(page.GetObservations()) != 0 {
			data, err := marshal.Marshal(page)
			if err != nil {
				return
			}
			frame := append([]byte("id: "+checkpoint+"\nevent: page\ndata: "), data...)
			if write(append(frame, '\n', '\n')) != nil {
				return
			}
		}
		cursor = checkpoint
		s.mu.Lock()
		_, current := s.worker(workerID)
		if current == nil || current.NativeSession == nil || *current.NativeSession != ref {
			s.mu.Unlock()
			return
		}
		page, checkpoint, err = s.liveSource.tail(workerID, ref, cursor)
		if err != nil {
			s.mu.Unlock()
			return
		}
		if len(page.GetObservations()) != 0 {
			s.mu.Unlock()
			continue
		}
		wakeup := s.liveSource.wait(workerID)
		s.mu.Unlock()
		ping, stop := false, false
		select {
		case <-wakeup.changed:
		case <-heartbeat.C:
			ping = true
		case <-req.Context().Done():
			stop = true
		}
		s.mu.Lock()
		s.liveSource.release(workerID, wakeup)
		_, current = s.worker(workerID)
		if current == nil || current.NativeSession == nil || *current.NativeSession != ref {
			s.mu.Unlock()
			return
		}
		page, checkpoint, err = s.liveSource.tail(workerID, ref, cursor)
		s.mu.Unlock()
		if stop || err != nil || ping && write([]byte(": heartbeat\n\n")) != nil {
			return
		}
	}
}

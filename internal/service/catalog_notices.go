package service

import (
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"time"

	"agentcommander/internal/catalog"
	"agentcommander/internal/hosted"
)

// Refreshes can run while Commander is closed or in another process using
// the same state directory. The local stream observes the committed pins.
func (s *service) streamCatalogNotices(w http.ResponseWriter, r *http.Request) {
	if _, supplied := r.Header["Authorization"]; supplied || hosted.From(r.Context()) != nil {
		respondError(w, denied())
		return
	}
	state := filepath.Dir(s.path)
	dir := filepath.Join(state, "catalog", "pins")
	control := http.NewResponseController(w)
	write := func(frame []byte) error {
		_ = control.SetWriteDeadline(time.Now().Add(8 * time.Second))
		if _, err := w.Write(frame); err != nil {
			return err
		}
		return control.Flush()
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	var sent []catalog.Notice
	var last os.FileInfo
	refresh := func(force bool) error {
		info, err := os.Stat(dir)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		// Pin writes use atomic rename. A periodically forced read also
		// covers filesystems with coarse directory modification times.
		if !force && (last == nil && info == nil || last != nil && info != nil && os.SameFile(last, info) && last.ModTime().Equal(info.ModTime())) {
			return nil
		}
		notices, err := catalog.RefreshNotices(state)
		if err != nil {
			return err
		}
		last = info
		if sent != nil && slices.Equal(sent, notices) {
			return nil
		}
		frame, err := json.Marshal(struct {
			Updates []catalog.Notice `json:"updates"`
		}{notices})
		if err != nil {
			return err
		}
		sent = notices
		return write(append(append([]byte("data: "), frame...), '\n', '\n'))
	}
	if err := refresh(true); err != nil {
		if sent == nil {
			respondError(w, &apiError{http.StatusServiceUnavailable, "catalog notices are unavailable"})
		}
		return
	}
	poll := time.NewTicker(time.Second)
	defer poll.Stop()
	heartbeat := time.NewTicker(10 * time.Second)
	defer heartbeat.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-poll.C:
			if refresh(false) != nil {
				return
			}
		case <-heartbeat.C:
			if refresh(true) != nil || write([]byte(": heartbeat\n\n")) != nil {
				return
			}
		}
	}
}

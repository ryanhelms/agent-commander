package service

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sync"
	"time"

	"agentcommander/internal/harness"
	"agentcommander/internal/hosted"
)

// The harness routes serve the owner's cockpit only. They do not take the shared
// state lock, because a probe runs the harness's own commands.
type harnessRoutes struct {
	stateDir string
	launcher Launcher
	once     sync.Once
	monitor  *harness.Monitor
	err      error
}

func (h *harnessRoutes) get() (*harness.Monitor, error) {
	h.once.Do(func() {
		h.monitor, h.err = harness.NewMonitor(h.stateDir, harness.DefaultEnv())
		if launcher, ok := h.launcher.(interface{ CheckClient(string) error }); ok && h.err == nil {
			h.monitor.SetRunCheck(launcher.CheckClient)
		}
	})
	return h.monitor, h.err
}

func (h *harnessRoutes) register(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/harnesses", h.owner(h.list))
	mux.HandleFunc("GET /v1/harnesses/events", h.owner(h.stream))
	mux.HandleFunc("POST /v1/harnesses/{id}/check", h.owner(h.check))
	mux.HandleFunc("POST /v1/harnesses/{id}/login", h.owner(h.session((*harness.Monitor).Login)))
	mux.HandleFunc("POST /v1/harnesses/{id}/install", h.owner(h.session((*harness.Monitor).Install)))
	mux.HandleFunc("PUT /v1/harnesses/{id}/settings", h.owner(h.settings))
}

func (h *harnessRoutes) owner(next func(http.ResponseWriter, *http.Request, *harness.Monitor)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if _, supplied := r.Header["Authorization"]; supplied || hosted.From(r.Context()) != nil {
			respondError(w, denied())
			return
		}
		m, err := h.get()
		if err != nil {
			respondError(w, &apiError{http.StatusServiceUnavailable, "harness status is unavailable: " + err.Error()})
			return
		}
		next(w, r, m)
	}
}

func harnessError(err error) error {
	switch {
	case errors.Is(err, harness.ErrUnknown):
		return missing("harness")
	case errors.Is(err, harness.ErrNoCommand):
		return conflict(err.Error())
	case errors.Is(err, context.DeadlineExceeded), errors.Is(err, context.Canceled):
		return &apiError{http.StatusServiceUnavailable, "the harness check did not finish in time"}
	}
	return bad(err.Error())
}

func writeHarnessJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(v)
}

type harnessList struct {
	Harnesses []harness.Status `json:"harnesses"`
}

func (h *harnessRoutes) list(w http.ResponseWriter, r *http.Request, m *harness.Monitor) {
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	list, err := m.List(ctx)
	if err != nil {
		respondError(w, harnessError(err))
		return
	}
	writeHarnessJSON(w, harnessList{list})
}

func (h *harnessRoutes) check(w http.ResponseWriter, r *http.Request, m *harness.Monitor) {
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	status, err := m.Check(ctx, r.PathValue("id"))
	if err != nil {
		respondError(w, harnessError(err))
		return
	}
	writeHarnessJSON(w, status)
}

func (h *harnessRoutes) session(start func(*harness.Monitor, context.Context, string) (harness.Attachment, error)) func(http.ResponseWriter, *http.Request, *harness.Monitor) {
	return func(w http.ResponseWriter, r *http.Request, m *harness.Monitor) {
		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()
		attachment, err := start(m, ctx, r.PathValue("id"))
		if err != nil {
			respondError(w, harnessError(err))
			return
		}
		writeHarnessJSON(w, attachment)
	}
}

func (h *harnessRoutes) settings(w http.ResponseWriter, r *http.Request, m *harness.Monitor) {
	var body struct {
		Enabled      *bool  `json:"enabled"`
		DefaultModel string `json:"default_model"`
	}
	dec := json.NewDecoder(io.LimitReader(r.Body, 4096))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil || body.Enabled == nil {
		respondError(w, bad(`settings need {"enabled": bool, "default_model": string}`))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	status, err := m.UpdateSettings(ctx, r.PathValue("id"), harness.Settings{Enabled: *body.Enabled, DefaultModel: body.DefaultModel})
	if err != nil {
		respondError(w, harnessError(err))
		return
	}
	writeHarnessJSON(w, status)
}

func (h *harnessRoutes) stream(w http.ResponseWriter, r *http.Request, m *harness.Monitor) {
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	first, frames, done, err := m.Subscribe(ctx)
	cancel()
	if err != nil {
		respondError(w, harnessError(err))
		return
	}
	defer done()
	control := http.NewResponseController(w)
	write := func(frame []byte) error {
		_ = control.SetWriteDeadline(time.Now().Add(8 * time.Second))
		if _, err := w.Write(frame); err != nil {
			return err
		}
		return control.Flush()
	}
	send := func(list []harness.Status) error {
		raw, err := json.Marshal(harnessList{list})
		if err != nil {
			return err
		}
		return write(append(append([]byte("data: "), raw...), '\n', '\n'))
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	if send(first) != nil {
		return
	}
	heartbeat := time.NewTicker(10 * time.Second)
	defer heartbeat.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case list := <-frames:
			if send(list) != nil {
				return
			}
		case <-heartbeat.C:
			if write([]byte(": heartbeat\n\n")) != nil {
				return
			}
		}
	}
}

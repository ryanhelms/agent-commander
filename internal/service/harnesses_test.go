package service

import (
	"net/http"
	"testing"
)

func TestHarnessRoutesServeOnlyTheOwner(t *testing.T) {
	f := newFixture(t)
	worker := f.run()
	for _, route := range []struct{ method, path string }{
		{http.MethodGet, "/v1/harnesses"}, {http.MethodGet, "/v1/harnesses/events"},
		{http.MethodPost, "/v1/harnesses/claude/check"}, {http.MethodPost, "/v1/harnesses/claude/login"},
		{http.MethodPost, "/v1/harnesses/claude/install"}, {http.MethodPut, "/v1/harnesses/claude/settings"},
	} {
		f.call(route.method, route.path, worker.Token, nil, http.StatusForbidden, "")
	}
}

func TestHarnessRoutesRejectUnknownHarnessAndBadSettings(t *testing.T) {
	f := newFixture(t)
	f.call(http.MethodPost, "/v1/harnesses/nope/check", "", nil, http.StatusNotFound, "")
	f.call(http.MethodPost, "/v1/harnesses/nope/login", "", nil, http.StatusNotFound, "")
	f.call(http.MethodPut, "/v1/harnesses/claude/settings", "", map[string]any{"default_model": "opus"}, http.StatusBadRequest, "")
	f.call(http.MethodPut, "/v1/harnesses/claude/settings", "", map[string]any{"enabled": true, "extra": 1}, http.StatusBadRequest, "")
}

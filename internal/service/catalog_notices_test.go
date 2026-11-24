package service

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCatalogNoticeStreamRequiresOwnerAndReadablePins(t *testing.T) {
	f := newFixture(t)
	const path = "/v1/catalog/notices/events"
	worker := f.run()
	f.call(http.MethodGet, path, worker.Token, nil, http.StatusForbidden, "")
	dir := filepath.Join(f.dir, "catalog", "pins")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "broken.json"), []byte("{"), 0600); err != nil {
		t.Fatal(err)
	}
	body := f.call(http.MethodGet, path, "", nil, http.StatusServiceUnavailable, "")
	if !strings.Contains(string(body), "catalog notices are unavailable") || strings.Contains(string(body), f.dir) {
		t.Fatalf("unexpected initial read failure: %s", body)
	}
}

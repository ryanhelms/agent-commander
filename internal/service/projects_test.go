package service

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

func TestDirectoryProjects(t *testing.T) {
	f := newFixture(t)
	dir := t.TempDir()
	canonical, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(f.dir, "alias")
	if err := os.Symlink(dir, alias); err != nil {
		t.Fatal(err)
	}
	parseProject := func(body []byte) Project {
		t.Helper()
		var p Project
		if err := json.Unmarshal(body, &p); err != nil || p.ID == "" {
			t.Fatalf("invalid project %s: %v", body, err)
		}
		return p
	}
	open := func(path string, code int) Project {
		t.Helper()
		return parseProject(f.call("POST", "/v1/projects", "", map[string]string{"path": path}, code, ""))
	}
	p := open(dir, http.StatusCreated)
	runList := f.call("GET", "/v1/runs", "", nil, http.StatusOK, "")
	if string(runList) != "{\"runs\":[]}\n" {
		t.Fatalf("opening a folder should leave the run list empty: %s", runList)
	}
	if got := open(alias, http.StatusOK); got != p || p.Path != canonical {
		t.Fatalf("opening the same directory twice returned %+v and %+v", p, got)
	}
	neighbor := filepath.Join(t.TempDir(), filepath.Base(dir))
	if err := os.Mkdir(neighbor, 0700); err != nil {
		t.Fatal(err)
	}
	if got := open(neighbor, http.StatusCreated); got.ID == p.ID || got.Name != p.Name {
		t.Fatalf("distinct directory with the same basename returned %+v", got)
	}
	f.call("POST", "/v1/projects", "", map[string]string{"path": "relative"}, http.StatusBadRequest, "")

	payload := map[string]string{"project_id": p.ID, "task": "Plan from the saved folder"}
	created := f.call("POST", "/v1/runs", "", payload, http.StatusCreated, "project-launch")
	first := f.launched()
	if first.Path != canonical {
		t.Fatalf("coordinator launched in %q, want %q", first.Path, canonical)
	}
	retried := f.call("POST", "/v1/runs", "", payload, http.StatusOK, "project-launch")
	if string(created) != string(retried) {
		t.Fatalf("retry changed the run: %s and %s", created, retried)
	}
	f.call("POST", "/v1/runs", "", map[string]string{
		"project_id": p.ID, "path": neighbor, "task": "Mismatched project",
	}, http.StatusConflict, "")
	legacyPath := f.call("POST", "/v1/runs", "", map[string]string{
		"path": alias, "task": "Plan from the caller's directory",
	}, http.StatusCreated, "")
	second := f.launched()
	if second.Path != alias || second.RunID == first.RunID {
		t.Fatalf("path-based launch lost the caller's directory or run identity: %+v", second)
	}
	for _, body := range [][]byte{created, legacyPath} {
		var run Run
		if err := json.Unmarshal(body, &run); err != nil || run.ProjectID != p.ID {
			t.Fatalf("run was not associated with project %s: %s (%v)", p.ID, body, err)
		}
	}
	f.call("GET", "/v1/projects", first.Token, nil, http.StatusForbidden, "")
	f.call("POST", "/v1/projects", first.Token, map[string]string{"path": dir}, http.StatusForbidden, "")
	f.call("GET", "/v1/runs/"+second.RunID, first.Token, nil, http.StatusForbidden, "")

	f.api, err = New(f.dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := open(dir, http.StatusOK); got != p {
		t.Fatalf("project changed after restart: %+v, want %+v", got, p)
	}
}

func TestDirectoryProjectsRecoverLegacyHistory(t *testing.T) {
	stateDir := t.TempDir()
	missingPath := filepath.Join(stateDir, "unavailable")
	old := database{Runs: []*Run{
		{ID: "r-old-1", Path: missingPath, Project: "Historical project", Status: "stopped"},
		{ID: "r-old-2", Path: missingPath, Project: "Historical project", Status: "stopped"},
	}}
	statePath := filepath.Join(stateDir, "state.json")
	if err := writeStateJSON(statePath, old); err != nil {
		t.Fatal(err)
	}
	api, err := New(stateDir, nil)
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatal(err)
	}
	var migrated database
	if err := json.Unmarshal(data, &migrated); err != nil {
		t.Fatal(err)
	}
	if len(migrated.Projects) != 1 || migrated.Projects[0].Path != missingPath {
		t.Fatalf("expected one project at the saved path, got %+v", migrated.Projects)
	}
	p := migrated.Projects[0]
	for _, r := range migrated.Runs {
		if r.ProjectID == "" || r.ProjectID != p.ID {
			t.Fatalf("legacy run %s was not migrated to %s", r.ID, p.ID)
		}
	}
	f := fixture{t: t, api: api}
	f.call("POST", "/v1/runs", "", map[string]string{"project_id": p.ID, "task": "Plan"}, http.StatusBadRequest, "")
}

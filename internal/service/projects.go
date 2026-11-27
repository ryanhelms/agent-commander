package service

import (
	"net/http"
	"os"
	"path/filepath"

	"agentcommander/internal/hosted"
)

// Project represents one directory on the service's host. Runs retain their
// launch paths even when several path spellings resolve to this directory.
type Project struct {
	ID   string `json:"id"`
	Path string `json:"path"`
	Name string `json:"name"`
}

func existingProjectDirectory(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", bad("an absolute project path is required")
	}
	resolved, err := filepath.EvalSymlinks(filepath.Clean(path))
	if err == nil {
		if info, err := os.Stat(resolved); err == nil && info.IsDir() {
			return resolved, nil
		}
	}
	return "", bad("project path must be an existing directory")
}

func (s *service) projectByID(id string) *Project {
	for _, p := range s.state.Projects {
		if p.ID == id {
			return p
		}
	}
	return nil
}

func (s *service) ensureProject(path, name string) (*Project, bool) {
	for _, p := range s.state.Projects {
		if p.Path == path {
			return p, false
		}
	}
	if name == "" {
		name = filepath.Base(path)
	}
	p := &Project{ID: randomID("p-"), Path: path, Name: name}
	s.state.Projects = append(s.state.Projects, p)
	return p, true
}

func (s *service) recoverProjects() bool {
	dirty := false
	for _, run := range s.state.Runs {
		if run.ProjectID != "" || !filepath.IsAbs(run.Path) {
			continue
		}
		path, err := existingProjectDirectory(run.Path)
		if err != nil {
			path = filepath.Clean(run.Path)
		}
		p, _ := s.ensureProject(path, run.Project)
		run.ProjectID = p.ID
		dirty = true
	}
	return dirty
}

func (s *service) listProjects(req *http.Request, actor string) (outcome, error) {
	if actor != "" || hosted.From(req.Context()) != nil {
		return outcome{}, denied()
	}
	return read(map[string][]*Project{"projects": append([]*Project{}, s.state.Projects...)}), nil
}

func (s *service) openProject(req *http.Request, actor string) (outcome, error) {
	if actor != "" || hosted.From(req.Context()) != nil {
		return outcome{}, denied()
	}
	var input struct {
		Path string `json:"path"`
	}
	if err := decode(req, &input); err != nil {
		return outcome{}, err
	}
	prepared, err := s.prepareLaunch(req.Context(), launchPrerequisites{path: input.Path, projectOnly: true})
	if err != nil {
		return outcome{}, err
	}
	p, created := s.ensureProject(prepared.projectPath, "")
	if !created {
		return read(p), nil
	}
	return outcome{body: p, code: http.StatusCreated, mutated: true}, nil
}

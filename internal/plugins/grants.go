package plugins

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
)

const grantsName = "tool-grants.json"

// grantFile mirrors the toolregistry grant format. Each tool value stays raw
// so grants for compiled tools pass through untouched.
type grantFile struct {
	Projects []grantProject `json:"projects"`
}

type grantProject struct {
	Path  string                     `json:"path"`
	Tools map[string]json.RawMessage `json:"tools"`
}

func readGrants(stateDir string) (grantFile, error) {
	path := filepath.Join(stateDir, grantsName)
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return grantFile{Projects: []grantProject{}}, nil
	}
	if err != nil {
		return grantFile{}, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return grantFile{}, fmt.Errorf("%s must be a private regular file", grantsName)
	}
	raw, err := readLimited(path, 64<<10)
	if err != nil {
		return grantFile{}, err
	}
	var file grantFile
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&file); err != nil || file.Projects == nil {
		return grantFile{}, fmt.Errorf("read %s: expected an explicit projects array", grantsName)
	}
	return file, nil
}

func writeGrants(stateDir string, file grantFile) error {
	file.Projects = slices.DeleteFunc(file.Projects, func(p grantProject) bool { return len(p.Tools) == 0 })
	raw, err := json.MarshalIndent(file, "", "  ")
	if err != nil {
		return err
	}
	return writePrivate(filepath.Join(stateDir, grantsName), append(raw, '\n'))
}

// Grant authorizes one installed plugin tool version for a project checkout.
// The service reads grants at startup, so a running service needs a restart.
func Grant(stateDir, toolID string, version int, project string, settings json.RawMessage) error {
	record, tool, err := findTool(stateDir, toolID)
	if err != nil {
		return err
	}
	if tool.Version != version {
		return fmt.Errorf("plugin %s provides %s version %d, not %d", record.ID, toolID, tool.Version, version)
	}
	if err := validateSettings(record, settings); err != nil {
		return err
	}
	clean := filepath.Clean(project)
	if !filepath.IsAbs(clean) {
		return errors.New("grant a project by its absolute path")
	}
	if info, err := os.Stat(clean); err != nil || !info.IsDir() {
		return fmt.Errorf("project %s must be an existing directory", clean)
	}
	value, err := json.Marshal(struct {
		Version  int             `json:"version"`
		Settings json.RawMessage `json:"settings,omitempty"`
	}{version, settings})
	if err != nil {
		return err
	}
	file, err := readGrants(stateDir)
	if err != nil {
		return err
	}
	index := slices.IndexFunc(file.Projects, func(p grantProject) bool { return filepath.Clean(p.Path) == clean })
	if index < 0 {
		file.Projects = append(file.Projects, grantProject{Path: clean, Tools: map[string]json.RawMessage{}})
		index = len(file.Projects) - 1
	}
	file.Projects[index].Tools[toolID] = value
	return writeGrants(stateDir, file)
}

// Revoke withdraws a tool from one project, or from every project when
// project is empty.
func Revoke(stateDir, toolID, project string) error {
	if project != "" {
		project = filepath.Clean(project)
	}
	return revokeTools(stateDir, project, []string{toolID})
}

func revokeTools(stateDir, project string, ids []string) error {
	file, err := readGrants(stateDir)
	if err != nil {
		return err
	}
	changed := false
	for _, p := range file.Projects {
		if project != "" && filepath.Clean(p.Path) != project {
			continue
		}
		for _, id := range ids {
			if _, ok := p.Tools[id]; ok {
				delete(p.Tools, id)
				changed = true
			}
		}
	}
	if !changed {
		return nil
	}
	return writeGrants(stateDir, file)
}

func findTool(stateDir, toolID string) (Record, ToolRecord, error) {
	installed, err := List(stateDir)
	if err != nil {
		return Record{}, ToolRecord{}, err
	}
	for _, r := range installed {
		for _, t := range r.Tools {
			if t.ID == toolID {
				return r, t, nil
			}
		}
	}
	return Record{}, ToolRecord{}, fmt.Errorf("no installed plugin provides %s", toolID)
}

func validateSettings(record Record, settings json.RawMessage) error {
	if len(record.SettingsSchema) == 0 {
		if len(settings) != 0 {
			return fmt.Errorf("plugin %s does not accept project settings", record.ID)
		}
		return nil
	}
	resolved, err := resolveObjectSchema(record.SettingsSchema)
	if err != nil {
		return err
	}
	if len(settings) == 0 {
		settings = json.RawMessage(`{}`)
	}
	var value map[string]any
	if err := json.Unmarshal(settings, &value); err != nil || value == nil {
		return errors.New("plugin settings must be a JSON object")
	}
	if err := resolved.Validate(value); err != nil {
		return fmt.Errorf("plugin settings do not match the plugin's settings_schema: %w", err)
	}
	return nil
}

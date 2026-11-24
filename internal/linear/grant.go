package linear

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

var (
	credentialName = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,63}$`)
	teamID         = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	credentialKey  = regexp.MustCompile(`^[\x21-\x7e]{1,512}$`)
	errCredential  = errors.New("Linear credential must be a private regular key file")
)

type projectGrant struct {
	credential string
	teams      []string
}

func parseGrant(raw json.RawMessage) (projectGrant, error) {
	var settings struct {
		Credential string   `json:"credential"`
		TeamIDs    []string `json:"team_ids"`
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&settings); err != nil ||
		!credentialName.MatchString(settings.Credential) || len(settings.TeamIDs) == 0 {
		return projectGrant{}, errors.New("Linear grants require a credential name and a nonempty team_ids list")
	}
	for i, id := range settings.TeamIDs {
		settings.TeamIDs[i] = strings.ToLower(id)
		if !teamID.MatchString(settings.TeamIDs[i]) {
			return projectGrant{}, errors.New("Linear team_ids must be team UUIDs")
		}
	}
	slices.Sort(settings.TeamIDs)
	return projectGrant{credential: settings.Credential, teams: slices.Compact(settings.TeamIDs)}, nil
}

func readCredential(stateDir, name string) (string, error) {
	dir := filepath.Join(stateDir, "linear-credentials")
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return "", errCredential
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		return "", errCredential
	}
	defer root.Close()
	openedDir, err := root.Stat(".")
	if err != nil || !os.SameFile(info, openedDir) || openedDir.Mode().Perm()&0077 != 0 {
		return "", errCredential
	}
	filename := name + ".key"
	info, err = root.Lstat(filename)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return "", errCredential
	}
	file, err := root.Open(filename)
	if err != nil {
		return "", errCredential
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !os.SameFile(info, opened) || opened.Mode().Perm()&0077 != 0 {
		return "", errCredential
	}
	raw, err := io.ReadAll(io.LimitReader(file, 514))
	if err != nil || len(raw) > 513 {
		return "", errCredential
	}
	key := strings.TrimSpace(string(raw))
	if !credentialKey.MatchString(key) {
		return "", errCredential
	}
	return key, nil
}

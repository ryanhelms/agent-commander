package provider

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"agentcommander/internal/catalog"
)

type acpProfile struct {
	Command          string            `json:"command"`
	Args             []string          `json:"args,omitempty"`
	OmitCommanderMCP bool              `json:"omit_commander_mcp,omitempty"`
	History          *acpHistory       `json:"history,omitempty"`
	Env              map[string]string `json:"-"`
}

type acpHistory struct {
	Format    string `json:"format"`
	Directory string `json:"directory"`
}

const acpReplayHistory = "acp-v1-replay"

func (p acpProfile) instance(id string) string {
	instance := "local-profile-" + id
	if p.History == nil {
		return instance
	}
	identity := p.History.Format + "\x00" + p.History.Directory
	if p.History.Format == acpReplayHistory {
		identity = strings.Join(append([]string{p.History.Format, p.Command}, p.Args...), "\x00")
	}
	fingerprint := sha256.Sum256([]byte(identity))
	return fmt.Sprintf("%s:history-%x", instance, fingerprint)
}

func loadACPProfiles(dir string) (map[string]acpProfile, error) {
	path := filepath.Join(dir, "acp-profiles.json")
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0022 != 0 {
		return nil, errors.New("ACP profiles must be a regular file writable only by its owner")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	const maxBytes = 64 << 10
	data, err := io.ReadAll(io.LimitReader(file, maxBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxBytes {
		return nil, errors.New("ACP profiles file exceeds 64 KiB")
	}
	var profiles map[string]acpProfile
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&profiles); err != nil || profiles == nil {
		return nil, errors.New("ACP profiles must be an object keyed by profile ID")
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, errors.New("unexpected data after ACP profiles")
	}
	for id, profile := range profiles {
		if !validID.MatchString(id) || id != strings.ToLower(id) || id == "claude" || id == "codex" {
			return nil, fmt.Errorf("invalid or reserved ACP profile ID %q", id)
		}
		if !filepath.IsAbs(profile.Command) || strings.ContainsRune(profile.Command, 0) {
			return nil, fmt.Errorf("ACP profile %q requires an absolute executable path", id)
		}
		for _, arg := range profile.Args {
			if strings.ContainsRune(arg, 0) {
				return nil, fmt.Errorf("ACP profile %q contains an invalid argument", id)
			}
		}
		if h := profile.History; h != nil {
			if h.Format == acpReplayHistory {
				if h.Directory != "" {
					return nil, fmt.Errorf("ACP replay profile %q does not accept a history directory", id)
				}
				continue
			}
			if acpHistoryReaders[h.Format] == nil || !filepath.IsAbs(h.Directory) {
				return nil, fmt.Errorf("ACP profile %q requires a supported history format and absolute directory", id)
			}
			path, err := resolveHistoryDirectory(h.Directory)
			if err != nil {
				return nil, fmt.Errorf("resolve ACP profile %q history directory: %w", id, err)
			}
			h.Directory = path
		}
	}
	return profiles, nil
}

// A provider may create its history directory on first launch or delete it
// during retention cleanup. Resolve the existing directory prefix in either case.
func resolveHistoryDirectory(path string) (string, error) {
	path = filepath.Clean(path)
	var missing []string
	for candidate := path; ; candidate = filepath.Dir(candidate) {
		resolved, err := filepath.EvalSymlinks(candidate)
		if err == nil {
			info, err := os.Stat(resolved)
			if err != nil {
				return "", err
			}
			if !info.IsDir() {
				return "", errors.New("history source must be a directory")
			}
			for i := len(missing) - 1; i >= 0; i-- {
				resolved = filepath.Join(resolved, missing[i])
			}
			return resolved, nil
		}
		if !errors.Is(err, os.ErrNotExist) || candidate == filepath.Dir(candidate) {
			return "", err
		}
		missing = append(missing, filepath.Base(candidate))
	}
}

func (l *Local) registeredACP(client string) (string, acpProfile, bool, error) {
	id := strings.ToLower(strings.TrimSpace(client))
	profile, ok := l.acpProfiles[id]
	if ok {
		return id, profile, true, nil
	}
	installed, err := catalog.LoadPin(l.stateDir, id)
	if err != nil || installed == nil {
		return id, acpProfile{}, false, err
	}
	return id, acpProfile{Command: installed.Command, Args: installed.Args, Env: installed.Env}, true, nil
}

func (p acpProfile) executable() (string, error) {
	path, err := filepath.EvalSymlinks(p.Command)
	if err != nil {
		return "", err
	}
	return exec.LookPath(path)
}

// External ACP profiles are trusted for an explicit owner launch. ACP does
// not establish that the provider enforces the managed planning tool policy.
func (l *Local) CheckAgentClient(client string) error {
	if _, selected, err := selectedBuiltin(client); selected {
		if err != nil {
			return err
		}
		return errors.New("this built-in adapter requires an explicit local owner launch")
	}
	_, _, registered, err := l.registeredACP(client)
	if err != nil {
		return err
	}
	if registered {
		return errors.New("this ACP profile requires an explicit local owner launch")
	}
	return nil
}

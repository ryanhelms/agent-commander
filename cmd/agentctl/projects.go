package main

import (
	"context"
	"encoding/json"
	"errors"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
)

func projectOperation(args []string) (string, string, any, error) {
	switch {
	case len(args) == 1 && args[0] == "list":
		return "GET", "/v1/projects", nil, nil
	case len(args) >= 1 && len(args) <= 2 && args[0] == "open":
		path := "."
		if len(args) == 2 {
			path = args[1]
		}
		absolute, err := filepath.Abs(path)
		if err != nil {
			return "", "", nil, err
		}
		return "POST", "/v1/projects", map[string]string{"path": absolute}, nil
	default:
		return "", "", nil, errors.New("usage: agentctl project list | project open [--open] [DIRECTORY]")
	}
}

// Only consume an option before the directory and task. Once the task starts,
// every argument is prompt text.
func cockpitLaunchArgs(args []string) ([]string, string) {
	if len(args) >= 2 && args[0] == "run" && args[1] == "--open" {
		return slices.Delete(slices.Clone(args), 1, 2), "run"
	}
	if len(args) >= 4 && args[0] == "run" && args[1] == "--client" && args[3] == "--open" {
		return slices.Delete(slices.Clone(args), 3, 4), "run"
	}
	if len(args) >= 3 && args[0] == "project" && args[1] == "open" && args[2] == "--open" {
		return slices.Delete(slices.Clone(args), 2, 3), "project"
	}
	return args, ""
}

var cockpitTargetID = regexp.MustCompile(`^[rp]-[0-9a-f]{32}$`)

func cockpitResultURL(kind string, result []byte) (string, error) {
	var target struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(result, &target); err != nil {
		return "", err
	}
	if (kind != "run" && kind != "project") || !cockpitTargetID.MatchString(target.ID) ||
		!strings.HasPrefix(target.ID, kind[:1]+"-") {
		return "", errors.New("Commander returned an invalid destination")
	}
	return "agentcommander://" + kind + "/" + target.ID, nil
}

func openCockpitResult(ctx context.Context, kind string, result []byte) error {
	link, err := cockpitResultURL(kind, result)
	if err != nil {
		return err
	}
	if runtime.GOOS != "darwin" {
		return errors.New("opening the cockpit is only available on macOS")
	}
	return exec.CommandContext(ctx, "/usr/bin/open", "-b", "local.agentcommander.cockpit", link).Run()
}

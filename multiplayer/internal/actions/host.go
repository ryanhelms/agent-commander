package actions

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"time"

	"agentcommander.network/pilot/internal/sharing"
)

// HostCommand is one command an owner lends to friends.
type HostCommand struct {
	Name        string   `json:"name"`
	Args        []string `json:"args"`
	Dir         string   `json:"dir"`
	AllowArgs   bool     `json:"allowArgs,omitempty"`
	Environment string   `json:"environment,omitempty"`
	TimeoutSec  int      `json:"timeoutSec,omitempty"`
}

// LoadHostCommands reads a host resource's command file: {"commands": [...]}.
func LoadHostCommands(path string) ([]HostCommand, error) {
	if !filepath.IsAbs(path) {
		return nil, errors.New("host command file must be an absolute path")
	}
	b, e := os.ReadFile(path)
	if e != nil {
		return nil, e
	}
	var file struct{ Commands []HostCommand }
	if e = json.Unmarshal(b, &file); e != nil {
		return nil, e
	}
	if len(file.Commands) == 0 {
		return nil, errors.New("no commands enrolled")
	}
	for _, c := range file.Commands {
		if c.Name == "" || len(c.Args) == 0 || !filepath.IsAbs(c.Dir) {
			return nil, errors.New("each command needs a name, an argument array and an absolute dir")
		}
	}
	return file.Commands, nil
}

func prepareHost(r Resource) (Resource, error) {
	commands, err := LoadHostCommands(r.Target)
	if err != nil {
		return r, ErrInvalid
	}
	caps := sharing.Capabilities{}
	if r.Capabilities != nil {
		caps = *r.Capabilities
	}
	caps.Tools, caps.Environments = []string{}, []string{}
	for _, command := range commands {
		if !slices.Contains(caps.Tools, command.Name) {
			caps.Tools = append(caps.Tools, command.Name)
		}
		if command.Environment != "" && !slices.Contains(caps.Environments, command.Environment) {
			caps.Environments = append(caps.Environments, command.Environment)
		}
	}
	r.Capabilities = &caps
	return r, nil
}

func hostHandler(ctx context.Context, _ Config, r Resource, req Request, _ string, _ bool) (json.RawMessage, error) {
	var in struct {
		Command string   `json:"command"`
		Args    []string `json:"args"`
	}
	if strict(req.Payload, &in) != nil {
		return nil, ErrInvalid
	}
	cmds, e := LoadHostCommands(r.Target)
	if e != nil {
		return nil, ErrUnavailable
	}
	var cmd *HostCommand
	for i := range cmds {
		if cmds[i].Name == in.Command {
			cmd = &cmds[i]
		}
	}
	if cmd == nil || (len(in.Args) > 0 && !cmd.AllowArgs) {
		return nil, ErrDenied
	}
	timeout := time.Duration(cmd.TimeoutSec) * time.Second
	if timeout <= 0 || timeout > 30*time.Minute {
		timeout = 10 * time.Minute
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	argv := append(append([]string{}, cmd.Args...), in.Args...)
	c := exec.CommandContext(ctx, argv[0], argv[1:]...)
	c.Dir = cmd.Dir
	var out bytes.Buffer
	c.Stdout, c.Stderr = &out, &out
	started := time.Now()
	runErr := c.Run()
	code := 0
	var exit *exec.ExitError
	switch {
	case errors.As(runErr, &exit):
		code = exit.ExitCode()
	case runErr != nil:
		return nil, ErrUnavailable
	}
	tail := out.Bytes()
	if len(tail) > 64<<10 {
		tail = tail[len(tail)-64<<10:]
	}
	return answer(map[string]any{"command": cmd.Name, "exitCode": code, "output": string(tail), "seconds": int(time.Since(started).Seconds())})
}

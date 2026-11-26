// Package sshx runs commands on a server through the system OpenSSH client,
// so host aliases, jump hosts, keys and known hosts work as they do in a
// terminal.
package sshx

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os/exec"
	"strings"
)

// Target is one SSH destination and the options passed to ssh before it.
type Target struct {
	Destination string
	Options     []string // such as -p 2222, -i KEY, -F CONFIG, -o NAME=VALUE
}

// Quote quotes one word for a POSIX shell.
func Quote(word string) string {
	if word != "" && strings.Trim(word, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./=:@%+,") == "" {
		return word
	}
	return "'" + strings.ReplaceAll(word, "'", `'\''`) + "'"
}

// Command builds the ssh command for a remote shell script. The script runs
// under `sh -c` on the server, so the user's login shell does not matter.
func (t Target) Command(ctx context.Context, script string) (*exec.Cmd, error) {
	if t.Destination == "" || strings.HasPrefix(t.Destination, "-") {
		return nil, fmt.Errorf("invalid SSH destination %q", t.Destination)
	}
	args := append([]string{"-o", "BatchMode=yes"}, t.Options...)
	args = append(args, "--", t.Destination, "sh -c "+Quote(script))
	return exec.CommandContext(ctx, "ssh", args...), nil
}

// Run runs script with stdin and returns its standard output. A failure
// includes the remote standard error.
func (t Target) Run(ctx context.Context, script string, stdin io.Reader) ([]byte, error) {
	cmd, err := t.Command(ctx, script)
	if err != nil {
		return nil, err
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdin, cmd.Stdout, cmd.Stderr = stdin, &stdout, &stderr
	if err := cmd.Run(); err != nil {
		return stdout.Bytes(), &Error{Err: err, Stderr: strings.TrimSpace(stderr.String())}
	}
	return stdout.Bytes(), nil
}

// Error is a failed remote command.
type Error struct {
	Err    error
	Stderr string
}

func (e *Error) Error() string {
	if e.Stderr == "" {
		return e.Err.Error()
	}
	return e.Err.Error() + ": " + e.Stderr
}

func (e *Error) Unwrap() error { return e.Err }

// ExitCode returns the remote exit status, or -1 when ssh itself failed.
func (e *Error) ExitCode() int {
	if x, ok := e.Err.(*exec.ExitError); ok {
		return x.ExitCode()
	}
	return -1
}

// Platform reports the server's GOOS and GOARCH from uname.
func (t Target) Platform(ctx context.Context) (string, string, error) {
	out, err := t.Run(ctx, "uname -s; uname -m", nil)
	if err != nil {
		return "", "", err
	}
	fields := strings.Fields(string(out))
	if len(fields) != 2 {
		return "", "", fmt.Errorf("unexpected uname output %q", out)
	}
	goos := strings.ToLower(fields[0])
	arch := map[string]string{"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}[fields[1]]
	if arch == "" {
		return goos, "", fmt.Errorf("unsupported architecture %s", fields[1])
	}
	return goos, arch, nil
}

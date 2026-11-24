package provider

import (
	"context"
	"errors"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"agentcommander/internal/service"
)

var tmuxSessionID = regexp.MustCompile(`^\$[0-9]+$`)

func (l *Local) ResolveTerminal(ctx context.Context, workerID string) (service.TerminalAttachment, error) {
	var target service.TerminalAttachment
	if !validID.MatchString(workerID) {
		return target, errors.New("invalid managed worker ID")
	}
	tmux, err := TmuxExecutable()
	if err != nil {
		return target, err
	}
	// Inspect the selected pane and its enclosing session in one server command.
	// -N prevents lookup from creating a new server when the original exits.
	const format = "#{session_name}\t#{session_id}\t#{socket_path}\t#{session_windows}\t#{window_panes}\t#{window_linked}\t#{pane_start_command}"
	raw, err := exec.CommandContext(ctx, tmux, "-N", "-L", l.label, "display-message", "-p", "-t", "="+workerID+":", format).Output()
	if err != nil {
		return target, err
	}
	fields := strings.Split(strings.TrimSuffix(string(raw), "\n"), "\t")
	if len(fields) != 7 || fields[0] != workerID || !tmuxSessionID.MatchString(fields[1]) ||
		!filepath.IsAbs(fields[2]) || strings.ContainsAny(fields[2], "\r\n") ||
		fields[3] != "1" || fields[4] != "1" || fields[5] != "0" {
		return target, errors.New("expected a dedicated single-pane worker session")
	}
	// A pane may have been moved here from another worker. Its original launch
	// argv survives the runner deleting launch.json, even on pre-viewer sessions.
	// tmux may quote an argument containing spaces when rendering the command.
	command := strings.TrimRight(fields[6], "\"'")
	if !strings.Contains(command, " runner ") || !strings.HasSuffix(command, "/jobs/"+workerID+"/launch.json") {
		return target, errors.New("selected pane does not belong to the original worker")
	}
	return service.TerminalAttachment{WorkerID: workerID, SocketPath: fields[2], SessionID: fields[1]}, nil
}

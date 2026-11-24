package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"agentcommander/internal/localapi"
	"agentcommander/internal/provider"
	"agentcommander/internal/service"
)

var tmuxSessionID = regexp.MustCompile(`^\$[0-9]+$`)

// Both clients belong to this viewer. Closing it leaves the managed worker running.
func observeTerminal(ctx context.Context, api *localapi.Client, workerID string) error {
	id, err := localapi.Segment(workerID)
	if err != nil {
		return err
	}
	data, err := api.Do(ctx, "GET", "/v1/workers/"+id+"/terminal", nil)
	if err != nil {
		var response *localapi.ResponseError
		if errors.As(err, &response) && response.StatusCode == 404 && strings.Contains(response.Error(), "404 page not found") {
			return errors.New("the running Commander service predates native terminals; restart it with the agentctl bundled with this app")
		}
		return fmt.Errorf("cannot open native terminal: %w", err)
	}
	var target service.TerminalAttachment
	if err := json.Unmarshal(data, &target); err != nil || target.WorkerID != workerID ||
		!filepath.IsAbs(target.SocketPath) || !tmuxSessionID.MatchString(target.SessionID) {
		return errors.New("Commander returned an invalid terminal target")
	}
	tmux, err := provider.TmuxExecutable()
	if err != nil {
		return err
	}
	// An exact worker name remains unique across tmux server restarts, where
	// tmux numeric IDs can be reused. -N prevents starting a replacement server.
	env := make([]string, 0, len(os.Environ()))
	for _, entry := range os.Environ() {
		key, _, _ := strings.Cut(entry, "=")
		if key != "TMUX" && key != "TMUX_PANE" {
			env = append(env, entry)
		}
	}
	ctx, cancel := signal.NotifyContext(ctx, syscall.SIGHUP)
	defer cancel()
	ctx, stopClients := context.WithCancel(ctx)
	defer stopClients()
	args := []string{"-N", "-S", target.SocketPath}
	command := func(tail ...string) *exec.Cmd {
		cmd := exec.CommandContext(ctx, tmux, append(args, tail...)...)
		cmd.Env = env
		cmd.Cancel = func() error { return cmd.Process.Signal(syscall.SIGHUP) }
		cmd.WaitDelay = 2 * time.Second
		return cmd
	}
	session := "=" + workerID
	// tmux 3.5 can use the size of its sole attached client even with ignore-size.
	// An unsized control client keeps a detached window's geometry intact. It
	// never receives user input or pane output. Ordinary writers keep sizing it.
	anchor := command("-C", "attach-session", "-E", "-f", "no-output", "-t", session)
	input, err := anchor.StdinPipe()
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := anchor.StdoutPipe()
	if err != nil {
		return err
	}
	anchor.Stderr = os.Stderr
	if err := anchor.Start(); err != nil {
		return err
	}
	ready := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		reader := bufio.NewReader(output)
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				break
			}
			if strings.TrimSuffix(line, "\n") == "%session-changed "+target.SessionID+" "+workerID {
				close(ready)
				_, _ = io.Copy(io.Discard, reader)
				break
			}
		}
		_ = anchor.Wait()
		stopClients()
	}()
	defer func() {
		stopClients()
		_ = input.Close()
		<-done
	}()
	select {
	case <-ready:
	case <-ctx.Done():
		return errors.New("the selected tmux session is unavailable")
	case <-time.After(5 * time.Second):
		return errors.New("timed out attaching to the selected tmux session")
	}
	viewer := command("attach-session", "-E", "-r", "-t", session)
	viewer.Stdin, viewer.Stdout, viewer.Stderr = os.Stdin, os.Stdout, os.Stderr
	return viewer.Run()
}

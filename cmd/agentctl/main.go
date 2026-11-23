package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"agentcommander/internal/localapi"
	"agentcommander/internal/mcpbridge"
	"agentcommander/internal/provider"
	"agentcommander/internal/service"
)

const usage = `Agent Commander

  agentctl start                         Start the local API service
  agentctl run DIRECTORY TASK            Start a managed coordinator
  agentctl list                          List runs
  agentctl show RUN                      Inspect a run and its consoles
  agentctl delegate RUN PARENT NAME TASK Create a worker under PARENT
  agentctl reply REQUEST ANSWER          Answer a pending question
  agentctl stop RUN                      Stop this run's managed workers
  agentctl take WORKER GENERATION        Acquire worker input for the developer
  agentctl hand-back WORKER GENERATION   Return worker input to its coordinator
  agentctl follow-up WORKER GEN TEXT     Send a follow-up while holding worker input
  agentctl interrupt WORKER              Interrupt a single worker's active turn
  agentctl stop-worker WORKER            Stop one managed worker
  agentctl api METHOD /v1/PATH           Call the API with an optional JSON body on stdin
  agentctl mcp                           Serve MCP for a managed actor over stdio

Arguments containing whitespace should be quoted by the calling shell.
Set AGENT_COMMANDER_HOME for an isolated service or AGENT_COMMANDER_SOCKET for its socket.`

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 || args[0] == "help" || args[0] == "--help" {
		fmt.Println(usage)
		return nil
	}
	paths, err := localapi.Config()
	if err != nil {
		return err
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	token := os.Getenv("AGENT_COMMANDER_TOKEN")
	api := localapi.New(paths.Socket, token)
	switch args[0] {
	case "runner":
		if len(args) != 2 {
			return errors.New("runner needs a job file")
		}
		return provider.Runner(args[1])
	case "serve":
		return serve(ctx, paths)
	case "start":
		return start(ctx, paths, api)
	case "mcp":
		return mcpbridge.Run(ctx, api)
	}
	method, path, input, err := operation(args)
	if err != nil {
		return err
	}
	b, err := api.Do(ctx, method, path, input)
	if err != nil {
		return err
	}
	var pretty interface{}
	if err = json.Unmarshal(b, &pretty); err != nil {
		return err
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(pretty)
}

func operation(args []string) (method, path string, input any, err error) {
	invalid := func() (string, string, any, error) {
		return "", "", nil, fmt.Errorf("invalid arguments for %s\n%s", args[0], usage)
	}
	switch args[0] {
	case "list":
		if len(args) != 1 {
			return invalid()
		}
		return "GET", "/v1/runs", nil, nil
	case "run":
		if len(args) < 3 {
			return invalid()
		}
		dir, err := filepath.Abs(args[1])
		if err != nil {
			return "", "", nil, err
		}
		info, err := os.Stat(dir)
		if err != nil {
			return "", "", nil, err
		}
		if !info.IsDir() {
			return "", "", nil, errors.New("project must be a directory")
		}
		return "POST", "/v1/runs", map[string]string{"project": filepath.Base(dir), "path": dir, "task": strings.Join(args[2:], " "), "client": "claude"}, nil
	case "show", "stop", "reply", "delegate":
		if len(args) < 2 {
			return invalid()
		}
		id, err := localapi.Segment(args[1])
		if err != nil {
			return "", "", nil, err
		}
		switch args[0] {
		case "show":
			if len(args) != 2 {
				return invalid()
			}
			return "GET", "/v1/runs/" + id, nil, nil
		case "stop":
			if len(args) != 2 {
				return invalid()
			}
			return "POST", "/v1/runs/" + id + "/stop", struct{}{}, nil
		case "reply":
			if len(args) < 3 {
				return invalid()
			}
			return "POST", "/v1/requests/" + id + "/reply", map[string]string{"answer": strings.Join(args[2:], " ")}, nil
		case "delegate":
			if len(args) < 5 {
				return invalid()
			}
			return "POST", "/v1/runs/" + id + "/workers", map[string]string{"parent_id": args[2], "name": args[3], "task": strings.Join(args[4:], " ")}, nil
		}
	case "take", "hand-back", "follow-up", "interrupt", "stop-worker":
		if len(args) < 2 {
			return invalid()
		}
		id, err := localapi.Segment(args[1])
		if err != nil {
			return "", "", nil, err
		}
		path := "/v1/workers/" + id
		switch args[0] {
		case "interrupt", "stop-worker":
			if len(args) != 2 {
				return invalid()
			}
			action := strings.TrimSuffix(args[0], "-worker")
			return "POST", path + "/" + action, struct{}{}, nil
		}
		if len(args) < 3 {
			return invalid()
		}
		generation, err := strconv.Atoi(args[2])
		if err != nil || generation < 1 {
			return "", "", nil, errors.New("generation must be a positive integer from the worker's control state")
		}
		if args[0] == "follow-up" && len(args) >= 4 {
			return "POST", path + "/messages", map[string]any{"generation": generation, "text": strings.Join(args[3:], " ")}, nil
		}
		if args[0] != "follow-up" && len(args) == 3 {
			return "POST", path + "/control", map[string]any{"generation": generation, "held": args[0] == "take"}, nil
		}
		return invalid()
	case "api":
		if len(args) != 3 {
			return invalid()
		}
		method = strings.ToUpper(args[1])
		switch method {
		case "GET", "HEAD":
			return method, args[2], nil, nil
		case "POST", "PUT", "PATCH", "DELETE":
		default:
			return invalid()
		}
		info, err := os.Stdin.Stat()
		if err != nil {
			return "", "", nil, err
		}
		if info.Mode()&os.ModeCharDevice == 0 {
			b, err := io.ReadAll(os.Stdin)
			if err != nil {
				return "", "", nil, err
			}
			if len(b) > 0 {
				if !json.Valid(b) {
					return "", "", nil, errors.New("stdin must contain JSON")
				}
				input = json.RawMessage(b)
			}
		}
		return method, args[2], input, nil
	}
	return invalid()
}

func start(ctx context.Context, p localapi.Paths, api *localapi.Client) error {
	if _, err := api.Do(ctx, "GET", "/v1/health", nil); err == nil {
		return nil
	}
	if err := os.MkdirAll(p.State, 0700); err != nil {
		return err
	}
	binary, err := os.Executable()
	if err != nil {
		return err
	}
	logPath := filepath.Join(p.State, "service.log")
	log, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return err
	}
	defer log.Close()
	cmd := exec.Command(binary, "serve")
	cmd.Stdout = log
	cmd.Stderr = log
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start service: %w", err)
	}
	// Reap the child if startup fails. The daemon continues when this CLI exits.
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	deadline := time.NewTimer(8 * time.Second)
	defer deadline.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-exited:
			// A concurrent start can own the lock and still be starting its listener.
			exited = nil
		case <-deadline.C:
			return fmt.Errorf("service did not become ready; see %s", logPath)
		case <-ticker.C:
			if _, err := api.Do(ctx, "GET", "/v1/health", nil); err == nil {
				return nil
			}
		}
	}
}

func serve(ctx context.Context, p localapi.Paths) error {
	if err := os.MkdirAll(p.State, 0700); err != nil {
		return err
	}
	lock, err := os.OpenFile(filepath.Join(p.State, "service.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return errors.New("a Commander service already owns this data directory")
	}
	if fi, err := os.Lstat(p.Socket); err == nil {
		if fi.Mode()&os.ModeSocket == 0 {
			return fmt.Errorf("existing path is not a socket: %s", p.Socket)
		}
		conn, dialErr := net.DialTimeout("unix", p.Socket, time.Second)
		if dialErr == nil {
			conn.Close()
			return errors.New("this API socket is in use")
		}
		if !errors.Is(dialErr, syscall.ECONNREFUSED) && !errors.Is(dialErr, os.ErrNotExist) {
			return dialErr
		}
		if err := os.Remove(p.Socket); err != nil {
			return err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	binary, err := os.Executable()
	if err != nil {
		return err
	}
	adapter, err := provider.New(p.State, p.Socket, binary)
	if err != nil {
		return err
	}
	handler, err := service.New(p.State, adapter)
	if err != nil {
		return err
	}
	syscall.Umask(0077)
	listener, err := net.Listen("unix", p.Socket)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", p.Socket, err)
	}
	defer listener.Close()
	if err := os.Chmod(p.Socket, 0600); err != nil {
		return err
	}
	server := http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 60 * time.Second}
	context.AfterFunc(ctx, func() { _ = server.Close() })
	err = server.Serve(listener)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

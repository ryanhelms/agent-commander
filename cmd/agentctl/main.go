package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"agentcommander/internal/catalog"
	"agentcommander/internal/linear"
	"agentcommander/internal/localapi"
	"agentcommander/internal/mcpbridge"
	"agentcommander/internal/provider"
	"agentcommander/internal/service"
	"agentcommander/internal/toolregistry"
)

const usage = `Agent Commander

  agentctl start                         Start the local API service
  agentctl run [--client ID] DIRECTORY TASK
                                         Start a managed coordinator
  agentctl catalog list [HTTPS_URL ...]   List ACP adapter catalog metadata
  agentctl catalog stage-binary URL ID VERSION ENTRY SIGNATURE PUBLIC_KEY
                                         Verify and stage a catalog binary
  agentctl catalog stage-package URL ID VERSION npm|python ENTRY SIGNATURE PUBLIC_KEY
                                         Verify and stage an offline package bundle
  agentctl catalog activate STAGE PUBLISHER_KEY_SHA256
                                         Activate a staged binary
  agentctl catalog rollback ID            Restore the previous binary pin
  agentctl catalog updates                List verified, staged updates
  agentctl catalog update-source ID ENTRY_URL SIGNATURE_URL PUBLIC_KEY
                                         Configure the pinned publisher's HTTPS proof endpoints
  agentctl catalog refresh ID             Check and stage a verified update
  agentctl list                          List runs
  agentctl show RUN                      Inspect a run and its consoles
  agentctl session status WORKER            Read negotiated and usable provider capabilities
  agentctl session list WORKER [CURSOR]     Discover provider sessions in this worker's checkout
  agentctl session reattach WORKER GENERATION OPERATION_ID [--acknowledge-unknown]
  agentctl terminal observe WORKER       Watch a managed worker’s tmux terminal read-only
  agentctl delegate RUN PARENT NAME TASK Create a worker under PARENT
  agentctl delegate-coding RUN PARENT NAME TASK
                                         Create an isolated coding worker
  agentctl integrate RUN KEY WORKER...   Test and integrate selected coding handoffs
  agentctl reply REQUEST ANSWER          Answer a pending question
  agentctl reconcile REQUEST             Check original SSH history for reply delivery
  agentctl stop RUN                      Stop this run's managed workers
  agentctl take WORKER GENERATION        Acquire worker input for the developer
  agentctl hand-back WORKER GENERATION   Return worker input to its coordinator
  agentctl follow-up WORKER GEN TEXT     Send a follow-up while holding worker input
  agentctl interrupt WORKER              Interrupt a single worker's active turn
  agentctl stop-worker WORKER            Stop one managed worker
  agentctl api METHOD /v1/PATH           Call the API with an optional JSON body on stdin
  agentctl mcp                           Serve MCP for a managed actor over stdio
  agentctl relay CONFIG.json             Serve the authenticated Commander relay
  agentctl relay --check CONFIG.json     Validate relay configuration without starting it

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
	if args[0] == "catalog" {
		if len(args) > 1 && args[1] == "update-source" {
			if len(args) != 6 {
				return errors.New("usage: agentctl catalog update-source ID ENTRY_URL SIGNATURE_URL PUBLIC_KEY")
			}
			key, err := readCatalogProof(args[5])
			if err != nil {
				return err
			}
			return catalog.SetUpdateSource(ctx, paths.State, args[2], args[3], args[4], key)
		}
		if len(args) > 1 && args[1] == "refresh" {
			if len(args) != 3 {
				return errors.New("usage: agentctl catalog refresh ID")
			}
			update, err := catalog.Refresh(ctx, paths.State, args[2])
			if err != nil {
				return err
			}
			encoder := json.NewEncoder(os.Stdout)
			encoder.SetIndent("", "  ")
			return encoder.Encode(update)
		}
		if len(args) == 9 && args[1] == "stage-package" {
			if args[5] != "npm" && args[5] != "python" {
				return errors.New("package manager must be npm or python")
			}
			return stageCatalogRelease(ctx, paths.State, args[2:5], args[5], args[6:])
		}
		if len(args) == 2 && args[1] == "updates" {
			updates, err := catalog.Updates(paths.State)
			if err != nil {
				return err
			}
			encoder := json.NewEncoder(os.Stdout)
			encoder.SetIndent("", "  ")
			return encoder.Encode(updates)
		}
		if len(args) == 4 && args[1] == "activate" {
			installed, err := catalog.Activate(ctx, paths.State, args[2], args[3])
			if err != nil {
				return err
			}
			return json.NewEncoder(os.Stdout).Encode(installed)
		}
		if len(args) == 3 && args[1] == "rollback" {
			installed, err := catalog.Rollback(ctx, paths.State, args[2])
			if err != nil {
				return err
			}
			return json.NewEncoder(os.Stdout).Encode(installed)
		}
		if len(args) > 1 && args[1] == "stage-binary" {
			if len(args) != 8 {
				return errors.New("usage: agentctl catalog stage-binary URL ID VERSION ENTRY SIGNATURE PUBLIC_KEY")
			}
			return stageCatalogRelease(ctx, paths.State, args[2:5], "", args[5:])
		}
		if len(args) < 2 || args[1] != "list" {
			return errors.New("usage: agentctl catalog list [HTTPS_URL ...]")
		}
		sources := args[2:]
		if len(sources) == 0 {
			sources = []string{catalog.DefaultURL}
		}
		snapshots := make([]catalog.Snapshot, 0, len(sources))
		for _, source := range sources {
			snapshot, err := catalog.Read(ctx, source)
			if err != nil {
				return fmt.Errorf("read ACP catalog: %w", err)
			}
			snapshots = append(snapshots, snapshot)
		}
		encoder := json.NewEncoder(os.Stdout)
		encoder.SetIndent("", "  ")
		return encoder.Encode(snapshots)
	}
	api := localapi.New(paths.Socket, token)
	switch args[0] {
	case "terminal":
		if len(args) != 3 || args[1] != "observe" {
			return errors.New("usage: agentctl terminal observe WORKER")
		}
		return observeTerminal(ctx, api, args[2])
	case "app-server":
		if len(args) != 1 {
			return errors.New("unexpected managed Codex startup arguments")
		}
		return provider.RunCodexBridge(ctx, os.Stdin, os.Stdout)
	case "runner":
		if len(args) != 2 {
			return errors.New("runner needs a job file")
		}
		return provider.Runner(args[1])
	case "runner-history":
		if len(args) != 1 {
			return errors.New("runner-history takes its request on stdin")
		}
		return provider.RunSSHHistory(ctx, os.Stdin, os.Stdout)
	case "persistent-acp":
		return provider.RunPersistentACP(ctx, args[1:], os.Stdin, os.Stdout)
	case "serve":
		return serve(ctx, paths)
	case "relay":
		if len(args) == 3 && args[1] == "--check" {
			_, err := prepareRelay(args[2])
			return err
		}
		if len(args) != 2 {
			return errors.New("usage: agentctl relay [--check] CONFIG.json")
		}
		return serveRelay(ctx, args[1])
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

func stageCatalogRelease(ctx context.Context, stateDir string, release []string, manager string, proofPaths []string) error {
	var proof catalog.BinaryProof
	fields := []*[]byte{&proof.Manifest, &proof.Signature, &proof.PublicKey}
	for i, field := range fields {
		data, err := readCatalogProof(proofPaths[i])
		if err != nil {
			return err
		}
		*field = data
	}
	snapshot, err := catalog.Read(ctx, release[0])
	if err != nil {
		return err
	}
	dir := filepath.Join(stateDir, "catalog", "staged")
	var staged catalog.StagedBinary
	if manager == "" {
		staged, err = catalog.StageBinary(ctx, dir, snapshot, release[1], release[2], proof)
	} else {
		staged, err = catalog.StagePackage(ctx, dir, snapshot, release[1], release[2], manager, proof)
	}
	if err != nil {
		return err
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(staged)
}

func readCatalogProof(path string) ([]byte, error) {
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
		return nil, errors.New("catalog proof file exceeds 64 KiB")
	}
	return data, nil
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
		client := "claude"
		runArgs := args[1:]
		if len(runArgs) > 0 && runArgs[0] == "--client" {
			if len(runArgs) < 4 || strings.TrimSpace(runArgs[1]) == "" {
				return invalid()
			}
			client, runArgs = runArgs[1], runArgs[2:]
		}
		if len(runArgs) < 2 {
			return invalid()
		}
		dir, err := filepath.Abs(runArgs[0])
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
		return "POST", "/v1/runs", map[string]string{"project": filepath.Base(dir), "path": dir, "task": strings.Join(runArgs[1:], " "), "client": client}, nil
	case "show", "stop", "reply", "reconcile", "delegate", "delegate-coding", "integrate":
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
		case "reconcile":
			if len(args) != 2 {
				return invalid()
			}
			return "POST", "/v1/requests/" + id + "/reconcile", struct{}{}, nil
		case "integrate":
			if len(args) < 4 {
				return invalid()
			}
			return "POST", "/v1/runs/" + id + "/integrations", map[string]any{"worker_ids": args[3:], "idempotency_key": args[2]}, nil
		case "delegate", "delegate-coding":
			if len(args) < 5 {
				return invalid()
			}
			input := map[string]string{"parent_id": args[2], "name": args[3], "task": strings.Join(args[4:], " ")}
			if args[0] == "delegate-coding" {
				input["kind"] = "coding"
			}
			return "POST", "/v1/runs/" + id + "/workers", input, nil
		}
	case "session":
		if len(args) < 3 {
			return invalid()
		}
		id, err := localapi.Segment(args[2])
		if err != nil {
			return "", "", nil, err
		}
		path := "/v1/workers/" + id
		switch args[1] {
		case "status":
			if len(args) == 3 {
				return "GET", path + "/session", nil, nil
			}
		case "list":
			switch len(args) {
			case 3:
				return "GET", path + "/provider-sessions", nil, nil
			case 4:
				return "GET", path + "/provider-sessions?cursor=" + url.QueryEscape(args[3]), nil, nil
			}
		case "reattach":
			if len(args) != 5 && (len(args) != 6 || args[5] != "--acknowledge-unknown") {
				return invalid()
			}
			generation, err := strconv.Atoi(args[3])
			if err != nil || generation <= 0 || strings.TrimSpace(args[4]) == "" {
				return invalid()
			}
			return "POST", path + "/reattach", map[string]any{
				"generation": generation, "idempotency_key": args[4],
				"acknowledge_delivery_unknown": len(args) == 6,
			}, nil
		}
		return invalid()
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

func lockServiceFile(path, busyMessage string) (*os.File, error) {
	lock, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, errors.New(busyMessage)
		}
		return nil, fmt.Errorf("lock %s: %w", path, err)
	}
	return lock, nil
}

func serve(ctx context.Context, p localapi.Paths) error {
	if err := os.MkdirAll(p.State, 0700); err != nil {
		return err
	}
	stateLock, err := lockServiceFile(filepath.Join(p.State, "service.lock"), "a Commander service already owns this data directory")
	if err != nil {
		return err
	}
	defer stateLock.Close()
	// Distinct homes can target the same API socket. Serialize stale-socket
	// recovery with bind and close so a losing process cannot unlink the winner.
	socketLock, err := lockServiceFile(p.Socket+".agentctl-lock", "this API socket is in use")
	if err != nil {
		return err
	}
	defer socketLock.Close()
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
	registry, err := toolregistry.Load(p.State, linear.IssueRead(p.State, nil))
	if err != nil {
		return err
	}
	if err := registry.RegisterCompanion(provider.DevflowCompanion()); err != nil {
		return err
	}
	adapter, err := provider.NewWithToolRegistry(p.State, p.Socket, binary, registry)
	if err != nil {
		return err
	}
	handler, err := service.NewWithToolRegistry(p.State, adapter, registry)
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
	access, err := prepareHosted(p.State, handler)
	if err != nil {
		return err
	}
	if access.connect != nil {
		relayCtx, stopRelay := context.WithCancel(ctx)
		defer stopRelay()
		go access.connect(relayCtx)
	}
	if access.direct == nil {
		err = server.Serve(listener)
	} else {
		defer access.direct.listener.Close()
		defer access.direct.server.Close()
		defer server.Close()
		done := make(chan error, 2)
		go func() { done <- server.Serve(listener) }()
		go func() { done <- access.direct.server.ServeTLS(access.direct.listener, "", "") }()
		err = <-done
	}
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

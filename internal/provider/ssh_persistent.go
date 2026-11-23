package provider

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"agentcommander/internal/localapi"
	"agentcommander/internal/sshlink"
)

const persistentACPConfig = "AGENT_COMMANDER_PERSISTENT_ACP_CONFIG"

type persistentProxy struct {
	Profile     sshProfile
	Worker      string
	LocalSocket string
	OwnerSocket string
}

func persistentDir(worker string) string { return "/tmp/ac-p-" + worker }
func persistentAPI(worker string) string { return filepath.Join(persistentDir(worker), "api") }

func (p sshProfile) persistentCommand(arguments ...string) string {
	command := "exec " + quoteShell(p.Agentctl) + " persistent-acp"
	for _, arg := range arguments {
		command += " " + quoteShell(arg)
	}
	return command
}

// RunPersistentACP handles private broker and host commands. The remote host
// exposes its streams only through sockets in the login's private directory.
func RunPersistentACP(ctx context.Context, args []string, input io.Reader, output io.Writer) error {
	if len(args) == 1 && args[0] == "proxy" {
		var cfg persistentProxy
		if err := json.Unmarshal([]byte(os.Getenv(persistentACPConfig)), &cfg); err != nil {
			return errors.New("invalid persistent ACP proxy configuration")
		}
		if !validID.MatchString(cfg.Worker) || !filepath.IsAbs(cfg.LocalSocket) ||
			!filepath.IsAbs(cfg.OwnerSocket) || !sshAlias.MatchString(cfg.Profile.Host) || !filepath.IsAbs(cfg.Profile.Agentctl) {
			return errors.New("invalid persistent ACP proxy target")
		}
		return sshlink.Run(ctx, input, output, cfg.connect, cfg.reportConnection)
	}
	if len(args) < 2 || !validID.MatchString(args[1]) {
		return errors.New("invalid persistent ACP worker")
	}
	dir := persistentDir(args[1])
	switch {
	case args[0] == "start" && len(args) == 4 && filepath.IsAbs(args[2]) && filepath.IsAbs(args[3]):
		return startPersistentHost(ctx, dir, args[1:])
	case args[0] == "host" && len(args) == 4 && filepath.IsAbs(args[2]) && filepath.IsAbs(args[3]):
		return servePersistentHost(ctx, dir, args[2], args[3])
	case args[0] == "connect" && len(args) == 3:
		return connectPersistentHost(ctx, dir, args[1], args[2], input, output)
	case args[0] == "stop" && len(args) == 2:
		return stopPersistentHost(ctx, dir)
	default:
		return errors.New("invalid persistent ACP command")
	}
}

func stopPersistentHost(ctx context.Context, dir string) error {
	conn, err := (&net.Dialer{Timeout: time.Second}).DialContext(ctx, "unix", filepath.Join(dir, "stop"))
	if err != nil && !errors.Is(err, os.ErrNotExist) && !errors.Is(err, syscall.ECONNREFUSED) {
		return err
	}
	if conn != nil {
		_ = conn.Close()
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	for {
		_, err := os.Lstat(dir)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-tick.C:
		}
	}
}

func startPersistentHost(ctx context.Context, dir string, args []string) error {
	if err := os.Mkdir(dir, 0700); err != nil {
		return fmt.Errorf("reserve persistent worker directory: %w", err)
	}
	binary, err := os.Executable()
	if err != nil {
		_ = os.Remove(dir)
		return err
	}
	cmd := exec.Command(binary, append([]string{"persistent-acp", "host"}, args...)...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		_ = os.Remove(dir)
		return err
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	timeout, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-timeout.Done():
			_ = cmd.Process.Kill()
			return timeout.Err()
		case err := <-exited:
			return fmt.Errorf("persistent ACP host exited during startup: %v", err)
		case <-ticker.C:
			conn, err := (&net.Dialer{Timeout: time.Second}).DialContext(timeout, "unix", filepath.Join(dir, "stream"))
			if err == nil {
				return conn.Close()
			}
		}
	}
}

func servePersistentHost(ctx context.Context, dir, adapter, cwd string) error {
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || info.Mode().Perm() != 0700 || int(info.Sys().(*syscall.Stat_t).Uid) != os.Geteuid() {
		return errors.New("persistent ACP host requires its private worker directory")
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	defer func() {
		for _, name := range []string{"stream", "stop", "api"} {
			_ = os.Remove(filepath.Join(dir, name))
		}
		_ = os.Remove(dir)
	}()
	listener, err := net.Listen("unix", filepath.Join(dir, "stream"))
	if err != nil {
		return err
	}
	defer listener.Close()
	stop, err := net.Listen("unix", filepath.Join(dir, "stop"))
	if err != nil {
		return err
	}
	defer stop.Close()

	cmd := exec.CommandContext(ctx, adapter)
	cmd.Dir = cwd
	toAdapter, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	defer toAdapter.Close()
	fromAdapter, writer, err := os.Pipe()
	if err != nil {
		return err
	}
	defer fromAdapter.Close()
	cmd.Stdout = writer
	err = cmd.Start()
	_ = writer.Close()
	if err != nil {
		return err
	}
	defer func() {
		cancel()
		_ = cmd.Wait()
	}()
	host := sshlink.NewHost(ctx, toAdapter, fromAdapter)
	go func() {
		link, err := stop.Accept()
		if err == nil {
			_ = link.Close()
			cancel()
		}
	}()
	unblock := context.AfterFunc(ctx, func() { _ = listener.Close() })
	defer unblock()
	// Only one link can own the conversation. A lost SSH process closes its
	// pipe and disconnects the old link before the replacement takes over.
	for ctx.Err() == nil {
		link, err := listener.Accept()
		if err != nil {
			return err
		}
		closeLink := context.AfterFunc(ctx, func() { _ = link.Close() })
		_ = host.Serve(link)
		closeLink()
		_ = link.Close()
	}
	return ctx.Err()
}

func connectPersistentHost(ctx context.Context, dir, worker, remoteSocket string, input io.Reader, output io.Writer) error {
	prefix := "/tmp/ac-f-" + worker + "-"
	if len(remoteSocket) != len(prefix)+16 || remoteSocket[:len(prefix)] != prefix {
		return errors.New("invalid persistent ACP forward socket")
	}
	if _, err := hex.DecodeString(remoteSocket[len(prefix):]); err != nil {
		return errors.New("invalid persistent ACP forward generation")
	}
	info, err := os.Lstat(remoteSocket)
	if err != nil || info.Mode()&os.ModeSocket == 0 || int(info.Sys().(*syscall.Stat_t).Uid) != os.Geteuid() {
		return errors.New("expected an SSH forward socket owned by this login")
	}
	link, err := (&net.Dialer{Timeout: time.Second}).DialContext(ctx, "unix", filepath.Join(dir, "stream"))
	if err != nil {
		// A live SSH connection that cannot locate the original host is a
		// terminal outcome. The broker must never launch a replacement.
		return json.NewEncoder(output).Encode(map[string]string{"error": "original persistent ACP host is unavailable"})
	}
	defer link.Close()
	temporary := filepath.Join(dir, "api-"+remoteSocket[len(prefix):])
	if err := os.Symlink(remoteSocket, temporary); err != nil {
		return err
	}
	defer os.Remove(temporary)
	if err := os.Rename(temporary, filepath.Join(dir, "api")); err != nil {
		return err
	}
	defer os.Remove(remoteSocket)
	go func() {
		_, _ = io.Copy(link, input)
		_ = link.Close()
	}()
	cancel := context.AfterFunc(ctx, func() { _ = link.Close() })
	defer cancel()
	_, err = io.Copy(output, link)
	return err
}

type sshStream struct {
	command *exec.Cmd
	read    io.ReadCloser
	write   io.WriteCloser
	close   sync.Once
}

func (s *sshStream) Read(p []byte) (int, error)  { return s.read.Read(p) }
func (s *sshStream) Write(p []byte) (int, error) { return s.write.Write(p) }
func (s *sshStream) Close() error {
	s.close.Do(func() {
		_ = s.write.Close()
		_ = s.read.Close()
		_ = s.command.Process.Kill()
		_ = s.command.Wait()
	})
	return nil
}

func (p persistentProxy) start(ctx context.Context) error {
	args := p.Profile.command(nil, p.Profile.persistentCommand("start", p.Worker, p.Profile.Adapter, p.Profile.Checkout))
	cmd := exec.CommandContext(ctx, "/usr/bin/ssh", args...)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("start persistent ACP host: %w: %s", err, out)
	}
	return nil
}

func (p persistentProxy) stop() error {
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	args := p.Profile.command(nil, p.Profile.persistentCommand("stop", p.Worker))
	return exec.CommandContext(ctx, "/usr/bin/ssh", args...).Run()
}

func (p persistentProxy) reportConnection(connected bool) {
	connection := "reconnecting"
	if connected {
		connection = "connected"
	}
	owner := &api{localapi.New(p.OwnerSocket, "")}
	_ = owner.request("POST", "/v1/workers/"+p.Worker+"/ssh-link", map[string]string{"connection": connection}, nil)
}

func (p persistentProxy) connect(ctx context.Context) (io.ReadWriteCloser, error) {
	var generation [8]byte
	if _, err := rand.Read(generation[:]); err != nil {
		return nil, err
	}
	remote := "/tmp/ac-f-" + p.Worker + "-" + hex.EncodeToString(generation[:])
	args := p.Profile.command([]string{
		"-R", remote + ":" + p.LocalSocket, "-o", "ExitOnForwardFailure=yes", "-o", "StreamLocalBindMask=0177",
	}, p.Profile.persistentCommand("connect", p.Worker, remote))
	cmd := exec.CommandContext(ctx, "/usr/bin/ssh", args...)
	stream := &sshStream{command: cmd}
	var err error
	stream.read, err = cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stream.write, err = cmd.StdinPipe()
	if err != nil {
		_ = stream.read.Close()
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		_ = stream.read.Close()
		_ = stream.write.Close()
		return nil, err
	}
	return stream, nil
}

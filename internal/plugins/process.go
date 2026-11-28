package plugins

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"agentcommander/internal/buildinfo"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const (
	defaultStartTimeout = 10 * time.Second
	defaultIdleTimeout  = 15 * time.Minute
	restartBackoff      = 2 * time.Second
	maxLogBytes         = 4 << 20
	terminateGrace      = 2 * time.Second
)

// baseEnv lists the host variables a plugin may inherit without declaring them.
var baseEnv = []string{"PATH", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME", "SHELL"}

// launch describes how to start one plugin process.
type launch struct {
	id, version, dir, dataDir, logPath string
	command, envAllow                  []string
	fallback                           string
	// environ supplies the parent environment; tests replace it.
	environ func() []string
}

func (r Record) launch(stateDir string) launch {
	return launch{
		id: r.ID, version: r.Version, dir: r.Dir(stateDir), dataDir: r.DataDir(stateDir),
		logPath: r.LogPath(stateDir), command: r.Command, envAllow: r.EnvAllow, environ: os.Environ,
		fallback: r.Program,
	}
}

// env builds the plugin's environment from an allowlist. Commander's token,
// sockets and any AGENT_COMMANDER_* setting never pass through.
func (l launch) env() []string {
	parent := map[string]string{}
	for _, kv := range l.environ() {
		if name, value, ok := strings.Cut(kv, "="); ok {
			parent[name] = value
		}
	}
	var env []string
	for _, name := range append(append([]string{}, baseEnv...), l.envAllow...) {
		if value, ok := parent[name]; ok {
			env = append(env, name+"="+value)
		}
	}
	return append(env,
		"HOME="+l.dataDir,
		"AGENT_COMMANDER_PLUGIN_ID="+l.id,
		"AGENT_COMMANDER_PLUGIN_VERSION="+l.version,
		"AGENT_COMMANDER_PLUGIN_DIR="+l.dir,
		"AGENT_COMMANDER_PLUGIN_DATA="+l.dataDir,
	)
}

// program resolves the manifest command against the package or PATH.
func (l launch) program() (string, error) {
	name := l.command[0]
	if strings.ContainsRune(name, '/') {
		path := filepath.Join(l.dir, filepath.Clean(name))
		info, err := os.Stat(path)
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o100 == 0 {
			return "", fmt.Errorf("plugin command %s is not an executable file in the package", name)
		}
		return path, nil
	}
	for _, kv := range l.env() {
		if path, ok := strings.CutPrefix(kv, "PATH="); ok {
			for _, dir := range filepath.SplitList(path) {
				candidate := filepath.Join(dir, name)
				if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0 && filepath.IsAbs(candidate) {
					return candidate, nil
				}
			}
		}
	}
	if l.fallback != "" && filepath.IsAbs(l.fallback) && filepath.Base(l.fallback) == name {
		if info, err := os.Stat(l.fallback); err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0 {
			return l.fallback, nil
		}
	}
	return "", fmt.Errorf("plugin command %s was not found on PATH", name)
}

// connect starts the process and completes the MCP handshake within ctx.
func (l launch) connect(ctx context.Context) (*mcp.ClientSession, error) {
	program, err := l.program()
	if err != nil {
		return nil, err
	}
	if err := ensurePrivateDir(l.dataDir); err != nil {
		return nil, err
	}
	logFile, err := openLog(l.logPath)
	if err != nil {
		return nil, err
	}
	// The command outlives ctx; the session's Close stops it.
	cmd := exec.Command(program, l.command[1:]...)
	cmd.Dir, cmd.Env, cmd.Stderr = l.dir, l.env(), logFile
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	transport := &mcp.CommandTransport{Command: cmd, TerminateDuration: terminateGrace}
	client := mcp.NewClient(&mcp.Implementation{Name: "agent-commander", Version: buildinfo.Current()}, nil)
	session, err := client.Connect(ctx, transport, nil)
	if err != nil {
		killGroup(cmd)
		logFile.Close()
		return nil, fmt.Errorf("start plugin %s: %w", l.id, err)
	}
	go func() {
		_ = session.Wait()
		killGroup(cmd)
		logFile.Close()
	}()
	return session, nil
}

// killGroup stops any children the plugin left behind in its process group.
func killGroup(cmd *exec.Cmd) {
	if cmd.Process != nil {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
}

func openLog(path string) (*os.File, error) {
	if err := ensurePrivateDir(filepath.Dir(path)); err != nil {
		return nil, err
	}
	flags := os.O_CREATE | os.O_WRONLY | os.O_APPEND
	if info, err := os.Stat(path); err == nil && info.Size() > maxLogBytes {
		flags |= os.O_TRUNC
	}
	return os.OpenFile(path, flags, 0o600)
}

// supervisor owns one plugin's process: it starts lazily, restarts after an
// exit or a timed-out call, and stops after an idle period.
type supervisor struct {
	launch       launch
	verify       func() error
	startTimeout time.Duration
	idleTimeout  time.Duration

	mu         sync.Mutex
	session    *mcp.ClientSession
	starting   chan struct{}
	startErr   error
	lastFail   time.Time
	idle       *time.Timer
	generation int
	closed     bool
}

func newSupervisor(l launch, verify func() error) *supervisor {
	return &supervisor{launch: l, verify: verify, startTimeout: defaultStartTimeout, idleTimeout: defaultIdleTimeout}
}

var errStopped = errors.New("plugin host stopped")

// get returns a live session, starting the process if needed. Concurrent
// callers share one start, and each stops waiting when its ctx ends.
func (s *supervisor) get(ctx context.Context) (*mcp.ClientSession, int, error) {
	for {
		s.mu.Lock()
		if s.closed {
			s.mu.Unlock()
			return nil, 0, errStopped
		}
		if s.session != nil {
			session, generation := s.session, s.generation
			s.touchLocked()
			s.mu.Unlock()
			return session, generation, nil
		}
		if wait := s.starting; wait != nil {
			s.mu.Unlock()
			select {
			case <-wait:
				continue
			case <-ctx.Done():
				return nil, 0, ctx.Err()
			}
		}
		if !s.lastFail.IsZero() && time.Since(s.lastFail) < restartBackoff {
			err := s.startErr
			s.mu.Unlock()
			return nil, 0, err
		}
		// The start runs on its own, so the caller that began it waits on it or
		// its own deadline like every other caller: a slow package check or
		// handshake never holds a call past the tool's deadline.
		done := make(chan struct{})
		s.starting = done
		s.mu.Unlock()
		go s.finishStart(done)
	}
}

// finishStart starts the process and publishes the session, or the failure
// that callers see until the restart backoff passes.
func (s *supervisor) finishStart(done chan struct{}) {
	session, err := s.start()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.starting = nil
	defer close(done)
	if err != nil {
		s.startErr, s.lastFail = err, time.Now()
		return
	}
	if s.closed {
		go session.Close()
		return
	}
	s.session, s.startErr, s.lastFail = session, nil, time.Time{}
	s.generation++
	s.touchLocked()
	go s.watch(session, s.generation)
}

func (s *supervisor) start() (*mcp.ClientSession, error) {
	if s.verify != nil {
		if err := s.verify(); err != nil {
			return nil, err
		}
	}
	// A start is not tied to the first caller's deadline, so a slow first
	// call does not leave a half-started process behind.
	ctx, cancel := context.WithTimeout(context.Background(), s.startTimeout)
	defer cancel()
	return s.launch.connect(ctx)
}

// watch forgets a session once its process exits so the next call restarts it.
func (s *supervisor) watch(session *mcp.ClientSession, generation int) {
	_ = session.Wait()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.generation == generation && s.session == session {
		s.session = nil
	}
}

// discard stops a session that misbehaved, such as one that missed a deadline.
func (s *supervisor) discard(generation int) {
	s.mu.Lock()
	session := s.session
	if s.generation != generation || session == nil {
		s.mu.Unlock()
		return
	}
	s.session = nil
	s.mu.Unlock()
	go session.Close()
}

func (s *supervisor) touchLocked() {
	if s.idleTimeout <= 0 {
		return
	}
	generation := s.generation
	if s.idle != nil {
		s.idle.Stop()
	}
	s.idle = time.AfterFunc(s.idleTimeout, func() { s.discard(generation) })
}

// warm starts the process in the background so the first call is fast.
func (s *supervisor) warm() {
	go func() { _, _, _ = s.get(context.Background()) }()
}

func (s *supervisor) close() {
	s.mu.Lock()
	s.closed = true
	session := s.session
	s.session = nil
	if s.idle != nil {
		s.idle.Stop()
	}
	s.mu.Unlock()
	if session != nil {
		_ = session.Close()
	}
}

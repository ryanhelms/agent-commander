package harness

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Attachment names the tmux session a login or install runs in. The cockpit
// attaches to it with the native terminal viewer.
type Attachment struct {
	HarnessID  string `json:"harness_id"`
	Purpose    string `json:"purpose"`
	SocketPath string `json:"socket_path"`
	SessionID  string `json:"session_id"`
}

// ErrNoCommand reports a harness without a login or install command.
var ErrNoCommand = errors.New("this harness has no command for that")

type sessions struct {
	env     Env
	label   string
	tmux    func() (string, error)
	onEnd   func(id string)
	mu      sync.Mutex
	running map[string]Attachment
}

func newSessions(stateDir string, env Env, onEnd func(string)) *sessions {
	sum := sha256.Sum256([]byte(stateDir))
	s := &sessions{env: env, label: fmt.Sprintf("ac-harness-%x", sum[:6]), onEnd: onEnd, running: map[string]Attachment{}}
	s.tmux = func() (string, error) {
		if path := env.Getenv("AGENT_COMMANDER_TMUX"); path != "" {
			if !filepath.IsAbs(path) {
				return "", errors.New("AGENT_COMMANDER_TMUX must contain an absolute path")
			}
			return path, nil
		}
		if path := env.lookPath("tmux"); path != "" {
			return path, nil
		}
		return "", errors.New("tmux is required to run a harness login")
	}
	return s
}

var tmuxSessionID = regexp.MustCompile(`^\$[0-9]+$`)

// holdOpen runs the command, then waits for Return so its output stays readable.
const holdOpen = `"$@"; code=$?; printf '\n%s exited with status %s. Press Return to close.' "$1" "$code"; read _; exit $code`

// Login starts the harness's own login command in a dedicated tmux session.
func (m *Monitor) Login(ctx context.Context, id string) (Attachment, error) {
	e, ok := m.entry(id)
	if !ok {
		return Attachment{}, ErrUnknown
	}
	status, err := m.Check(ctx, id)
	if err != nil {
		return Attachment{}, err
	}
	if !status.Login.Available || status.Executable == "" {
		return Attachment{}, ErrNoCommand
	}
	return m.sessions.open(ctx, e, "login", append([]string{status.Executable}, e.Login...))
}

// Install starts the harness's install command in a dedicated tmux session.
func (m *Monitor) Install(ctx context.Context, id string) (Attachment, error) {
	e, ok := m.entry(id)
	if !ok {
		return Attachment{}, ErrUnknown
	}
	install := installAction(m.env, e)
	if !install.Available {
		return Attachment{}, ErrNoCommand
	}
	argv := e.Install
	if e.InstallScript != "" {
		argv = []string{"/bin/sh", "-c", e.InstallScript}
	} else if path := m.env.lookPath(argv[0]); path != "" {
		argv = append([]string{path}, argv[1:]...)
	}
	return m.sessions.open(ctx, e, "install", argv)
}

func (s *sessions) open(ctx context.Context, e Entry, purpose string, argv []string) (Attachment, error) {
	tmux, err := s.tmux()
	if err != nil {
		return Attachment{}, err
	}
	name := purpose + "-" + e.ID
	s.mu.Lock()
	defer s.mu.Unlock()
	if existing, ok := s.running[name]; ok && s.alive(ctx, tmux, name) {
		return existing, nil
	}
	dir := s.env.Home
	if home := s.env.profileHome(e); home != "" {
		dir = home
	}
	args := []string{"-L", s.label, "-f", "/dev/null", "new-session", "-d", "-s", name, "-x", "120", "-y", "32", "-c", dir}
	for _, kv := range s.env.CommandEnv(e) {
		args = append(args, "-e", kv)
	}
	args = append(args, append([]string{"/bin/sh", "-c", holdOpen, "sh"}, argv...)...)
	if out, err := exec.CommandContext(ctx, tmux, args...).CombinedOutput(); err != nil {
		return Attachment{}, fmt.Errorf("could not start the %s session: %s", purpose, strings.TrimSpace(string(out)))
	}
	raw, err := exec.CommandContext(ctx, tmux, "-N", "-L", s.label, "display-message", "-p", "-t", "="+name+":", "#{session_id} #{socket_path}").Output()
	if err != nil {
		return Attachment{}, fmt.Errorf("could not read the %s session: %w", purpose, err)
	}
	// tmux rewrites a tab in its output, so the session ID, which has no spaces, comes first.
	session, socket, _ := strings.Cut(strings.TrimSpace(string(raw)), " ")
	if !filepath.IsAbs(socket) || !tmuxSessionID.MatchString(session) {
		return Attachment{}, errors.New("tmux returned an unexpected session")
	}
	a := Attachment{HarnessID: e.ID, Purpose: purpose, SocketPath: socket, SessionID: session}
	s.running[name] = a
	go s.awaitEnd(tmux, name, e.ID)
	return a, nil
}

func (s *sessions) alive(ctx context.Context, tmux, name string) bool {
	return exec.CommandContext(ctx, tmux, "-N", "-L", s.label, "has-session", "-t", "="+name).Run() == nil
}

// awaitEnd checks once a second, only while the session is open, and re-probes when it ends.
func (s *sessions) awaitEnd(tmux, name, id string) {
	for {
		time.Sleep(time.Second)
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		alive := s.alive(ctx, tmux, name)
		cancel()
		if !alive {
			break
		}
	}
	s.mu.Lock()
	delete(s.running, name)
	s.mu.Unlock()
	s.onEnd(id)
}

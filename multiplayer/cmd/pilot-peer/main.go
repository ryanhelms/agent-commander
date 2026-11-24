//go:build pilotfixture

// Command pilot-peer runs one isolated Linux participant in the Docker rehearsal.
package main

import (
	"bytes"
	"context"
	"crypto/rand"

	"encoding/hex"
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
	"regexp"
	"strings"
	"syscall"
	"time"

	"agentcommander.network/pilot/internal/device"
	"agentcommander.network/pilot/internal/devicekeys"
)

const (
	stateDir        = "/participant"
	networkSocket   = stateDir + "/network.sock"
	commanderSocket = stateDir + "/commander.sock"
	checkout        = stateDir + "/checkout"
	trustFile       = "/fixture/trust.pem"
	browserToken    = "/fixture/browser-token"
	githubToken     = "/fixture/github-token"
	relayOrigin     = "https://srv01.agentmux.bytedesk.ai:8443"
	issuerOrigin    = "https://issuer.rehearsal.test:8443"
	githubOrigin    = "https://github.rehearsal.test:8443"
)

var resourceID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,100}$`)

type actor struct{ Run, Worker, Token string }
type actors struct{ Main, Other actor }

func credential() (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}
func readSecret(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", errors.New("fixture credential unavailable")
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, 4097))
	v := strings.TrimSpace(string(b))
	if err != nil || v == "" || len(b) > 4096 || strings.ContainsAny(v, "\r\n\x00") {
		return "", errors.New("invalid fixture credential")
	}
	return v, nil
}
func runGit(ctx context.Context, dir string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "/usr/bin/git", append([]string{"-c", "core.hooksPath=/dev/null", "-c", "user.name=Pilot rehearsal", "-c", "user.email=peer@rehearsal.test"}, args...)...)
	cmd.Dir = dir
	cmd.Env = []string{"PATH=/usr/bin:/bin", "HOME=" + stateDir, "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_TERMINAL_PROMPT=0"}
	b, err := cmd.Output()
	return strings.TrimSpace(string(b)), err
}
func prepareRepos(ctx context.Context, handle string) error {
	if _, err := runGit(ctx, stateDir, "init", "--template=", "-b", "main", checkout); err != nil {
		return err
	}
	if _, err := runGit(ctx, checkout, "rev-parse", "--verify", "HEAD"); err != nil {
		if _, err = runGit(ctx, checkout, "commit", "--allow-empty", "-qm", "Start rehearsal checkout"); err != nil {
			return err
		}
	}
	want := "https://github.com/" + handle + "/pilot.git"
	origin, err := runGit(ctx, checkout, "config", "--local", "--get", "remote.origin.url")
	if err != nil && origin == "" {
		_, err = runGit(ctx, checkout, "remote", "add", "origin", want)
		return err
	}
	if err != nil || origin != want {
		return errors.New("pilot checkout has unexpected origin")
	}
	return nil
}
func unixService(path string, h http.Handler) (*http.Server, error) {
	fi, err := os.Lstat(path)
	if err == nil {
		if fi.Mode()&os.ModeSocket == 0 {
			return nil, errors.New("fixture socket path is occupied")
		}
		if err = os.Remove(path); err != nil {
			return nil, err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err = os.Chmod(path, 0600); err != nil {
		ln.Close()
		return nil, err
	}
	s := &http.Server{Handler: h, ReadHeaderTimeout: 5 * time.Second, MaxHeaderBytes: 8192}
	go s.Serve(ln)
	return s, nil
}
func issueActors(handle string) (actors, error) {
	fresh := actors{}
	for i, name := range []string{handle, handle + "-other"} {
		token, err := credential()
		if err != nil {
			return fresh, err
		}
		a := actor{name + "-run", name + "-coordinator", token}
		if i == 0 {
			fresh.Main = a
		} else {
			fresh.Other = a
		}
	}
	b, err := json.Marshal(fresh)
	if err != nil {
		return actors{}, err
	}
	return fresh, os.WriteFile(stateDir+"/actor.json", b, 0600)
}
func serve(ctx context.Context, handle string) error {
	if os.Geteuid() == 0 {
		return errors.New("pilot peer must run as a nonroot user")
	}
	for k, want := range map[string]string{"PILOT_PEER_RELAY": relayOrigin, "PILOT_PEER_ISSUER": issuerOrigin, "PILOT_PEER_CA": trustFile, "PILOT_PEER_GITHUB": githubOrigin, "PILOT_PEER_BROWSER_TOKEN_FILE": browserToken, "PILOT_PEER_GITHUB_TOKEN_FILE": githubToken} {
		if v := os.Getenv(k); v != "" && v != want {
			return fmt.Errorf("unexpected fixture setting %s", k)
		}
	}
	fi, err := os.Lstat(stateDir)
	if err != nil || !fi.IsDir() || fi.Mode().Perm()&0077 != 0 {
		return errors.New("participant volume requires owner-only access")
	}
	lock, err := os.OpenFile(stateDir+"/.lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if syscall.Flock(int(lock.Fd()), syscall.LOCK_NB|syscall.LOCK_EX) != nil {
		return errors.New("another participant process owns the state volume")
	}
	roots, err := fixtureRoots()
	if err != nil {
		return err
	}
	if err = prepareRepos(ctx, handle); err != nil {
		return err
	}
	ids, err := issueActors(handle)
	if err != nil {
		return err
	}
	command, err := unixService(commanderSocket, commanderFixture(handle, ids))
	if err != nil {
		return err
	}
	defer command.Close()
	upstream := fixtureHTTP(roots)
	defer upstream.CloseIdleConnections()
	if err = checkPrivateOrigins(ctx); err != nil {
		return err
	}
	secrets, err := devicekeys.Directory(filepath.Join(stateDir, "secrets"))
	if err != nil {
		return err
	}
	a, err := device.New(ctx, device.Config{Relay: relayOrigin, Dir: filepath.Join(stateDir, "network"), CommanderSocket: commanderSocket, Secrets: secrets, Roots: roots, OpenBrowser: rehearsalBrowser(ctx, upstream), OIDCHTTP: upstream})
	if err != nil {
		return err
	}
	defer a.Close()
	local, err := unixService(networkSocket, a.Handler())
	if err != nil {
		return err
	}
	defer local.Close()
	<-ctx.Done()
	return nil
}
func call(ctx context.Context, path string, other bool) error {
	if !regexp.MustCompile(`^/(tray|coordinator)/[a-z][a-z-]{0,32}$`).MatchString(path) {
		return errors.New("expected a local tray or coordinator operation")
	}
	b, err := io.ReadAll(io.LimitReader(os.Stdin, 1<<20+1))
	if len(b) == 0 {
		b = []byte("{}")
	}
	if err != nil || len(b) > 1<<20 || !json.Valid(b) {
		return errors.New("expected one JSON request on stdin")
	}
	if path == "/tray/repo-credential" {
		var req struct {
			Resource string `json:"resource"`
		}
		d := json.NewDecoder(bytes.NewReader(b))
		d.DisallowUnknownFields()
		if d.Decode(&req) != nil || !resourceID.MatchString(req.Resource) {
			return errors.New("specify only the enrolled resource id")
		}
		t, err := readSecret(githubToken)
		if err != nil {
			return err
		}
		b, _ = json.Marshal(map[string]string{"resource": req.Resource, "token": t})
	}
	r, err := http.NewRequestWithContext(ctx, "POST", "http://peer"+path, bytes.NewReader(b))
	if err != nil {
		return err
	}
	r.Header.Set("Content-Type", "application/json")
	if strings.HasPrefix(path, "/coordinator/") {
		data, err := os.ReadFile(stateDir + "/actor.json")
		if err != nil {
			return err
		}
		var ids actors
		if json.Unmarshal(data, &ids) != nil {
			return errors.New("invalid local actor bindings")
		}
		a := ids.Main
		if other {
			a = ids.Other
		}
		r.Header.Set("Authorization", "Bearer "+a.Token)
		r.Header.Set("X-Commander-Run", a.Run)
		r.Header.Set("X-Commander-Worker", a.Worker)
	}
	tr := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", networkSocket)
	}}
	defer tr.CloseIdleConnections()
	h := http.Client{Transport: tr, Timeout: 45 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := h.Do(r)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	result, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20+1))
	if err != nil || len(result) > 4<<20 || !json.Valid(result) {
		return errors.New("invalid participant response")
	}
	if _, err = os.Stdout.Write(result); err != nil {
		return err
	}
	if resp.StatusCode != 200 {
		return errors.New("participant rejected the request")
	}
	return nil
}
func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	handle := os.Getenv("PILOT_PEER_HANDLE")
	var err error
	args := os.Args[1:]
	switch {
	case handle != "alice" && handle != "bob" && handle != "carol":
		err = errors.New("PILOT_PEER_HANDLE must be alice, bob or carol")
	case len(args) == 1 && args[0] == "serve":
		err = serve(ctx, handle)
	case len(args) == 2 && (args[0] == "call" || args[0] == "call-other"):
		err = call(ctx, args[1], args[0] == "call-other")
	case len(args) == 1 && args[0] == "info":
		var head string
		if head, err = runGit(ctx, checkout, "rev-parse", "HEAD"); err == nil {
			err = json.NewEncoder(os.Stdout).Encode(map[string]string{"handle": handle, "checkout": checkout, "origin": "https://github.com/" + handle + "/pilot.git", "worker": handle + "-worker", "coordinator": handle + "-coordinator", "other_coordinator": handle + "-other-coordinator", "run": handle + "-run", "repository": handle + "/pilot", "head": head})
		}
	case len(args) == 2 && args[0] == "published" && resourceID.MatchString(args[1]):
		err = inspect(ctx, handle, args[1])
	case len(args) == 1 && args[0] == "facts":
		err = inspect(ctx, handle, "")
	case len(args) == 1 && args[0] == "mcp":
		err = probeMCP(ctx, "", nil)
	case len(args) == 2 && args[0] == "mcp" && resourceID.MatchString(args[1]):
		err = probeMCP(ctx, args[1], nil)
	case len(args) == 1 && args[0] == "mcp-submit":
		var raw []byte
		raw, err = io.ReadAll(io.LimitReader(os.Stdin, 1<<20+1))
		if err == nil {
			if len(raw) > 1<<20 || !json.Valid(raw) {
				err = errors.New("invalid MCP submission JSON")
			} else {
				err = probeMCP(ctx, "", raw)
			}
		}
	default:
		err = errors.New("use serve, info, facts, mcp [RECEIPT], mcp-submit, published RESOURCE, call PATH, or call-other PATH")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

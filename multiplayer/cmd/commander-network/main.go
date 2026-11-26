// commander-network runs the owner's outbound relay connection and serves the native tray.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
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
	"syscall"
	"time"

	"agentcommander.network/pilot/internal/device"
	"agentcommander.network/pilot/internal/devicekeys"
)

const daemonBusyExit = 75

var errDaemonBusy = errors.New("another device agent is starting or running")

func setting(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func trustRoots(variable string) (*x509.CertPool, error) {
	name := os.Getenv(variable)
	if name == "" {
		return nil, nil
	}
	data, err := os.ReadFile(name)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", variable, err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(data) {
		return nil, fmt.Errorf("%s contains no trusted certificates", variable)
	}
	return roots, nil
}

func issuerClient() (*http.Client, error) {
	roots, err := trustRoots("COMMANDER_NETWORK_OIDC_CA")
	if err != nil || roots == nil {
		return nil, err
	}
	// Never use the relay transport for issuer discovery or token exchange.
	return &http.Client{
		Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}},
		Timeout:   20 * time.Second,
	}, nil
}

func paths() (dir, socket, commander string, err error) {
	home, e := os.UserHomeDir()
	if e != nil {
		err = e
		return
	}
	base, e := os.UserConfigDir()
	if e != nil {
		err = e
		return
	}
	root := filepath.Join(home, ".agent-commander")
	dir = setting("COMMANDER_NETWORK_STATE", filepath.Join(root, "network"))
	socket = setting("COMMANDER_NETWORK_SOCKET", filepath.Join(root, "network.sock"))
	commander = setting("AGENT_COMMANDER_SOCKET", filepath.Join(setting("AGENT_COMMANDER_HOME", filepath.Join(base, "Agent Commander")), "service.sock"))
	for _, p := range []string{dir, socket, commander} {
		if !filepath.IsAbs(p) {
			err = errors.New("multiplayer paths must be absolute")
			return
		}
	}
	return
}
func daemon(ctx context.Context, dir, socket, commander string) error {
	parent := filepath.Dir(socket)
	if e := os.MkdirAll(parent, 0700); e != nil {
		return e
	}
	st, e := os.Lstat(parent)
	if e != nil {
		return e
	}
	if !st.IsDir() || st.Mode().Perm()&0022 != 0 {
		return errors.New("network socket parent must be an owner-controlled directory")
	}
	// Both paths can be overridden. Hold the state lock even when another
	// launcher requests a different socket for the same device policy.
	if e = os.MkdirAll(dir, 0700); e != nil {
		return e
	}
	state, e := os.OpenFile(dir, os.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0)
	if e != nil {
		return e
	}
	defer state.Close()
	if e = syscall.Flock(int(state.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); e != nil {
		if errors.Is(e, syscall.EWOULDBLOCK) {
			return fmt.Errorf("%w for this state directory", errDaemonBusy)
		}
		return e
	}
	lock, e := os.OpenFile(socket+".lock", os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if e != nil {
		return e
	}
	defer lock.Close()
	if e = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); e != nil {
		if errors.Is(e, syscall.EWOULDBLOCK) {
			return fmt.Errorf("%w on this socket", errDaemonBusy)
		}
		return e
	}
	if st, e = os.Lstat(socket); e == nil {
		if st.Mode()&os.ModeSocket == 0 {
			return errors.New("network socket path occupied")
		}
		conn, err := net.DialTimeout("unix", socket, time.Second)
		if err == nil {
			conn.Close()
			return errors.New("network socket is in use")
		}
		if !errors.Is(err, syscall.ECONNREFUSED) && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if e = os.Remove(socket); e != nil {
			return e
		}
	} else if !errors.Is(e, os.ErrNotExist) {
		return e
	}
	listener, e := net.Listen("unix", socket)
	if e != nil {
		return e
	}
	defer listener.Close()
	if e = os.Chmod(socket, 0600); e != nil {
		return e
	}
	roots, e := trustRoots("COMMANDER_NETWORK_CA")
	if e != nil {
		return e
	}
	issuer, e := issuerClient()
	if e != nil {
		return e
	}
	if issuer != nil {
		defer issuer.CloseIdleConnections()
	}
	a, e := device.NewManager(ctx, device.ManagerConfig{
		Dir: dir, CommanderSocket: commander, Roots: roots, OIDCHTTP: issuer,
		SeedRelay: os.Getenv("COMMANDER_NETWORK_RELAY"),
		Secrets: func(relay string) (devicekeys.Store, error) {
			sum := sha256.Sum256([]byte(relay))
			return devicekeys.Keychain("device-" + hex.EncodeToString(sum[:]))
		},
		OpenBrowser: func(u string) error { return exec.Command("/usr/bin/open", u).Run() },
	})
	if e != nil {
		return e
	}
	defer a.Close()
	server := http.Server{Handler: a.Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 40 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8192}
	go func() { <-ctx.Done(); _ = server.Close() }()
	e = server.Serve(listener)
	if errors.Is(e, http.ErrServerClosed) {
		return nil
	}
	return e
}

var verbPattern = regexp.MustCompile("^[a-z][a-z-]{0,32}$")

func tray(ctx context.Context, socket, verb string, raw []byte) ([]byte, error) {
	if !verbPattern.MatchString(verb) || !json.Valid(raw) {
		return nil, errors.New("expected a tray operation and JSON object on stdin")
	}
	dial := func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socket)
	}
	preflight, e := dial(ctx, "", "")
	if e != nil {
		if !errors.Is(e, os.ErrNotExist) && !errors.Is(e, syscall.ECONNREFUSED) {
			return nil, e
		}
		self, e := os.Executable()
		if e != nil {
			return nil, e
		}
		cmd := exec.Command(self, "serve")
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		if e = cmd.Start(); e != nil {
			return nil, e
		}
		done := make(chan error, 1)
		go func() { done <- cmd.Wait() }()
		startup, cancel := context.WithTimeout(ctx, 15*time.Second)
		defer cancel()
		for preflight == nil {
			select {
			case <-startup.Done():
				return nil, errors.New("device agent did not start; run commander-network serve to inspect the error")
			case childErr := <-done:
				var exit *exec.ExitError
				if errors.As(childErr, &exit) && exit.ExitCode() == daemonBusyExit {
					// Another tray call won startup. It may still be opening
					// its listener, so join it under the same deadline.
					done = nil
					continue
				}
				if conn, e := dial(ctx, "", ""); e == nil {
					preflight = conn
					break
				}
				return nil, errors.New("device agent could not start; run commander-network serve for details")
			case <-time.After(75 * time.Millisecond):
				preflight, _ = dial(ctx, "", "")
			}
		}
	}
	preflight.Close()
	transport := &http.Transport{DialContext: dial}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 35 * time.Second}
	req, e := http.NewRequestWithContext(ctx, "POST", "http://local/tray/"+verb, bytes.NewReader(raw))
	if e != nil {
		return nil, e
	}
	req.Header.Set("Content-Type", "application/json")
	resp, e := client.Do(req)
	if e != nil {
		return nil, e
	}
	defer resp.Body.Close()
	b, e := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if e != nil {
		return nil, e
	}
	if !json.Valid(b) {
		return nil, errors.New("invalid local device response")
	}
	return b, nil
}
func run() error {
	dir, socket, commander, e := paths()
	if e != nil {
		return e
	}
	if len(os.Args) == 2 && os.Args[1] == "serve" {
		ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer cancel()
		return daemon(ctx, dir, socket, commander)
	}
	if len(os.Args) != 3 || os.Args[1] != "tray" {
		return errors.New("usage: commander-network serve | commander-network tray VERB < request.json")
	}
	raw, e := io.ReadAll(io.LimitReader(os.Stdin, 98305))
	if e != nil {
		return e
	}
	if len(raw) > 98304 {
		return errors.New("tray input too large")
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		raw = []byte("{}")
	}
	b, e := tray(context.Background(), socket, os.Args[2], raw)
	if e != nil {
		return e
	}
	_, e = os.Stdout.Write(b)
	return e
}
func main() {
	if e := run(); e != nil {
		if len(os.Args) > 1 && os.Args[1] == "tray" {
			_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": false, "error": e.Error()})
		} else {
			fmt.Fprintln(os.Stderr, e)
		}
		if errors.Is(e, errDaemonBusy) {
			os.Exit(daemonBusyExit)
		}
		os.Exit(1)
	}
}

package provider

import (
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	"agentcommander/internal/service"
)

type sshProfile struct {
	Host, LocalCheckout, Checkout, Adapter, Agentctl, ConfigFile string
	Persistent                                                   bool
}

var sshAlias = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$`)

func configuredSSHProfile() (sshProfile, error) {
	p := sshProfile{
		Host:          os.Getenv("AGENT_COMMANDER_SSH_HOST"),
		LocalCheckout: os.Getenv("AGENT_COMMANDER_SSH_LOCAL_CHECKOUT"),
		Checkout:      os.Getenv("AGENT_COMMANDER_SSH_CHECKOUT"),
		Adapter:       os.Getenv("AGENT_COMMANDER_SSH_ADAPTER"),
		Agentctl:      os.Getenv("AGENT_COMMANDER_SSH_AGENTCTL"),
		ConfigFile:    os.Getenv("AGENT_COMMANDER_SSH_CONFIG"),
		Persistent:    os.Getenv("AGENT_COMMANDER_SSH_MODE") == "persistent",
	}
	if mode := os.Getenv("AGENT_COMMANDER_SSH_MODE"); mode != "" && mode != "ssh-only" && mode != "persistent" {
		return sshProfile{}, errors.New("SSH mode must be ssh-only or persistent")
	}
	if !sshAlias.MatchString(p.Host) || strings.EqualFold(p.Host, "localhost") {
		return sshProfile{}, errors.New("configure a distinct SSH host alias")
	}
	if !filepath.IsAbs(p.LocalCheckout) || p.ConfigFile != "" && !filepath.IsAbs(p.ConfigFile) ||
		!path.IsAbs(p.Checkout) || !path.IsAbs(p.Adapter) || !path.IsAbs(p.Agentctl) {
		return sshProfile{}, errors.New("SSH profile requires absolute checkout and executable paths")
	}
	p.Checkout = path.Clean(p.Checkout)
	return p, nil
}

func (p sshProfile) harnessInstance() string { return "ssh-" + p.Host + "-claude" }

func (*Local) WorkerCheckout(host, localCheckout, client string) (string, error) {
	p, err := configuredSSHProfile()
	if err != nil || host != p.Host || filepath.Clean(localCheckout) != filepath.Clean(p.LocalCheckout) {
		return "", errors.New("no SSH checkout is configured for this host and project")
	}
	if !slices.Contains([]string{"claude", "claude code"}, strings.ToLower(strings.TrimSpace(client))) {
		return "", fmt.Errorf("managed client %q is unavailable on SSH", client)
	}
	return path.Clean(p.Checkout), nil
}

func (p sshProfile) command(args []string, command string) []string {
	base := []string{"-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2"}
	if p.ConfigFile != "" {
		base = append(base, "-F", p.ConfigFile)
	}
	return append(append(base, args...), "--", p.Host, command)
}

func quoteShell(path string) string {
	return "'" + strings.ReplaceAll(path, "'", "'\"'\"'") + "'"
}

// A worker forward can reach the shared API only with that job's credential.
// The downstream API applies the same authorization rules as the local MCP.
func startWorkerForward(ownerSocket, token string) (string, func(), error) {
	if token == "" {
		return "", nil, errors.New("worker forward requires a credential")
	}
	dir, err := os.MkdirTemp("/tmp", "ac-forward-")
	if err != nil {
		return "", nil, err
	}
	socket := filepath.Join(dir, "api.sock")
	l, err := net.Listen("unix", socket)
	if err != nil {
		_ = os.Remove(dir)
		return "", nil, err
	}
	dialer := net.Dialer{Timeout: 3 * time.Second}
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return dialer.DialContext(ctx, "unix", ownerSocket)
	}, ResponseHeaderTimeout: 30 * time.Second}
	proxy := &httputil.ReverseProxy{Transport: transport, Rewrite: func(req *httputil.ProxyRequest) {
		req.SetURL(&url.URL{Scheme: "http", Host: "localhost"})
		req.Out.Header.Set("Authorization", "Bearer "+token)
	}}
	server := &http.Server{ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 15 * time.Second}
	server.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		values := r.Header.Values("Authorization")
		if len(values) != 1 || subtle.ConstantTimeCompare([]byte(values[0]), []byte("Bearer "+token)) != 1 {
			http.Error(w, "worker credential required", http.StatusUnauthorized)
			return
		}
		proxy.ServeHTTP(w, r)
	})
	go func() { _ = server.Serve(l) }()
	return socket, func() {
		_ = server.Close()
		_ = l.Close()
		transport.CloseIdleConnections()
		_ = os.Remove(dir)
	}, nil
}

func (p sshProfile) sessionArgs(w service.LaunchSpec, localSocket string) ([]string, string) {
	// The remote basename is unique to this worker. The SSH login owns the socket.
	remoteSocket := "/tmp/ac-" + w.ID + ".sock"
	return p.command([]string{"-R", remoteSocket + ":" + localSocket, "-o", "ExitOnForwardFailure=yes", "-o", "StreamLocalBindMask=0177"},
		"exec "+quoteShell(p.Adapter)), remoteSocket
}

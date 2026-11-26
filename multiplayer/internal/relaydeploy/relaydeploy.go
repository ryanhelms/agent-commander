// Package relaydeploy installs commander-relay host mode on a Linux server
// over SSH, as one Docker container or one systemd service, and checks the
// result the way Agent Commander does when it adds a server. It replaces
// multiplayer/deploy/remote/remote.py. Transport comes from hostkit/sshx;
// the server-side install is commander-relay's own `host provision`, `host
// init` and `host configure`, so this package never edits relay state.
package relaydeploy

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"agentcommander.network/hostkit/sshx"
	"agentcommander.network/pilot/internal/hostmode"
)

// Names on the server.
const (
	Image          = "agent-commander-relay"
	Container      = "agent-commander-relay"
	Volume         = "agent-commander-relay"
	Unit           = "agent-commander-relay.service"
	ContainerPort  = 8443
	Sidecar        = "agent-commander-relay-tailnet"
	SidecarVolume  = "agent-commander-relay-tailnet"
	TailscaleImage = "tailscale/tailscale:stable"
	tsSocket       = "/var/lib/tailscale/tailscaled.sock"
)

// Tailnet joins the relay to a Headscale or Tailscale network in Docker mode.
type Tailnet struct {
	LoginServer string
	AuthKeyFile string // otherwise TS_AUTHKEY
	Hostname    string // default agent-relay
	Tags        []string
	LocalPort   int // loopback port behind tailscale serve, default 18443
	Image       string
}

// Options describe one deploy.
type Options struct {
	Mode   string // docker or systemd
	Target sshx.Target
	// Module is the multiplayer module directory, used to build the binary
	// or image for the server's architecture.
	Module string
	// Binary is a prebuilt Linux commander-relay for systemd mode.
	Binary         string
	Config         hostmode.Config // name, hostnames, issuer, client ID, admins, allowed emails
	Port           int
	Bind           string
	PublicURL      string
	NoConnect      bool
	ConnectAddress string
	Tailnet        *Tailnet
	Log            func(string)
}

// Result is what deploy prints.
type Result struct {
	Mode    string        `json:"mode"`
	URL     string        `json:"url"`
	Pin     string        `json:"pin"`
	Tailnet *TailnetState `json:"tailnet,omitempty"`
	Check   *CheckResult  `json:"check,omitempty"`
}

// TailnetState is the sidecar's node on the tailnet.
type TailnetState struct {
	Tailnet   string   `json:"tailnet"`
	DNS       string   `json:"dns"`
	Addresses []string `json:"addresses"`
	Tags      []string `json:"tags"`
}

func (o Options) log(format string, args ...any) {
	if o.Log != nil {
		o.Log(fmt.Sprintf(format, args...))
	}
}

// remote wraps the target with root and Docker prefixes.
type remote struct {
	sshx.Target
	sudo   *string
	docker string
}

func (r *remote) run(ctx context.Context, script string) (string, error) {
	out, err := r.Run(ctx, script, nil)
	return strings.TrimSpace(string(out)), err
}

func (r *remote) ok(ctx context.Context, script string) bool {
	_, err := r.Run(ctx, script, nil)
	return err == nil
}

func (r *remote) sudoPrefix(ctx context.Context) (string, error) {
	if r.sudo == nil {
		uid, err := r.run(ctx, "id -u")
		if err != nil {
			return "", err
		}
		prefix := "sudo -n "
		if uid == "0" {
			prefix = ""
		}
		r.sudo = &prefix
	}
	return *r.sudo, nil
}

func (r *remote) dockerPrefix(ctx context.Context) (string, error) {
	if r.docker != "" {
		return r.docker, nil
	}
	if r.ok(ctx, "docker info >/dev/null 2>&1") {
		r.docker = "docker"
		return r.docker, nil
	}
	sudo, err := r.sudoPrefix(ctx)
	if err != nil {
		return "", err
	}
	if r.ok(ctx, sudo+"docker info >/dev/null 2>&1") {
		r.docker = sudo + "docker"
		return r.docker, nil
	}
	return "", errors.New("Docker Engine is not available on the server; install it or use the systemd mode")
}

func (r *remote) arch(ctx context.Context) (string, error) {
	goos, arch, err := r.Platform(ctx)
	if err != nil {
		return "", err
	}
	if goos != "linux" {
		return "", fmt.Errorf("unsupported server %s; expected Linux on x86-64 or arm64", goos)
	}
	return arch, nil
}

func quoteAll(words []string) string {
	q := make([]string, len(words))
	for i, w := range words {
		q[i] = sshx.Quote(w)
	}
	return strings.Join(q, " ")
}

// Deploy installs or upgrades the relay and returns its URL and pin.
func Deploy(ctx context.Context, o Options) (Result, error) {
	if o.Tailnet != nil && o.Mode != "docker" {
		return Result{}, errors.New("--tailnet-login-server needs Docker mode")
	}
	if len(o.Config.Hostnames) == 0 && o.Tailnet == nil {
		return Result{}, errors.New("--hostname is required without a tailnet")
	}
	if o.Port == 0 {
		o.Port = 443
	}
	r := &remote{Target: o.Target}
	var status string
	var tailnet *TailnetState
	var err error
	switch o.Mode {
	case "docker":
		status, tailnet, err = deployDocker(ctx, o, r)
	case "systemd":
		status, err = deploySystemd(ctx, o, r)
	default:
		err = fmt.Errorf("unknown mode %q; use docker or systemd", o.Mode)
	}
	if err != nil {
		return Result{}, err
	}
	res := Result{Mode: o.Mode, Tailnet: tailnet}
	res.URL, res.Pin = publicURL(o, status, tailnet)
	if !o.NoConnect {
		check, err := Check(ctx, res.URL, res.Pin, o.ConnectAddress)
		if err != nil {
			return res, fmt.Errorf("connection check: %w", err)
		}
		res.Check = &check
	}
	return res, nil
}

func statusField(status, name string) string {
	for _, line := range strings.Split(status, "\n") {
		if v, ok := strings.CutPrefix(line, name+": "); ok {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func publicURL(o Options, status string, tailnet *TailnetState) (string, string) {
	pin := statusField(status, "Server pin")
	if o.PublicURL != "" {
		return o.PublicURL, pin
	}
	host := ""
	if tailnet != nil && tailnet.DNS != "" {
		host = tailnet.DNS
	} else if len(o.Config.Hostnames) > 0 {
		host = o.Config.Hostnames[0]
	}
	u := url.URL{Scheme: "https", Host: host}
	if strings.Contains(host, ":") {
		u.Host = "[" + host + "]"
	}
	if o.Port != 443 {
		u.Host = net.JoinHostPort(host, strconv.Itoa(o.Port))
	}
	return u.String(), pin
}

func waitStatus(ctx context.Context, fetch func() string) (string, error) {
	status := ""
	for i := 0; i < 40; i++ {
		status = fetch()
		if statusField(status, "State") == "running" && strings.HasPrefix(statusField(status, "Server pin"), "sha256/") {
			return status, nil
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(1500 * time.Millisecond):
		}
	}
	return "", fmt.Errorf("the relay did not report a running state:\n%s", status)
}

// ---- Docker mode ----

func deployDocker(ctx context.Context, o Options, r *remote) (string, *TailnetState, error) {
	arch, err := r.arch(ctx)
	if err != nil {
		return "", nil, err
	}
	docker, err := r.dockerPrefix(ctx)
	if err != nil {
		return "", nil, err
	}
	tag := Image + ":linux-" + arch
	o.log("Building %s", tag)
	build := exec.CommandContext(ctx, "docker", "buildx", "build", "--platform", "linux/"+arch, "--load", "-t", tag,
		"-f", filepath.Join(o.Module, "deploy", "remote", "host.Dockerfile"), o.Module)
	build.Stdout, build.Stderr = os.Stderr, os.Stderr
	if err := build.Run(); err != nil {
		return "", nil, fmt.Errorf("docker buildx build: %w", err)
	}
	o.log("Streaming the image to %s", o.Target.Destination)
	if err := streamImage(ctx, r, docker, tag); err != nil {
		return "", nil, err
	}
	steps := []string{
		docker + " tag " + tag + " " + Image + ":current",
		docker + " volume create " + Volume + " >/dev/null",
	}
	for _, s := range steps {
		if _, err := r.run(ctx, s); err != nil {
			return "", nil, err
		}
	}
	configured := r.ok(ctx, docker+" run --rm -v "+Volume+":/data --entrypoint test "+Image+":current -f /data/host.json")
	if _, err := r.run(ctx, docker+" rm -f "+Container+" >/dev/null 2>&1 || true"); err != nil {
		return "", nil, err
	}
	var tailnet *TailnetState
	var listen, network string
	cfg := o.Config
	if o.Tailnet != nil {
		names, state, err := startSidecar(ctx, o, r, docker)
		if err != nil {
			return "", nil, err
		}
		tailnet = state
		cfg.Hostnames = append(names, cfg.Hostnames...)
		listen = "127.0.0.1:" + strconv.Itoa(o.Tailnet.LocalPort)
		network = "--network host"
	} else {
		listen = ":" + strconv.Itoa(ContainerPort)
		bind := strconv.Itoa(o.Port)
		if o.Bind != "" {
			bind = net.JoinHostPort(o.Bind, bind)
		}
		network = "-p " + sshx.Quote(bind+":"+strconv.Itoa(ContainerPort))
	}
	switch {
	case configured && tailnet != nil:
		o.log("Adding the tailnet names to the existing relay configuration")
		flags := []string{"--listen=" + listen}
		for _, h := range cfg.Hostnames {
			flags = append(flags, "--add-hostname="+h)
		}
		if _, err := r.run(ctx, docker+" run --rm -v "+Volume+":/data "+Image+":current configure "+quoteAll(flags)); err != nil {
			return "", nil, err
		}
	case configured:
		o.log("Keeping the existing configuration in the relay volume")
	default:
		o.log("Creating the relay configuration")
		cfg.Listen = listen
		if cfg.Name == "" && len(cfg.Hostnames) > 0 {
			cfg.Name = cfg.Hostnames[0]
		}
		if _, err := r.run(ctx, docker+" run --rm -v "+Volume+":/data "+Image+":current init "+quoteAll(cfg.InitFlags())); err != nil {
			return "", nil, err
		}
	}
	o.log("Starting the relay container")
	if _, err := r.run(ctx, docker+" run -d --name "+Container+" --restart unless-stopped "+network+
		" -v "+Volume+":/data --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges "+
		Image+":current >/dev/null"); err != nil {
		return "", nil, err
	}
	status, err := waitStatus(ctx, func() string { s, _ := dockerStatus(ctx, r, docker); return s })
	if err != nil {
		return "", nil, err
	}
	if tailnet != nil {
		o.log("Forwarding tailnet TCP %d to the relay on %s", o.Port, listen)
		if _, err := r.run(ctx, docker+" exec "+Sidecar+" tailscale --socket="+tsSocket+" serve --bg --tcp "+
			strconv.Itoa(o.Port)+" tcp://"+listen+" >/dev/null"); err != nil {
			return "", nil, err
		}
	}
	return status, tailnet, nil
}

func streamImage(ctx context.Context, r *remote, docker, tag string) error {
	save := exec.CommandContext(ctx, "docker", "save", tag)
	out, err := save.StdoutPipe()
	if err != nil {
		return err
	}
	var saveErr bytes.Buffer
	save.Stderr = &saveErr
	if err := save.Start(); err != nil {
		return err
	}
	pr, pw := io.Pipe()
	go func() {
		gz, _ := gzip.NewWriterLevel(pw, gzip.BestSpeed)
		_, err := io.Copy(gz, out)
		if err == nil {
			err = gz.Close()
		}
		pw.CloseWithError(err)
	}()
	_, err = r.Run(ctx, "gunzip | "+docker+" load >/dev/null", pr)
	pr.Close()
	if werr := save.Wait(); werr != nil && err == nil {
		err = fmt.Errorf("docker save: %w: %s", werr, saveErr.String())
	}
	return err
}

func dockerStatus(ctx context.Context, r *remote, docker string) (string, error) {
	return r.run(ctx, docker+" exec "+Container+" commander-relay host --dir /data status 2>&1")
}

func tailnetAuthKey(t *Tailnet) (string, error) {
	key := os.Getenv("TS_AUTHKEY")
	if t.AuthKeyFile != "" {
		path := t.AuthKeyFile
		if strings.HasPrefix(path, "~/") {
			home, _ := os.UserHomeDir()
			path = filepath.Join(home, path[2:])
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return "", err
		}
		key = string(data)
	}
	key = strings.TrimSpace(key)
	if strings.ContainsAny(key, " \t\r\n") {
		return "", errors.New("the tailnet auth key must be a single token")
	}
	return key, nil
}

type tsStatus struct {
	BackendState   string
	CurrentTailnet *struct{ Name string }
	Self           *struct {
		DNSName      string
		HostName     string
		TailscaleIPs []string
		Tags         []string
	}
}

func tailnetStatus(ctx context.Context, r *remote, docker string) *tsStatus {
	out, err := r.run(ctx, docker+" exec "+Sidecar+" tailscale --socket="+tsSocket+" status --json 2>/dev/null")
	if err != nil {
		return nil
	}
	var s tsStatus
	if json.Unmarshal([]byte(out), &s) != nil {
		return nil
	}
	return &s
}

func startSidecar(ctx context.Context, o Options, r *remote, docker string) ([]string, *TailnetState, error) {
	t := o.Tailnet
	login, err := url.Parse(t.LoginServer)
	if err != nil || (login.Scheme != "https" && login.Scheme != "http") || login.Hostname() == "" ||
		login.User != nil || login.RawQuery != "" || login.Fragment != "" {
		return nil, nil, errors.New("--tailnet-login-server must be a plain https:// URL")
	}
	image := sshx.Quote(t.Image)
	if !r.ok(ctx, docker+" image inspect "+image+" >/dev/null 2>&1") {
		o.log("Pulling %s on the server", t.Image)
		if _, err := r.run(ctx, docker+" pull -q "+image+" >/dev/null"); err != nil {
			return nil, nil, err
		}
	}
	o.log("Starting the tailnet sidecar")
	for _, s := range []string{
		docker + " rm -f " + Sidecar + " >/dev/null 2>&1 || true",
		docker + " volume create " + SidecarVolume + " >/dev/null",
		// tailscaled keeps its node key, preferences and serve configuration
		// in the volume, so a redeploy rejoins as the same node without an
		// auth key. Userspace networking needs no TUN device or capabilities,
		// and port 0 avoids a host tailscaled's UDP port.
		docker + " run -d --name " + Sidecar + " --network host --restart unless-stopped --cap-drop ALL" +
			" --security-opt no-new-privileges -v " + SidecarVolume + ":/var/lib/tailscale" +
			" --entrypoint tailscaled " + image + " --tun=userspace-networking --port=0" +
			" --state=/var/lib/tailscale/tailscaled.state --statedir=/var/lib/tailscale --socket=" + tsSocket + " >/dev/null",
	} {
		if _, err := r.run(ctx, s); err != nil {
			return nil, nil, err
		}
	}
	var state *tsStatus
	for i := 0; i < 60; i++ {
		state = tailnetStatus(ctx, r, docker)
		if state != nil && state.BackendState != "" && state.BackendState != "NoState" {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if state == nil {
		logs, _ := r.run(ctx, docker+" logs --tail 20 "+Sidecar+" 2>&1")
		return nil, nil, fmt.Errorf("tailscaled did not start in the sidecar:\n%s", logs)
	}
	up := []string{"tailscale", "--socket=" + tsSocket, "up", "--reset", "--login-server=" + t.LoginServer,
		"--hostname=" + t.Hostname, "--accept-dns=false", "--timeout=90s"}
	if len(t.Tags) > 0 {
		up = append(up, "--advertise-tags="+strings.Join(t.Tags, ","))
	}
	key := ""
	if state.BackendState == "NeedsLogin" || state.BackendState == "NoState" {
		if key, err = tailnetAuthKey(t); err != nil {
			return nil, nil, err
		}
		if key == "" {
			return nil, nil, errors.New("the sidecar is not logged in yet; pass --tailnet-auth-key-file or set TS_AUTHKEY")
		}
		// The key travels on standard input, never on a command line or in
		// the container's configuration.
		up = append(up, "--auth-key=file:/dev/stdin")
		o.log("Joining %s as %s", t.LoginServer, t.Hostname)
	} else {
		o.log("Keeping the sidecar's tailnet login")
	}
	if _, err := r.Run(ctx, docker+" exec -i "+Sidecar+" "+quoteAll(up), strings.NewReader(key)); err != nil {
		return nil, nil, err
	}
	for i := 0; i < 60; i++ {
		state = tailnetStatus(ctx, r, docker)
		if state != nil && state.BackendState == "Running" && state.Self != nil && len(state.Self.TailscaleIPs) > 0 {
			break
		}
		time.Sleep(time.Second)
	}
	if state == nil || state.Self == nil || len(state.Self.TailscaleIPs) == 0 {
		return nil, nil, errors.New("the sidecar did not reach the tailnet")
	}
	dns := strings.TrimSuffix(state.Self.DNSName, ".")
	var names []string
	if dns != "" {
		names = append(names, dns)
	}
	names = append(names, state.Self.TailscaleIPs...)
	o.log("The relay node is %s (%s)", dns, strings.Join(state.Self.TailscaleIPs, ", "))
	ts := &TailnetState{DNS: dns, Addresses: state.Self.TailscaleIPs, Tags: state.Self.Tags}
	if state.CurrentTailnet != nil {
		ts.Tailnet = state.CurrentTailnet.Name
	}
	return names, ts, nil
}

// ---- systemd mode ----

func deploySystemd(ctx context.Context, o Options, r *remote) (string, error) {
	arch, err := r.arch(ctx)
	if err != nil {
		return "", err
	}
	sudo, err := r.sudoPrefix(ctx)
	if err != nil {
		return "", err
	}
	binary := o.Binary
	if binary == "" {
		work, err := os.MkdirTemp("", "commander-relay-deploy-")
		if err != nil {
			return "", err
		}
		defer os.RemoveAll(work)
		binary = filepath.Join(work, "commander-relay")
		o.log("Building commander-relay for linux/%s", arch)
		build := exec.CommandContext(ctx, "go", "build", "-trimpath", "-buildvcs=false", "-o", binary, "./cmd/commander-relay")
		build.Dir = o.Module
		build.Env = append(os.Environ(), "CGO_ENABLED=0", "GOOS=linux", "GOARCH="+arch, "GOWORK=off")
		build.Stdout, build.Stderr = os.Stderr, os.Stderr
		if err := build.Run(); err != nil {
			return "", fmt.Errorf("go build: %w", err)
		}
	}
	data, err := os.ReadFile(binary)
	if err != nil {
		return "", err
	}
	o.log("Copying the relay to %s", o.Target.Destination)
	staged, err := r.run(ctx, "mktemp /tmp/commander-relay.XXXXXX")
	if err != nil {
		return "", err
	}
	if _, err := r.Run(ctx, "cat > "+sshx.Quote(staged)+" && chmod 0755 "+sshx.Quote(staged), bytes.NewReader(data)); err != nil {
		return "", err
	}
	cfg := o.Config
	cfg.Listen = ":" + strconv.Itoa(o.Port)
	if o.Bind != "" {
		cfg.Listen = net.JoinHostPort(o.Bind, strconv.Itoa(o.Port))
	}
	if cfg.Name == "" && len(cfg.Hostnames) > 0 {
		cfg.Name = cfg.Hostnames[0]
	}
	o.log("Installing PostgreSQL when needed and the systemd service")
	args := append([]string{staged, "host", "provision", staged}, cfg.InitFlags()...)
	if _, err := r.Run(ctx, sudo+quoteAll(args)+" 1>&2", nil); err != nil {
		return "", err
	}
	return waitStatus(ctx, func() string { s, _ := systemdStatus(ctx, r, sudo); return s })
}

func systemdStatus(ctx context.Context, r *remote, sudo string) (string, error) {
	return r.run(ctx, sudo+"systemctl is-active "+Unit+" >/dev/null && "+sudo+hostmode.LinuxServiceBinary+
		" host --dir "+hostmode.LinuxServiceDir+" status 2>&1")
}

// Status returns the deployed relay's status text.
func Status(ctx context.Context, mode string, t sshx.Target) (string, error) {
	r := &remote{Target: t}
	switch mode {
	case "docker":
		docker, err := r.dockerPrefix(ctx)
		if err != nil {
			return "", err
		}
		status, _ := dockerStatus(ctx, r, docker)
		if r.ok(ctx, docker+" inspect "+Sidecar+" >/dev/null 2>&1") {
			s := tailnetStatus(ctx, r, docker)
			backend, name, dns, ips := "not answering", "", "", ""
			if s != nil {
				backend = s.BackendState
				if s.CurrentTailnet != nil {
					name = s.CurrentTailnet.Name
				}
				if s.Self != nil {
					dns, ips = strings.TrimSuffix(s.Self.DNSName, "."), strings.Join(s.Self.TailscaleIPs, " ")
				}
			}
			status += fmt.Sprintf("\nTailnet: %s %s\nTailnet node: %s %s", name, backend, dns, ips)
		}
		return status, nil
	case "systemd":
		sudo, err := r.sudoPrefix(ctx)
		if err != nil {
			return "", err
		}
		status, _ := systemdStatus(ctx, r, sudo)
		if status == "" {
			status = Unit + " is not active"
		}
		return status, nil
	}
	return "", fmt.Errorf("unknown mode %q", mode)
}

// Remove stops and removes the relay, keeping its data and TLS identity.
func Remove(ctx context.Context, mode string, t sshx.Target) (string, error) {
	r := &remote{Target: t}
	switch mode {
	case "docker":
		docker, err := r.dockerPrefix(ctx)
		if err != nil {
			return "", err
		}
		if _, err := r.run(ctx, docker+" rm -f "+Container+" >/dev/null 2>&1 || true"); err != nil {
			return "", err
		}
		msg := "Removed the " + Container + " container. The " + Volume + " volume keeps the relay's data and TLS identity."
		if r.ok(ctx, docker+" inspect "+Sidecar+" >/dev/null 2>&1") {
			if _, err := r.run(ctx, docker+" rm -f "+Sidecar+" >/dev/null"); err != nil {
				return "", err
			}
			msg += "\nRemoved the " + Sidecar + " sidecar. The " + SidecarVolume + " volume keeps the tailnet node's login."
		}
		return msg, nil
	case "systemd":
		sudo, err := r.sudoPrefix(ctx)
		if err != nil {
			return "", err
		}
		if _, err := r.run(ctx, sudo+hostmode.LinuxServiceBinary+" host uninstall"); err != nil {
			return "", err
		}
		return "Removed " + Unit + ". " + hostmode.LinuxServiceDir + " keeps the relay's data and TLS identity.", nil
	}
	return "", fmt.Errorf("unknown mode %q", mode)
}

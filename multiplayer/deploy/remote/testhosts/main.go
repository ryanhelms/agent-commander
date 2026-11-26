// Command testhosts deploys the relay to disposable Linux hosts over SSH and
// connects to each. It replaces rehearse.py.
//
// One host runs systemd and receives the service deployment. The other runs
// Docker Engine and receives the container deployment. Both are local Docker
// containers reached only through SSH, as a remote server would be. For each
// host the rehearsal deploys, checks the connection, adds the relay to a real
// Agent Commander device agent with isolated state, restarts the relay,
// redeploys and confirms that the TLS identity survives, then removes it.
//
// The tailnet mode starts a disposable Headscale on a private Docker network,
// deploys the relay to a Docker host behind a userspace Tailscale sidecar
// with no published port, and checks it from a second tailnet node: the
// connection check, and the Linux device agent's tailnet-status,
// tailnet-relays and server-probe verbs. It never contacts a real tailnet's
// control server.
//
//	cd multiplayer && go run ./deploy/remote/testhosts [--keep] [--mode docker|systemd|tailnet]...
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"agentcommander.network/hostkit/sshx"
	"agentcommander.network/pilot/internal/hostmode"
	"agentcommander.network/pilot/internal/relaydeploy"
)

const (
	issuer   = "https://accounts.google.com"
	clientID = "rehearsal.apps.googleusercontent.com"
	// The private network for the tailnet rehearsal. headscale/config.yaml
	// names the control server's address on it.
	tailnetNet     = "acr-rehearsal-tailnet"
	tailnetSubnet  = "10.247.0.0/24"
	headscale      = "acr-rehearsal-headscale"
	headscaleIP    = "10.247.0.10"
	headscaleImage = "headscale/headscale:0.27.1"
	loginServer    = "http://" + headscaleIP + ":8080"
	tsHost         = "acr-rehearsal-tailnet"
	client         = "acr-rehearsal-client"
	clientImage    = "acr-testhost-client"
	relayNode      = "agent-relay"
	relayURL       = "https://" + relayNode + ".tail.internal"
)

type host struct {
	image, name        string
	sshPort, relayPort int
}

var hosts = map[string]host{
	"systemd": {"acr-testhost-systemd", "acr-rehearsal-systemd", 22401, 22443},
	"docker":  {"acr-testhost-docker", "acr-rehearsal-docker", 22402, 22444},
	"tailnet": {"acr-testhost-docker", "acr-rehearsal-tailnet", 22403, 22445},
}

type modes []string

func (m *modes) String() string { return strings.Join(*m, ",") }
func (m *modes) Set(v string) error {
	if _, ok := hosts[v]; !ok {
		return fmt.Errorf("unknown mode %q", v)
	}
	*m = append(*m, v)
	return nil
}

var (
	here   string // this directory
	module string // the multiplayer module
	work   string
	key    string
)

func logStep(format string, args ...any) { fmt.Printf("\n### "+format+"\n", args...) }

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func check(ok bool, format string, args ...any) {
	if !ok {
		panic(fmt.Errorf(format, args...))
	}
}

func run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func output(stdin []byte, name string, args ...string) string {
	cmd := exec.Command(name, args...)
	cmd.Stderr = os.Stderr
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	out, err := cmd.Output()
	must(err)
	return string(out)
}

func quiet(name string, args ...string) bool { return exec.Command(name, args...).Run() == nil }

func printJSON(v any) {
	data, _ := json.MarshalIndent(v, "", "  ")
	fmt.Println(string(data))
}

func target(sshPort int) sshx.Target {
	return sshx.Target{Destination: "ops@127.0.0.1", Options: []string{"-p", strconv.Itoa(sshPort), "-i", key,
		"-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
		"-o", "LogLevel=ERROR", "-o", "ConnectTimeout=15"}}
}

func startHost(mode string, publicKey []byte) host {
	h := hosts[mode]
	dockerfile := mode
	if mode == "tailnet" {
		dockerfile = "docker"
	}
	must(run("docker", "build", "-q", "-t", h.image, "-f", filepath.Join(here, dockerfile+".Dockerfile"), here))
	quiet("docker", "rm", "-f", h.name)
	args := []string{"run", "-d", "--name", h.name, "--hostname", h.name, "--privileged",
		"-p", fmt.Sprintf("127.0.0.1:%d:22", h.sshPort), "-p", fmt.Sprintf("127.0.0.1:%d:443", h.relayPort)}
	if mode == "systemd" {
		args = append(args, "--cgroupns=host", "-v", "/sys/fs/cgroup:/sys/fs/cgroup:rw", "--tmpfs", "/run", "--tmpfs", "/run/lock")
	}
	output(nil, "docker", append(args, h.image)...)
	output(publicKey, "docker", "exec", "-i", h.name, "sh", "-c",
		"cat > /home/ops/.ssh/authorized_keys && chown ops:ops /home/ops/.ssh/authorized_keys && chmod 600 /home/ops/.ssh/authorized_keys")
	deadline := time.Now().Add(90 * time.Second)
	for {
		conn, err := net.DialTimeout("tcp", "127.0.0.1:"+strconv.Itoa(h.sshPort), 2*time.Second)
		if err == nil {
			buf := make([]byte, 4)
			conn.SetReadDeadline(time.Now().Add(2 * time.Second))
			n, _ := conn.Read(buf)
			conn.Close()
			if n == 4 && string(buf) == "SSH-" {
				break
			}
		}
		check(time.Now().Before(deadline), "%s did not start SSH", h.name)
		time.Sleep(time.Second)
	}
	if mode == "tailnet" {
		must(run("docker", "network", "connect", "--ip", "10.247.0.20", tailnetNet, h.name))
	}
	if mode != "systemd" {
		for i := 0; i < 60 && !quiet("docker", "exec", h.name, "docker", "info"); i++ {
			time.Sleep(time.Second)
		}
	}
	return h
}

func deploy(ctx context.Context, mode string, h host) relaydeploy.Result {
	res, err := relaydeploy.Deploy(ctx, relaydeploy.Options{Mode: mode, Target: target(h.sshPort), Module: module,
		Config: hostmode.Config{Name: "Rehearsal " + mode, Hostnames: []string{"localhost", "127.0.0.1"},
			Issuer: issuer, ClientID: clientID, Admins: []string{"admin@example.org"}},
		Port: 443, PublicURL: fmt.Sprintf("https://localhost:%d", h.relayPort),
		Log: func(m string) { fmt.Fprintln(os.Stderr, "==>", m) }})
	must(err)
	printJSON(res)
	check(res.Check != nil && res.Check.DeviceReady == 204 && res.Check.AnonymousReady != 204, "unexpected readiness %+v", res.Check)
	check(res.Check.Pin == res.Pin, "the presented pin differs from the reported server pin")
	return res
}

func networkBinary(goos, arch string) string {
	name := filepath.Join(work, "commander-network-"+goos+"-"+arch)
	if _, err := os.Stat(name); err == nil {
		return name
	}
	cmd := exec.Command("go", "build", "-trimpath", "-o", name, "./cmd/commander-network")
	cmd.Dir = module
	cmd.Env = append(os.Environ(), "GOWORK=off", "GOOS="+goos, "GOARCH="+arch)
	if goos != runtime.GOOS {
		// The Mac build keeps cgo for its Keychain device store.
		cmd.Env = append(cmd.Env, "CGO_ENABLED=0")
	}
	cmd.Stderr = os.Stderr
	must(cmd.Run())
	return name
}

// deviceAgent adds the relay to a real Agent Commander device agent with
// isolated state.
func deviceAgent(url, pin string) {
	binary := networkBinary(runtime.GOOS, runtime.GOARCH)
	state, err := os.MkdirTemp("", "acr-net-")
	must(err)
	defer os.RemoveAll(state)
	must(os.Mkdir(filepath.Join(state, "state"), 0700))
	// Sign-in needs the Google Desktop client file for the relay's client ID.
	// The rehearsal stops before sign-in, so a placeholder secret is enough.
	must(os.WriteFile(filepath.Join(state, "state", "google-desktop-client.json"),
		[]byte(`{"installed":{"client_id":"`+clientID+`","client_secret":"rehearsal-placeholder"}}`), 0600))
	env := append(os.Environ(), "COMMANDER_NETWORK_STATE="+filepath.Join(state, "state"),
		"COMMANDER_NETWORK_SOCKET="+filepath.Join(state, "network.sock"), "AGENT_COMMANDER_SOCKET="+filepath.Join(state, "commander.sock"))
	daemon := exec.Command(binary, "serve")
	daemon.Env = env
	must(daemon.Start())
	account := ""
	defer func() {
		daemon.Process.Signal(syscall.SIGTERM)
		daemon.Wait()
		if account != "" && runtime.GOOS == "darwin" {
			quiet("security", "delete-generic-password", "-s", "Agent Commander Multiplayer", "-a", account)
		}
	}()
	for i := 0; i < 100; i++ {
		if _, err := os.Stat(filepath.Join(state, "network.sock")); err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	tray := func(verb string, body any) json.RawMessage {
		in, _ := json.Marshal(body)
		cmd := exec.Command(binary, "tray", verb)
		cmd.Env, cmd.Stdin = env, bytes.NewReader(in)
		out, err := cmd.Output()
		must(err)
		var reply struct {
			OK   bool            `json:"ok"`
			Data json.RawMessage `json:"data"`
		}
		must(json.Unmarshal(out, &reply))
		check(reply.OK, "tray %s failed: %s", verb, out)
		return reply.Data
	}
	probeSteps(tray("server-probe", map[string]string{"url": url}), pin)
	var added struct{ ID, URL string }
	must(json.Unmarshal(tray("server-add", map[string]string{"url": url, "pin": pin}), &added))
	sum := sha256.Sum256([]byte(added.URL))
	account = "device-" + hex.EncodeToString(sum[:])
	time.Sleep(2 * time.Second)
	var servers struct {
		Servers []struct {
			ID, Pin, Error, State string
		}
	}
	must(json.Unmarshal(tray("servers", map[string]string{}), &servers))
	for _, s := range servers.Servers {
		if s.ID == added.ID {
			printJSON(map[string]any{"server": s})
			check(s.Pin == pin && s.Error == "", "the device agent reported a connection error")
			check(s.State == "signedOut", "the device agent did not reach the sign-in step")
			return
		}
	}
	panic("the added server is not listed")
}

func probeSteps(data json.RawMessage, pin string) {
	var probe struct {
		Steps []struct {
			Step, Detail, Pin string
			OK                bool
		}
	}
	must(json.Unmarshal(data, &probe))
	steps := map[string]bool{}
	for _, s := range probe.Steps {
		fmt.Printf("probe %-7s ok=%v %s\n", s.Step, s.OK, s.Detail)
		steps[s.Step] = s.OK
		if s.Step == "tls" {
			check(s.Pin == pin, "the app would pin a different certificate")
		}
	}
	for _, s := range []string{"dns", "tcp", "tls", "relay", "signin"} {
		check(steps[s], "probe step %s failed", s)
	}
}

func rehearse(ctx context.Context, mode string, publicKey []byte) {
	logStep("%s: start a disposable remote host", mode)
	h := startHost(mode, publicKey)
	logStep("%s: deploy over SSH and connect", mode)
	first := deploy(ctx, mode, h)
	logStep("%s: add the relay to an Agent Commander device agent", mode)
	deviceAgent(first.URL, first.Pin)
	logStep("%s: restart the relay and reconnect", mode)
	if mode == "systemd" {
		must(run("docker", "exec", h.name, "systemctl", "restart", "agent-commander-relay.service"))
	} else {
		must(run("docker", "exec", h.name, "docker", "restart", "agent-commander-relay"))
	}
	report, err := relaydeploy.Check(ctx, first.URL, first.Pin, "")
	must(err)
	printJSON(report)
	logStep("%s: redeploy and keep the TLS identity and configuration", mode)
	second := deploy(ctx, mode, h)
	check(second.Pin == first.Pin, "redeploy replaced the relay identity")
	status, err := relaydeploy.Status(ctx, mode, target(h.sshPort))
	must(err)
	fmt.Println(status)
	logStep("%s: remove the relay and keep its data", mode)
	msg, err := relaydeploy.Remove(ctx, mode, target(h.sshPort))
	must(err)
	fmt.Println(msg)
	short, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	_, err = relaydeploy.Check(short, first.URL, "", "")
	check(err != nil, "the relay still answers after removal")
	fmt.Println("The relay no longer answers.")
}

func headscaleCmd(args ...string) string {
	return output(nil, "docker", append([]string{"exec", headscale, "headscale"}, args...)...)
}

func startTailnet() (relayKey, clientKey string) {
	for _, name := range []string{client, headscale, tsHost} {
		quiet("docker", "rm", "-f", "-v", name)
	}
	quiet("docker", "network", "rm", tailnetNet)
	output(nil, "docker", "network", "create", "--subnet", tailnetSubnet, tailnetNet)
	output(nil, "docker", "run", "-d", "--name", headscale, "--network", tailnetNet, "--ip", headscaleIP,
		"-v", filepath.Join(here, "headscale")+":/etc/headscale:ro", "--tmpfs", "/var/lib/headscale",
		"--tmpfs", "/var/run/headscale", headscaleImage, "serve")
	started := false
	for i := 0; i < 60 && !started; i++ {
		started = quiet("docker", "exec", headscale, "headscale", "users", "list")
		if !started {
			time.Sleep(time.Second)
		}
	}
	check(started, "the disposable Headscale did not start")
	var user struct{ ID json.Number }
	must(json.Unmarshal([]byte(headscaleCmd("users", "create", "rehearsal", "-o", "json")), &user))
	authKey := func(extra ...string) string {
		var k struct{ Key string }
		must(json.Unmarshal([]byte(headscaleCmd(append([]string{"preauthkeys", "create", "-u", user.ID.String(), "-e", "1h", "-o", "json"}, extra...)...)), &k))
		return k.Key
	}
	return authKey("--tags", "tag:relay"), authKey()
}

func startClient(authKey string) {
	must(run("docker", "build", "-q", "-t", clientImage, "-f", filepath.Join(here, "client.Dockerfile"), here))
	output(nil, "docker", "run", "-d", "--name", client, "--hostname", "rehearsal-client", "--network", tailnetNet,
		"--cap-add", "NET_ADMIN", "--cap-add", "NET_RAW", "--device", "/dev/net/tun",
		"--entrypoint", "tailscaled", clientImage, "--state=mem:")
	arch := map[string]string{"x86_64": "amd64", "aarch64": "arm64"}[strings.TrimSpace(output(nil, "docker", "exec", client, "uname", "-m"))]
	must(run("docker", "cp", networkBinary("linux", arch), client+":/usr/local/bin/commander-network"))
	relay := filepath.Join(work, "commander-relay-linux-"+arch)
	cmd := exec.Command("go", "build", "-trimpath", "-o", relay, "./cmd/commander-relay")
	cmd.Dir = module
	cmd.Env = append(os.Environ(), "GOWORK=off", "GOOS=linux", "GOARCH="+arch, "CGO_ENABLED=0")
	cmd.Stderr = os.Stderr
	must(cmd.Run())
	must(run("docker", "cp", relay, client+":/usr/local/bin/commander-relay"))
	for i := 0; i < 40; i++ {
		err := exec.Command("docker", "exec", client, "tailscale", "status").Run()
		var exit *exec.ExitError
		if err == nil || errors.As(err, &exit) && exit.ExitCode() == 1 {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	output([]byte(authKey), "docker", "exec", "-i", client, "tailscale", "up", "--login-server="+loginServer,
		"--hostname=rehearsal-client", "--accept-dns=true", "--auth-key=file:/dev/stdin", "--timeout=90s")
}

func inClient(stdin []byte, args ...string) string {
	return output(stdin, "docker", append([]string{"exec", "-i", client}, args...)...)
}

func clientCheck(pin string) {
	var report relaydeploy.CheckResult
	must(json.Unmarshal([]byte(inClient(nil, "commander-relay", "deploy", "connect", relayURL, "--pin", pin)), &report))
	printJSON(report)
	check(report.DeviceReady == 204 && report.AnonymousReady != 204, "unexpected readiness %+v", report)
}

// clientDeviceAgent runs the Linux device agent on the client node and finds
// the relay through tailnet verbs.
func clientDeviceAgent(pin string) {
	env := []string{"env", "COMMANDER_NETWORK_STATE=/tmp/net/state", "COMMANDER_NETWORK_SOCKET=/tmp/net/network.sock",
		"AGENT_COMMANDER_SOCKET=/tmp/net/commander.sock"}
	inClient(nil, "sh", "-c", "mkdir -p -m 0700 /tmp/net/state")
	// The probe checks that sign-in could start; a placeholder secret is enough.
	inClient([]byte(`{"installed":{"client_id":"`+clientID+`","client_secret":"rehearsal-placeholder"}}`),
		"sh", "-c", "umask 077 && cat > /tmp/net/state/google-desktop-client.json")
	must(run("docker", append([]string{"exec", "-d", client}, append(env, "commander-network", "serve")...)...))
	for i := 0; i < 100 && !quiet("docker", "exec", client, "test", "-S", "/tmp/net/network.sock"); i++ {
		time.Sleep(100 * time.Millisecond)
	}
	tray := func(verb string, body any) json.RawMessage {
		in, _ := json.Marshal(body)
		out := inClient(in, append(env, "commander-network", "tray", verb)...)
		var reply struct {
			OK   bool            `json:"ok"`
			Data json.RawMessage `json:"data"`
		}
		must(json.Unmarshal([]byte(out), &reply))
		check(reply.OK, "tray %s failed: %s", verb, out)
		return reply.Data
	}
	var status struct {
		Running        bool   `json:"running"`
		MagicDNSSuffix string `json:"magicDNSSuffix"`
	}
	must(json.Unmarshal(tray("tailnet-status", map[string]string{}), &status))
	printJSON(map[string]any{"tailnet-status": status})
	check(status.Running && status.MagicDNSSuffix == "tail.internal", "the client is not on the tailnet")
	var relays struct {
		Relays []struct {
			Name, URL     string
			Online, Added bool
		}
	}
	must(json.Unmarshal(tray("tailnet-relays", map[string]string{}), &relays))
	printJSON(relays)
	found := false
	for _, r := range relays.Relays {
		if r.Name == relayNode {
			found = r.URL == relayURL && r.Online && !r.Added
		}
	}
	check(found, "the relay is not listed")
	probeSteps(tray("server-probe", map[string]string{"url": relayURL}), pin)
	inClient(nil, "sh", "-c", "pkill commander-network || true")
}

func tailnetDeploy(ctx context.Context, h host, authKeyFile string) relaydeploy.Result {
	res, err := relaydeploy.Deploy(ctx, relaydeploy.Options{Mode: "docker", Target: target(h.sshPort), Module: module,
		Config: hostmode.Config{Name: "Rehearsal tailnet", Issuer: issuer, ClientID: clientID, Admins: []string{"admin@example.org"}},
		Port:   443, NoConnect: true,
		Tailnet: &relaydeploy.Tailnet{LoginServer: loginServer, AuthKeyFile: authKeyFile, Hostname: relayNode,
			LocalPort: 18443, Image: relaydeploy.TailscaleImage},
		Log: func(m string) { fmt.Fprintln(os.Stderr, "==>", m) }})
	must(err)
	printJSON(res)
	check(res.URL == relayURL && strings.HasPrefix(res.Pin, "sha256/"), "unexpected relay URL or pin")
	tagged := false
	for _, t := range res.Tailnet.Tags {
		tagged = tagged || t == "tag:relay"
	}
	check(tagged, "the relay node is not tagged tag:relay")
	return res
}

func rehearseTailnet(ctx context.Context, publicKey []byte) {
	logStep("tailnet: start a disposable Headscale and a remote Docker host")
	relayKey, clientKey := startTailnet()
	h := startHost("tailnet", publicKey)
	keyFile := filepath.Join(work, "relay.authkey")
	must(os.WriteFile(keyFile, []byte(relayKey), 0600))
	logStep("tailnet: deploy over SSH with a Tailscale sidecar and no published port")
	// The rehearsal passes the key by file; a stray TS_AUTHKEY must not win.
	os.Unsetenv("TS_AUTHKEY")
	first := tailnetDeploy(ctx, h, keyFile)
	for _, container := range []string{relaydeploy.Container, relaydeploy.Sidecar} {
		ports := strings.TrimSpace(output(nil, "docker", "exec", tsHost, "docker", "inspect", "-f", "{{json .HostConfig.PortBindings}}", container))
		check(ports == "{}" || ports == "null", "%s publishes ports: %s", container, ports)
	}
	logStep("tailnet: start a second tailnet node and check the relay from it")
	startClient(clientKey)
	for _, port := range []string{"443", "18443"} {
		reached := quiet("docker", "exec", client, "nc", "-z", "-w", "3", "10.247.0.20", port)
		check(!reached, "the Docker host answers on its own address at port %s", port)
	}
	fmt.Println("The relay does not answer on the Docker host's own address.")
	clientCheck(first.Pin)
	logStep("tailnet: find and probe the relay with the device agent's tailnet verbs")
	clientDeviceAgent(first.Pin)
	logStep("tailnet: redeploy without an auth key and keep the node and pin")
	second := tailnetDeploy(ctx, h, "")
	check(second.Pin == first.Pin, "redeploy replaced the relay identity")
	check(strings.Join(second.Tailnet.Addresses, ",") == strings.Join(first.Tailnet.Addresses, ","), "redeploy changed the tailnet node")
	clientCheck(first.Pin)
	status, err := relaydeploy.Status(ctx, "docker", target(h.sshPort))
	must(err)
	fmt.Println(status)
	logStep("tailnet: remove the relay and its sidecar")
	msg, err := relaydeploy.Remove(ctx, "docker", target(h.sshPort))
	must(err)
	fmt.Println(msg)
}

func main() {
	var selected modes
	flag.Var(&selected, "mode", "docker, systemd or tailnet; repeatable (default systemd and docker)")
	keep := flag.Bool("keep", false, "leave the test hosts running for inspection")
	flag.Parse()
	if len(selected) == 0 {
		selected = modes{"systemd", "docker"}
	}
	_, file, _, _ := runtime.Caller(0)
	here = filepath.Dir(file)
	module = filepath.Clean(filepath.Join(here, "..", "..", ".."))
	var err error
	work, err = os.MkdirTemp("", "acr-rehearsal-")
	must(err)
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	var started []string
	defer func() {
		failure := recover()
		if !*keep {
			for _, name := range started {
				quiet("docker", "rm", "-f", "-v", name)
			}
			for _, m := range selected {
				if m == "tailnet" {
					quiet("docker", "network", "rm", tailnetNet)
				}
			}
		}
		os.RemoveAll(work)
		cancel()
		if failure != nil {
			fmt.Fprintln(os.Stderr, "\nREHEARSAL FAILED:", failure)
			os.Exit(1)
		}
	}()
	key = filepath.Join(work, "id_ed25519")
	must(run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "relay-rehearsal", "-f", key))
	publicKey, err := os.ReadFile(key + ".pub")
	must(err)
	for _, m := range selected {
		started = append(started, hosts[m].name)
		if m == "tailnet" {
			started = append(started, client, headscale)
			rehearseTailnet(ctx, publicKey)
		} else {
			rehearse(ctx, m, publicKey)
		}
	}
	logStep("All rehearsals passed")
}

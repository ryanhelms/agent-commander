// Command testhost rehearses the headless Commander on a disposable Linux
// server: a local Docker container with systemd, reached only through SSH.
//
// It builds two releases of agentctl stamped with test tags and packages them
// with packaging/headless. It also writes two fake releases: one whose
// service never becomes healthy, and one with another API version. A local
// release mirror serves all four. Then it checks, in order:
//
//  1. install.sh, anonymously through the mirror, on a fresh server;
//
//  2. install.sh through `gh` (a stand-in that reads the mirror), using the
//     one-line form, and that a tampered archive is refused;
//
//  3. `agentctl host deploy` from this Mac: upgrade, a broken release that
//     rolls back, an incompatible release that is refused, then rollback;
//
//  4. `agentctl host connect`: the API through the forwarded socket, and
//     reconnection after the SSH connection drops;
//
//  5. tmux sessions surviving an upgrade, and `host remove`.
//
//     go run ./deploy/headless/testhost [--keep]
package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const (
	image      = "acx-headless-testhost"
	container  = "acx-headless-rehearsal"
	sshPort    = "22520"
	mirrorPort = 18766
	tagGood1   = "v0.0.1-rehearsal.1"
	tagGood2   = "v0.0.1-rehearsal.2"
	tagBroken  = "v0.0.1-rehearsal.3"
	tagAPI     = "v0.0.1-rehearsal.4"
)

var (
	root, work, sshConfig, agentctl string
	arch                            string
)

func step(format string, args ...any) { fmt.Printf("\n### "+format+"\n", args...) }

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func expect(ok bool, format string, args ...any) {
	if !ok {
		panic(fmt.Errorf(format, args...))
	}
}

func cmd(dir string, env []string, name string, args ...string) (string, error) {
	c := exec.Command(name, args...)
	c.Dir = dir
	c.Env = append(os.Environ(), env...)
	var out, errb bytes.Buffer
	c.Stdout, c.Stderr = &out, &errb
	err := c.Run()
	if err != nil {
		return out.String(), fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, errb.String())
	}
	return out.String(), nil
}

func ok(name string, args ...string) string {
	out, err := cmd(root, nil, name, args...)
	must(err)
	return out
}

func ssh(script string) (string, error) {
	return cmd(root, nil, "ssh", "-F", sshConfig, "-R", fmt.Sprintf("%d:127.0.0.1:%d", mirrorPort, mirrorPort), "acx", script)
}

func host(env []string, args ...string) (string, error) {
	return cmd(root, append([]string{"AGENT_COMMANDER_HOME=" + filepath.Join(work, "mac")}, env...), agentctl,
		append([]string{"host"}, args...)...)
}

func report(out string) map[string]any {
	var r map[string]any
	if i := strings.Index(out, "{"); i >= 0 {
		_ = json.Unmarshal([]byte(out[i:]), &r)
	}
	return r
}

func remoteStatus() map[string]any {
	out, err := host(nil, "status", "-F", sshConfig, "acx")
	must(err)
	return report(out)
}

func build(tag, goarch, out string) {
	_, err := cmd(root, []string{"GOOS=linux", "GOARCH=" + goarch, "CGO_ENABLED=0"}, "go", "build", "-trimpath", "-buildvcs=false",
		"-ldflags", "-X agentcommander/internal/buildinfo.Version="+tag, "-o", out, "./cmd/agentctl")
	must(err)
}

func release(mirror, tag string) {
	dir := filepath.Join(mirror, tag)
	amd, arm := filepath.Join(work, tag+"-amd64"), filepath.Join(work, tag+"-arm64")
	build(tag, "amd64", amd)
	build(tag, "arm64", arm)
	_, err := cmd(root, []string{"GOWORK=off"}, "go", "run", "./packaging/headless", "--version", tag, "--output", dir,
		"--binary", "amd64="+amd, "--binary", "arm64="+arm)
	must(err)
}

// fakeRelease writes a release whose agentctl is a script: it answers
// `host version` with api, and cannot serve.
func fakeRelease(mirror, tag string, api int) {
	dir := filepath.Join(mirror, tag)
	must(os.MkdirAll(dir, 0755))
	script := fmt.Sprintf("#!/bin/sh\ncase \"$1 $2\" in\n\"host version\") echo '{\"version\":\"%s\",\"api\":%d}' ;;\n\"host doctor\") echo '{\"ok\":true}' ;;\n*) exit 1 ;;\nesac\n", tag, api)
	stage := filepath.Join(work, "fake-"+tag, "agent-commander-headless")
	must(os.MkdirAll(stage, 0755))
	must(os.WriteFile(filepath.Join(stage, "agentctl"), []byte(script), 0755))
	for _, a := range []string{"amd64", "arm64"} {
		ok("tar", "-czf", filepath.Join(dir, "agent-commander-headless-linux-"+a+".tar.gz"), "-C", filepath.Dir(stage), "agent-commander-headless")
	}
	must(os.WriteFile(filepath.Join(dir, "install.sh"), mustRead(filepath.Join(root, "deploy/headless/install.sh")), 0755))
}

func mustRead(path string) []byte {
	data, err := os.ReadFile(path)
	must(err)
	return data
}

func sums(dir string) {
	entries, err := os.ReadDir(dir)
	must(err)
	var lines []string
	var assets []map[string]any
	for _, e := range entries {
		if e.Name() == "SHA256SUMS" {
			continue
		}
		sum := sha256.Sum256(mustRead(filepath.Join(dir, e.Name())))
		lines = append(lines, hex.EncodeToString(sum[:])+"  "+e.Name())
		assets = append(assets, map[string]any{"name": e.Name()})
	}
	must(os.WriteFile(filepath.Join(dir, "SHA256SUMS"), []byte(strings.Join(lines, "\n")+"\n"), 0644))
}

func writeMirror(mirror string, tags []string, latest string) {
	var releases []map[string]any
	for i, tag := range tags {
		dir := filepath.Join(mirror, tag)
		sums(dir)
		entries, _ := os.ReadDir(dir)
		var assets []map[string]any
		for _, e := range entries {
			assets = append(assets, map[string]any{"name": e.Name()})
		}
		releases = append(releases, map[string]any{"tag_name": tag, "prerelease": true,
			"published_at": time.Date(2026, 1, 1+i, 0, 0, 0, 0, time.UTC), "assets": assets})
	}
	data, _ := json.Marshal(releases)
	must(os.WriteFile(filepath.Join(mirror, "releases.json"), data, 0644))
	must(os.WriteFile(filepath.Join(mirror, "LATEST"), []byte(latest+"\n"), 0644))
}

func startHost() {
	ok("docker", "build", "-q", "-t", image, filepath.Join(root, "deploy/headless/testhost"))
	_, _ = cmd(root, nil, "docker", "rm", "-f", container)
	ok("docker", "run", "-d", "--name", container, "--hostname", container, "--privileged", "--cgroupns=host",
		"-v", "/sys/fs/cgroup:/sys/fs/cgroup:rw", "--tmpfs", "/run", "--tmpfs", "/run/lock", "-p", "127.0.0.1:"+sshPort+":22", image)
	key := filepath.Join(work, "key")
	ok("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key)
	c := exec.Command("docker", "exec", "-i", container, "sh", "-c",
		"cat > /home/ops/.ssh/authorized_keys && chown ops:ops /home/ops/.ssh/authorized_keys && chmod 600 /home/ops/.ssh/authorized_keys")
	c.Stdin = bytes.NewReader(mustRead(key + ".pub"))
	must(c.Run())
	sshConfig = filepath.Join(work, "ssh_config")
	must(os.WriteFile(sshConfig, []byte(fmt.Sprintf("Host acx\n  HostName 127.0.0.1\n  Port %s\n  User ops\n  IdentityFile %s\n  IdentitiesOnly yes\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n  LogLevel ERROR\n", sshPort, key)), 0600))
	for i := 0; ; i++ {
		if _, err := ssh("true"); err == nil {
			break
		}
		expect(i < 60, "the test host did not start SSH")
		time.Sleep(time.Second)
	}
	out, err := ssh("uname -m")
	must(err)
	arch = map[string]string{"x86_64": "amd64", "aarch64": "arm64"}[strings.TrimSpace(out)]
}

// ghShim stands in for a signed-in gh on the server, reading the mirror.
const ghShim = `#!/bin/sh
M=http://127.0.0.1:%d
case "$1 $2" in
"auth status") exit 0 ;;
"release list") curl -fsS $M/LATEST; exit ;;
"release download")
	shift 2; tag=""; out=""; dir=.; pats=""
	while [ $# -gt 0 ]; do case $1 in
		-R) shift ;; -p) pats="$pats $2"; shift ;; -O) out=$2; shift ;; -D) dir=$2; shift ;;
		-*) ;; *) tag=$1 ;; esac; shift; done
	[ -n "$tag" ] || tag=$(curl -fsS $M/LATEST)
	for p in $pats; do
		if [ "$out" = - ]; then curl -fsS "$M/$tag/$p"; else curl -fsS -o "$dir/$p" "$M/$tag/$p"; fi
	done ;;
*) exit 1 ;;
esac
`

func main() {
	keep := flag.Bool("keep", false, "leave the test host running")
	flag.Parse()
	_, file, _, _ := runtime.Caller(0)
	root = filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	var err error
	work, err = os.MkdirTemp("/tmp", "acx-")
	must(err)
	defer func() {
		failure := recover()
		if !*keep {
			_, _ = cmd(root, nil, "docker", "rm", "-f", container)
			os.RemoveAll(work)
		}
		if failure != nil {
			fmt.Fprintln(os.Stderr, "\nREHEARSAL FAILED:", failure)
			os.Exit(1)
		}
	}()

	step("build two releases and two fake ones, and serve them from a mirror")
	agentctl = filepath.Join(work, "agentctl")
	_, err = cmd(root, nil, "go", "build", "-o", agentctl, "./cmd/agentctl")
	must(err)
	mirror := filepath.Join(work, "mirror")
	release(mirror, tagGood1)
	release(mirror, tagGood2)
	fakeRelease(mirror, tagBroken, 1)
	fakeRelease(mirror, tagAPI, 2)
	// The newest release is a good one, so a deploy without --version finds it.
	writeMirror(mirror, []string{tagGood1, tagBroken, tagAPI, tagGood2}, tagGood1)
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", mirrorPort))
	must(err)
	go http.Serve(ln, http.FileServer(http.Dir(mirror)))

	step("start a disposable Linux server")
	startHost()
	fmt.Println("server architecture:", arch)

	step("install.sh, anonymously through the mirror")
	out, err := ssh(fmt.Sprintf("curl -fsS http://127.0.0.1:%d/%s/install.sh | AGENT_COMMANDER_DOWNLOAD_BASE=http://127.0.0.1:%d sh -s -- --sudo-linger", mirrorPort, tagGood1, mirrorPort))
	must(err)
	expect(report(out)["version"] == tagGood1, "install.sh installed %v", report(out)["version"])
	fmt.Println("installed", tagGood1)

	step("install.sh through gh, with the one-line form, and a tampered archive")
	shim := filepath.Join(work, "gh")
	must(os.WriteFile(shim, []byte(fmt.Sprintf(ghShim, mirrorPort)), 0755))
	ok("scp", "-q", "-F", sshConfig, shim, "acx:/tmp/gh")
	_, err = ssh("sudo install -m 0755 /tmp/gh /usr/local/bin/gh")
	must(err)
	out, err = ssh("gh release download -R ryanhelms/agent-commander -p install.sh -O - | sh")
	must(err)
	expect(report(out)["version"] == tagGood1, "the one-liner installed %v", report(out)["version"])
	tampered := filepath.Join(mirror, tagGood2, "agent-commander-headless-linux-"+arch+".tar.gz")
	original := mustRead(tampered)
	must(os.WriteFile(tampered, append(append([]byte{}, original...), 'x'), 0644))
	_, err = ssh("gh release download " + tagGood2 + " -R ryanhelms/agent-commander -p install.sh -O - | sh -s -- " + tagGood2)
	expect(err != nil && strings.Contains(err.Error(), "checksum mismatch"), "a tampered archive was not refused: %v", err)
	must(os.WriteFile(tampered, original, 0644))
	fmt.Println("refused the tampered archive")

	step("deploy from this Mac: upgrade, broken release, incompatible release, rollback")
	_, err = ssh("tmux new-session -d -s survivor 'sleep 3600'")
	must(err)
	out, err = host(nil, "deploy", "-F", sshConfig, "acx", "--mirror", mirror, "--version", tagGood2)
	must(err)
	expect(remoteStatus()["version"] == tagGood2, "the upgrade did not take")
	_, err = ssh("tmux has-session -t survivor")
	expect(err == nil, "the upgrade killed a tmux session")
	fmt.Println("upgraded to", tagGood2, "and the tmux session survived")
	_, err = host(nil, "deploy", "-F", sshConfig, "acx", "--mirror", mirror, "--version", tagBroken)
	expect(err != nil, "the broken release reported success")
	expect(remoteStatus()["version"] == tagGood2, "the broken release did not roll back")
	fmt.Println("the broken release rolled back to", tagGood2)
	out, err = host(nil, "deploy", "-F", sshConfig, "acx", "--mirror", mirror, "--version", tagAPI)
	expect(err != nil && strings.Contains(out, "uses API 2"), "the incompatible release was not refused: %v", err)
	expect(remoteStatus()["version"] == tagGood2, "the incompatible release changed the server")
	fmt.Println("refused the release with API 2")
	out, err = host(nil, "rollback", "-F", sshConfig, "acx")
	must(err)
	expect(report(out)["version"] == tagGood1, "rollback went to %v", report(out)["version"])
	fmt.Println("rolled back to", tagGood1)
	out, err = host(nil, "deploy", "-F", sshConfig, "acx", "--mirror", mirror)
	must(err)
	expect(remoteStatus()["version"] == tagGood2, "deploy without --version did not pick the newest working release")
	fmt.Println("deploy without --version chose the newest release,", tagGood2)

	step("connect from this Mac and survive a dropped SSH connection")
	c := exec.Command(agentctl, "host", "connect", "acx")
	c.Env = append(os.Environ(), "AGENT_COMMANDER_HOME="+filepath.Join(work, "mac"))
	stdout, err := c.StdoutPipe()
	must(err)
	must(c.Start())
	defer c.Process.Kill()
	events := make(chan map[string]any, 16)
	go func() {
		scan := bufio.NewScanner(stdout)
		for scan.Scan() {
			var e map[string]any
			if json.Unmarshal(scan.Bytes(), &e) == nil {
				events <- e
			}
		}
	}()
	waitReady := func() string {
		deadline := time.After(90 * time.Second)
		for {
			select {
			case e := <-events:
				fmt.Println("event:", e["event"], e["detail"])
				if e["event"] == "ready" {
					return e["socket"].(string)
				}
			case <-deadline:
				panic("connect did not report ready")
			}
		}
	}
	socket := waitReady()
	out, err = cmd(root, []string{"AGENT_COMMANDER_SOCKET=" + socket}, agentctl, "api", "GET", "/v1/health")
	must(err)
	expect(strings.Contains(out, tagGood2), "the forwarded service reports %s", out)
	_, _ = cmd(root, nil, "docker", "exec", container, "pkill", "-f", "sshd: ops")
	socket = waitReady()
	out, err = cmd(root, []string{"AGENT_COMMANDER_SOCKET=" + socket}, agentctl, "api", "GET", "/v1/health")
	must(err)
	expect(strings.Contains(out, tagGood2), "after reconnecting the service reports %s", out)
	fmt.Println("reached the service through", socket, "before and after the drop")
	c.Process.Kill()
	c.Wait()

	step("remove the service and keep its versions and state")
	_, err = host(nil, "remove", "-F", sshConfig, "acx")
	must(err)
	out, _ = ssh("systemctl --user is-active agent-commander.service; ls ~/.local/share/agent-commander/versions")
	expect(strings.HasPrefix(out, "inactive"), "the unit is still active: %s", out)
	fmt.Print(out)
	step("All headless rehearsals passed")
}

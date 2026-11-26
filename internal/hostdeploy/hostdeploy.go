// Package hostdeploy deploys the headless Commander service from this Mac to
// a Linux server over SSH. It picks a GitHub release, downloads and verifies
// the archive here, streams it to the server, checks that its API version
// matches this build, and has the server install it. The server side is
// package headless; transport and release handling come from hostkit.
package hostdeploy

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"

	"agentcommander.network/hostkit/release"
	"agentcommander.network/hostkit/sshx"

	"agentcommander/internal/buildinfo"
	"agentcommander/internal/headless"
)

// DefaultRepo publishes the releases.
const DefaultRepo = "ryanhelms/agent-commander"

const sums = "SHA256SUMS"

// ArchiveName is the release asset for one architecture.
func ArchiveName(arch string) string { return "agent-commander-headless-linux-" + arch + ".tar.gz" }

// Options control a deploy.
type Options struct {
	Target  sshx.Target
	Source  release.Source
	Version string // a tag, or "" for the newest release with headless assets
	// Archive and Sums deploy a local build instead of a release.
	Archive, Sums string
	// Force deploys a release whose API version differs from this build.
	Force                bool
	SudoLinger           bool
	InstallPrerequisites bool
	// Progress receives each step as it completes.
	Progress func(headless.Step)
}

// Result is a deploy's outcome: the Mac-side steps and the server's report.
type Result struct {
	Destination string           `json:"destination"`
	Version     string           `json:"version,omitempty"`
	Attestation string           `json:"attestation,omitempty"`
	Steps       []headless.Step  `json:"steps"`
	Doctor      *headless.Report `json:"doctor,omitempty"`
	Server      *headless.Report `json:"server,omitempty"`
	OK          bool             `json:"ok"`
}

func (r *Result) add(o Options, s headless.Step) bool {
	r.Steps = append(r.Steps, s)
	if o.Progress != nil {
		o.Progress(s)
	}
	return s.OK || !s.Required
}

func step(name string, err error, detail string) headless.Step {
	if err != nil {
		return headless.Step{Step: name, Required: true, Detail: err.Error()}
	}
	return headless.Step{Step: name, OK: true, Required: true, Detail: detail}
}

// remoteData is the server's headless directory, resolved by its shell.
const remoteData = `"${XDG_DATA_HOME:-$HOME/.local/share}/agent-commander"`

// Deploy installs or upgrades the headless service on the target.
func Deploy(ctx context.Context, o Options) Result {
	r := Result{Destination: o.Target.Destination}
	goos, arch, err := o.Target.Platform(ctx)
	if err == nil && goos != "linux" {
		err = fmt.Errorf("the server runs %s; the headless service needs Linux", goos)
	}
	if !r.add(o, step("connect", err, "linux/"+arch)) {
		return r
	}
	work, err := os.MkdirTemp("", "agent-commander-deploy-")
	if !r.add(o, step("prepare", err, "")) {
		return r
	}
	defer os.RemoveAll(work)

	archive, sumsPath, version := o.Archive, o.Sums, o.Version
	if archive == "" {
		rel, err := o.Source.Find(ctx, o.Version, ArchiveName(arch), sums)
		if !r.add(o, step("release", err, rel.Tag)) {
			return r
		}
		version = rel.Tag
		archive, err = o.Source.Download(ctx, rel, ArchiveName(arch), work)
		if err == nil {
			sumsPath, err = o.Source.Download(ctx, rel, sums, work)
		}
		if !r.add(o, step("download", err, ArchiveName(arch))) {
			return r
		}
	}
	r.Version = version
	err = release.VerifySum(sumsPath, archive)
	if !r.add(o, step("checksum", err, "matches "+sums)) {
		return r
	}
	if o.Archive == "" {
		att, err := release.VerifyAttestation(ctx, o.Source.Repo, archive)
		r.Attestation = string(att)
		detail := map[release.Attestation]string{release.Verified: "verified", release.Absent: "none published; relying on " + sums,
			release.Unchecked: "gh is not available to check"}[att]
		if !r.add(o, step("attestation", err, detail)) {
			return r
		}
	}

	// Upload and unpack into a private temporary directory on the server.
	data, err := os.ReadFile(archive)
	if !r.add(o, step("read archive", err, "")) {
		return r
	}
	out, err := o.Target.Run(ctx, `set -eu
d=$(mktemp -d "${TMPDIR:-/tmp}/agent-commander-deploy.XXXXXX")
cat > "$d/archive.tar.gz"
tar -xzf "$d/archive.tar.gz" -C "$d"
rm "$d/archive.tar.gz"
"$d/agent-commander-headless/agentctl" host version >/dev/null
printf '%s\n' "$d"`, bytes.NewReader(data))
	dir := strings.TrimSpace(string(out))
	if err == nil && !strings.HasPrefix(dir, "/") {
		err = fmt.Errorf("unexpected upload directory %q", dir)
	}
	if !r.add(o, step("upload", err, fmt.Sprintf("%d bytes", len(data)))) {
		return r
	}
	defer o.Target.Run(context.WithoutCancel(ctx), "rm -rf "+sshx.Quote(dir), nil)
	newBin := dir + "/agent-commander-headless/agentctl"

	// Compatibility: the new binary's API version must match this build.
	out, err = o.Target.Run(ctx, sshx.Quote(newBin)+" host version", nil)
	var v struct {
		Version string `json:"version"`
		API     int    `json:"api"`
	}
	if err == nil {
		err = json.Unmarshal(out, &v)
	}
	if err == nil && v.API != buildinfo.APIVersion {
		err = fmt.Errorf("version %s uses API %d and this Commander uses API %d", v.Version, v.API, buildinfo.APIVersion)
		if o.Force {
			r.add(o, headless.Step{Step: "compatibility", Detail: err.Error() + "; deploying anyway with --force"})
			err = nil
		}
	}
	if err == nil && version != "" && buildinfo.IsRelease(version) && v.Version != version {
		err = fmt.Errorf("the archive contains %s, not %s", v.Version, version)
	}
	if version == "" {
		version, r.Version = v.Version, v.Version
	}
	if !r.add(o, step("compatibility", err, fmt.Sprintf("API %d", v.API))) {
		return r
	}

	if o.InstallPrerequisites {
		_, err := o.Target.Run(ctx, prerequisiteScript, nil)
		if !r.add(o, step("prerequisites", err, "git, tmux and curl")) {
			return r
		}
	}
	out, _ = o.Target.Run(ctx, sshx.Quote(newBin)+" host doctor", nil)
	var doctor headless.Report
	if json.Unmarshal(out, &doctor) == nil {
		r.Doctor = &doctor
		missing := []string{}
		for _, s := range doctor.Steps {
			if s.Required && !s.OK {
				missing = append(missing, s.Step)
			}
		}
		detail := "all prerequisites present"
		if len(missing) > 0 {
			detail = "missing: " + strings.Join(missing, ", ") + "; run `agentctl host doctor` on the server"
		}
		r.add(o, headless.Step{Step: "doctor", OK: len(missing) == 0, Detail: detail})
	}

	// The installed version, when there is one, installs the new binary, so
	// a new binary that cannot start still rolls back.
	args := []string{"host", "install", "--source", newBin, "--version", version}
	if o.SudoLinger {
		args = append(args, "--sudo-linger")
	}
	quoted := make([]string, len(args))
	for i, a := range args {
		quoted[i] = sshx.Quote(a)
	}
	script := `installer=` + sshx.Quote(newBin) + `
current=` + remoteData + `/current/agentctl
if [ -x "$current" ]; then installer=$current; fi
exec "$installer" ` + strings.Join(quoted, " ")
	out, err = o.Target.Run(ctx, script, nil)
	var server headless.Report
	if jerr := json.Unmarshal(out, &server); jerr == nil {
		r.Server = &server
	} else if err == nil {
		err = jerr
	}
	if err != nil && r.Server != nil {
		err = fmt.Errorf("the server did not install %s", version)
		for _, s := range server.Steps {
			if s.Required && !s.OK {
				err = fmt.Errorf("%s: %s", s.Step, s.Detail)
			}
		}
	}
	installed := ""
	if r.Server != nil {
		installed = r.Server.Version
	}
	if !r.add(o, step("install", err, "running "+installed)) {
		if r.Server != nil && r.Server.Version != "" && r.Server.Version != version {
			r.add(o, headless.Step{Step: "rolled back", OK: true, Detail: "the server is back on " + r.Server.Version})
		}
		return r
	}
	r.OK = true
	return r
}

// prerequisiteScript installs the packages a package manager can supply.
// Node, Claude Code and the ACP adapter need their own installers.
const prerequisiteScript = `set -eu
sudo=; [ "$(id -u)" = 0 ] || sudo="sudo -n"
if command -v apt-get >/dev/null 2>&1; then
  $sudo env DEBIAN_FRONTEND=noninteractive apt-get update -q
  $sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends git tmux curl ca-certificates
elif command -v dnf >/dev/null 2>&1; then
  $sudo dnf install -y -q git tmux curl ca-certificates
else
  echo "no apt-get or dnf; install git, tmux and curl by hand" >&2; exit 1
fi`

// Remote runs a server-side host verb (status, rollback, remove) and
// returns its report.
func Remote(ctx context.Context, t sshx.Target, verb string) (headless.Report, error) {
	switch verb {
	case "status", "rollback", "remove":
	default:
		return headless.Report{}, fmt.Errorf("unknown host verb %q", verb)
	}
	script := `current=` + remoteData + `/current/agentctl
if [ ! -x "$current" ]; then echo "the headless service is not installed on this server" >&2; exit 3; fi
exec "$current" host ` + verb
	out, err := t.Run(ctx, script, nil)
	var report headless.Report
	if jerr := json.Unmarshal(out, &report); jerr != nil {
		if err == nil {
			err = jerr
		}
		return report, err
	}
	var exit *sshx.Error
	if err != nil && !errors.As(err, &exit) {
		return report, err
	}
	return report, nil
}

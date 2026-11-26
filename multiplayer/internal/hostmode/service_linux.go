//go:build linux

package hostmode

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"text/template"
)

// UnitName is the systemd unit that runs a Linux host relay.
const UnitName = "agent-commander-relay.service"

const systemUnitDir = "/etc/systemd/system"

// A system unit runs as the account that owns the host directory, because
// PostgreSQL refuses to run as root. It may bind ports below 1024 and can
// write only to the host directory.
var systemdUnit = template.Must(template.New("unit").Parse(`[Unit]
Description=Agent Commander relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart={{.Exec}}
{{- if .PostgresBin}}
Environment={{.PostgresBin}}
{{- end}}
Restart=always
RestartSec=2
# The relay stops its PostgreSQL child with a fast, checkpointed shutdown.
KillMode=mixed
TimeoutStopSec=30
UMask=0077
NoNewPrivileges=yes
{{- if .System}}
User={{.User}}
Group={{.Group}}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths={{.Dir}}
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
{{- end}}

[Install]
WantedBy={{if .System}}multi-user.target{{else}}default.target{{end}}
`))

type unitSpec struct {
	Exec, PostgresBin, User, Group, Dir string
	System                              bool
}

// systemdQuote quotes one word for an ExecStart or Environment line.
func systemdQuote(word string) string {
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "%", "%%", "$", "$$")
	return `"` + r.Replace(word) + `"`
}

func renderUnit(spec unitSpec) ([]byte, error) {
	var out bytes.Buffer
	err := systemdUnit.Execute(&out, spec)
	return out.Bytes(), err
}

func systemctl(system bool, args ...string) error {
	if !system {
		args = append([]string{"--user"}, args...)
	}
	out, err := exec.Command("systemctl", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("systemctl %s: %w: %s", strings.Join(args, " "), err, bytes.TrimSpace(out))
	}
	return nil
}

// unitPath returns the unit file location: a system unit for root, otherwise
// the invoking user's systemd instance.
func unitPath() (string, bool, error) {
	if os.Geteuid() == 0 {
		dir := systemUnitDir
		if override := os.Getenv("COMMANDER_SYSTEMD_UNIT_DIR"); override != "" {
			dir = override
		}
		return filepath.Join(dir, UnitName), true, nil
	}
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", false, err
		}
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "systemd", "user", UnitName), false, nil
}

func serviceAccount(dir string) (string, string, error) {
	info, err := os.Stat(dir)
	if err != nil {
		return "", "", err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return "", "", errors.New("cannot read the host directory owner")
	}
	if st.Uid == 0 {
		return "", "", errors.New("PostgreSQL cannot run as root; give the host directory to a service account first, for example: useradd --system agent-commander && chown -R agent-commander: " + dir)
	}
	account, err := user.LookupId(strconv.FormatUint(uint64(st.Uid), 10))
	if err != nil {
		return "", "", fmt.Errorf("look up the host directory owner: %w", err)
	}
	group, err := user.LookupGroupId(strconv.FormatUint(uint64(st.Gid), 10))
	if err != nil {
		return "", "", fmt.Errorf("look up the host directory group: %w", err)
	}
	return account.Username, group.Name, nil
}

// Install writes the systemd unit, enables it at boot and starts or restarts it.
func Install(dir string) error {
	dir, err := filepath.Abs(dir)
	if err != nil {
		return err
	}
	if _, err := ReadConfig(dir); err != nil {
		return err
	}
	path, system, err := unitPath()
	if err != nil {
		return err
	}
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	if executable, err = filepath.EvalSymlinks(executable); err != nil {
		return err
	}
	spec := unitSpec{Dir: dir, System: system,
		Exec: strings.Join([]string{systemdQuote(executable), "host", "--dir", systemdQuote(dir)}, " ")}
	if bin := os.Getenv("COMMANDER_PG_BIN"); bin != "" {
		if bin, err = filepath.Abs(bin); err != nil {
			return err
		}
		spec.PostgresBin = systemdQuote("COMMANDER_PG_BIN=" + bin)
	}
	if system {
		if spec.User, spec.Group, err = serviceAccount(dir); err != nil {
			return err
		}
	}
	data, err := renderUnit(spec)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	old, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	changed := !bytes.Equal(old, data)
	if changed {
		if err := publishFile(path, data, true); err != nil {
			return err
		}
		if err := os.Chmod(path, 0644); err != nil {
			return err
		}
	}
	if err := systemctl(system, "daemon-reload"); err != nil {
		return err
	}
	if err := systemctl(system, "enable", UnitName); err != nil {
		return err
	}
	if changed {
		return systemctl(system, "restart", UnitName)
	}
	return systemctl(system, "start", UnitName)
}

// Uninstall stops and disables the unit and removes its file. The host
// directory, with its database and TLS identity, stays in place.
func Uninstall() error {
	path, system, err := unitPath()
	if err != nil {
		return err
	}
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err := systemctl(system, "disable", "--now", UnitName); err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return systemctl(system, "daemon-reload")
}

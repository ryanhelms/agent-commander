// Package systemd installs and removes one systemd service unit. It is the
// Linux supervisor adapter shared by the relay's host mode and the headless
// Commander service.
package systemd

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"text/template"
)

// SystemUnitDir holds system units. COMMANDER_SYSTEMD_UNIT_DIR overrides it
// for tests.
const SystemUnitDir = "/etc/systemd/system"

// Unit describes one service. Exec and Environment words are quoted when the
// unit is rendered, so callers pass them literally.
type Unit struct {
	Name        string // file name, such as agent-commander.service
	Description string
	Exec        []string
	Environment []string // KEY=VALUE pairs
	Restart     string   // always or on-failure; default always
	// KillMode decides what a stop or restart signals. The headless service
	// uses "process" so that tmux sessions and workers survive an upgrade.
	KillMode       string
	TimeoutStopSec int
	// System selects a system unit. Otherwise the unit belongs to the
	// invoking user's systemd instance.
	System bool
	// The fields below apply only to a system unit.
	User, Group    string
	Capabilities   []string // ambient and bounding set
	ReadWritePaths []string
	// Sandbox adds the strict file system and kernel protections.
	Sandbox bool
}

var unitTemplate = template.Must(template.New("unit").Funcs(template.FuncMap{"quote": Quote, "join": strings.Join}).Parse(`[Unit]
Description={{.Description}}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart={{range $i, $w := .Exec}}{{if $i}} {{end}}{{quote $w}}{{end}}
{{- range .Environment}}
Environment={{quote .}}
{{- end}}
Restart={{.Restart}}
RestartSec=2
{{- if .KillMode}}
KillMode={{.KillMode}}
{{- end}}
{{- if .TimeoutStopSec}}
TimeoutStopSec={{.TimeoutStopSec}}
{{- end}}
UMask=0077
NoNewPrivileges=yes
{{- if .System}}
{{- if .User}}
User={{.User}}
{{- end}}
{{- if .Group}}
Group={{.Group}}
{{- end}}
{{- if .Capabilities}}
AmbientCapabilities={{join .Capabilities " "}}
CapabilityBoundingSet={{join .Capabilities " "}}
{{- end}}
{{- if .Sandbox}}
ProtectSystem=strict
ProtectHome=read-only
{{- range .ReadWritePaths}}
ReadWritePaths={{.}}
{{- end}}
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
{{- end}}
{{- end}}

[Install]
WantedBy={{if .System}}multi-user.target{{else}}default.target{{end}}
`))

// Quote quotes one word for an ExecStart or Environment line.
func Quote(word string) string {
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "%", "%%", "$", "$$")
	return `"` + r.Replace(word) + `"`
}

// Render returns the unit file.
func Render(u Unit) ([]byte, error) {
	if u.Name == "" || strings.ContainsAny(u.Name, "/\n") || !strings.HasSuffix(u.Name, ".service") {
		return nil, fmt.Errorf("invalid unit name %q", u.Name)
	}
	if len(u.Exec) == 0 {
		return nil, errors.New("a unit needs an ExecStart command")
	}
	for _, field := range append(append([]string{u.Description}, u.Exec...), u.Environment...) {
		if strings.ContainsAny(field, "\n\r") {
			return nil, errors.New("unit fields must be single lines")
		}
	}
	if u.Restart == "" {
		u.Restart = "always"
	}
	var out bytes.Buffer
	err := unitTemplate.Execute(&out, u)
	return out.Bytes(), err
}

// Path returns the unit file location: the system directory, or the
// invoking user's systemd user directory.
func Path(name string, system bool) (string, error) {
	if system {
		dir := SystemUnitDir
		if override := os.Getenv("COMMANDER_SYSTEMD_UNIT_DIR"); override != "" {
			dir = override
		}
		return filepath.Join(dir, name), nil
	}
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "systemd", "user", name), nil
}

// Systemctl runs systemctl for a system or user unit.
func Systemctl(system bool, args ...string) error {
	_, err := systemctlOutput(system, args...)
	return err
}

func systemctlOutput(system bool, args ...string) (string, error) {
	if !system {
		args = append([]string{"--user"}, args...)
	}
	out, err := exec.Command("systemctl", args...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("systemctl %s: %w: %s", strings.Join(args, " "), err, bytes.TrimSpace(out))
	}
	return string(out), nil
}

// Install writes the unit, enables it and starts it. It restarts a running
// unit only when the file changed or restart is true.
func Install(u Unit, restart bool) error {
	data, err := Render(u)
	if err != nil {
		return err
	}
	path, err := Path(u.Name, u.System)
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
		if err := WriteFileAtomic(path, data, 0644); err != nil {
			return err
		}
	}
	if err := Systemctl(u.System, "daemon-reload"); err != nil {
		return err
	}
	if err := Systemctl(u.System, "enable", u.Name); err != nil {
		return err
	}
	if changed || restart {
		return Systemctl(u.System, "restart", u.Name)
	}
	return Systemctl(u.System, "start", u.Name)
}

// Uninstall stops and disables the unit and removes its file. It leaves
// every data directory in place.
func Uninstall(name string, system bool) error {
	path, err := Path(name, system)
	if err != nil {
		return err
	}
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err := Systemctl(system, "disable", "--now", name); err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return Systemctl(system, "daemon-reload")
}

// State reports systemd's ActiveState for the unit, such as active, failed
// or inactive. A missing unit reports inactive.
func State(name string, system bool) (string, error) {
	out, err := systemctlOutput(system, "show", "--property=ActiveState", "--value", name)
	return strings.TrimSpace(out), err
}

// WriteFileAtomic replaces path with data through a temporary file in the
// same directory.
func WriteFileAtomic(path string, data []byte, mode os.FileMode) error {
	f, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Chmod(mode); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}

// Linger reports whether the user's systemd instance keeps running after
// they log out.
func Linger(user string) (bool, error) {
	out, err := exec.Command("loginctl", "show-user", user, "--property=Linger", "--value").CombinedOutput()
	if err != nil && bytes.Contains(out, []byte("not logged in")) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("loginctl show-user: %w: %s", err, bytes.TrimSpace(out))
	}
	switch v := strings.TrimSpace(string(out)); v {
	case "yes":
		return true, nil
	case "no":
		return false, nil
	default:
		return strconv.ParseBool(v)
	}
}

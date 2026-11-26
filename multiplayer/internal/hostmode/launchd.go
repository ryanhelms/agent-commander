package hostmode

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"text/template"
)

const launchLabel = "local.agentcommander.relay"

var launchPlist = template.Must(template.New("relay").Parse(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>` + launchLabel + `</string>
	<key>ProgramArguments</key>
	<array>
		<string>{{html .Executable}}</string>
		<string>host</string>
		<string>--dir</string>
		<string>{{html .Dir}}</string>
	</array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>StandardOutPath</key><string>{{html .Dir}}/logs/relay.log</string>
	<key>StandardErrorPath</key><string>{{html .Dir}}/logs/relay.err.log</string>
	{{- if .PostgresBin}}
	<key>EnvironmentVariables</key>
	<dict><key>COMMANDER_PG_BIN</key><string>{{html .PostgresBin}}</string></dict>
	{{- end}}
</dict>
</plist>
`))

func launchAgentPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "LaunchAgents", launchLabel+".plist"), nil
}

func guiDomain() string {
	return fmt.Sprintf("gui/%d", os.Getuid())
}

func launchctl(args ...string) error {
	out, err := exec.Command("launchctl", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("launchctl %s: %w: %s", args[0], err, bytes.TrimSpace(out))
	}
	return nil
}

func bootout() error {
	err := launchctl("bootout", guiDomain()+"/"+launchLabel)
	var exit *exec.ExitError
	// launchctl uses ESRCH or its own "could not find service" code.
	if errors.As(err, &exit) && (exit.ExitCode() == int(syscall.ESRCH) || exit.ExitCode() == 113) {
		return nil
	}
	return err
}

func Install(dir string) error {
	dir, err := filepath.Abs(dir)
	if err != nil {
		return err
	}
	if _, err := ReadConfig(dir); err != nil {
		return err
	}
	plist, err := launchAgentPath()
	if err != nil {
		return err
	}
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	pgBin := os.Getenv("COMMANDER_PG_BIN")
	if pgBin != "" {
		pgBin, err = filepath.Abs(pgBin)
		if err != nil {
			return err
		}
	}
	var data bytes.Buffer
	err = launchPlist.Execute(&data, struct{ Executable, Dir, PostgresBin string }{executable, dir, pgBin})
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(dir, "logs"), 0700); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(plist), 0700); err != nil {
		return err
	}
	old, err := os.ReadFile(plist)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if bytes.Equal(old, data.Bytes()) {
		if launchctl("print", guiDomain()+"/"+launchLabel) == nil {
			return nil
		}
	} else {
		if old != nil {
			if err := bootout(); err != nil {
				return err
			}
		}
		if err := publishFile(plist, data.Bytes(), true); err != nil {
			return err
		}
	}
	return launchctl("bootstrap", guiDomain(), plist)
}

func Uninstall() error {
	plist, err := launchAgentPath()
	if err != nil {
		return err
	}
	if err := bootout(); err != nil {
		return err
	}
	err = os.Remove(plist)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// LockHost holds exclusive ownership of this host's data until the file is
// closed. A crashed host releases the lock, so status can ignore stale ports.
func LockHost(dir string, addr net.Addr) (*os.File, error) {
	f, err := os.OpenFile(filepath.Join(dir, "relay.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, errors.New("relay already running in this host directory")
		}
		return nil, err
	}
	if err = f.Truncate(0); err == nil {
		_, err = fmt.Fprintln(f, addr.String())
	}
	if err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}

func runningAddress(dir string) (string, error) {
	f, err := os.Open(filepath.Join(dir, "relay.lock"))
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	defer f.Close()
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_SH|syscall.LOCK_NB); err == nil {
		return "", nil
	} else if !errors.Is(err, syscall.EWOULDBLOCK) {
		return "", err
	}
	b, err := io.ReadAll(f)
	return strings.TrimSpace(string(b)), err
}

// Report is what the tray and `host status` show about this Mac's relay.
type Report struct {
	// State is "unconfigured" (no host.json yet), "stopped", "starting" (the launch agent is
	// installed but the relay doesn't hold its lock yet) or "running".
	State string `json:"state"`
	// Installed is true when the launch agent is in ~/Library/LaunchAgents.
	Installed bool   `json:"installed"`
	Name      string `json:"name,omitempty"`
	URL       string `json:"url,omitempty"`
	// Pin is the CA's SPKI pin, empty until the relay has started once.
	Pin string `json:"pin,omitempty"`
	Dir string `json:"dir"`
	// Log is the relay's error log, where a failed start explains itself.
	Log string `json:"log"`
	// Setup is what this Mac suggests for a first-time setup, only while unconfigured.
	Setup *Suggestion `json:"setup,omitempty"`
}

func launchAgentInstalled() (bool, error) {
	plist, err := launchAgentPath()
	if err != nil {
		return false, err
	}
	_, err = os.Stat(plist)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return err == nil, err
}

// Inspect reads the host's configuration, lock and certificate. A missing host.json is the
// "unconfigured" state, not an error.
func Inspect(dir string) (Report, error) {
	return InspectWith(dir, SystemProbe)
}

// InspectWith is Inspect with the probe that suggests a first-time setup.
func InspectWith(dir string, probe Probe) (Report, error) {
	report := Report{Dir: dir, Log: filepath.Join(dir, "logs", "relay.err.log")}
	installed, err := launchAgentInstalled()
	if err != nil {
		return report, err
	}
	report.Installed = installed
	cfg, err := ReadConfig(dir)
	if errors.Is(err, os.ErrNotExist) {
		report.State = "unconfigured"
		suggestion := probe.Suggest()
		report.Setup = &suggestion
		return report, nil
	}
	if err != nil {
		return report, err
	}
	report.Name = cfg.Name
	host, port, err := net.SplitHostPort(cfg.Listen)
	if err != nil {
		return report, err
	}
	report.State = "stopped"
	if installed {
		report.State = "starting"
	}
	addr, err := runningAddress(dir)
	if err != nil {
		return report, err
	}
	if addr != "" {
		report.State = "running"
		_, port, err = net.SplitHostPort(addr)
		if err != nil {
			return report, err
		}
	}
	if host == "" || net.ParseIP(host).IsUnspecified() {
		host = cfg.Hostnames[0]
	}
	report.URL = (&url.URL{Scheme: "https", Host: net.JoinHostPort(host, port)}).String()
	pin, err := CAPin(dir)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return report, err
	}
	report.Pin = pin
	return report, nil
}

func Status(dir string, output io.Writer) error {
	if _, err := ReadConfig(dir); err != nil {
		return err
	}
	report, err := Inspect(dir)
	if err != nil {
		return err
	}
	state := report.State
	if state == "starting" {
		// The plain status keeps its two states; launchd may still be bringing the relay up.
		state = "stopped"
	}
	pin := report.Pin
	if pin == "" {
		pin = "unavailable until first start"
	}
	_, err = fmt.Fprintf(output, "State: %s\nListen URL: %s\nCA SPKI pin: %s\n", state, report.URL, pin)
	return err
}

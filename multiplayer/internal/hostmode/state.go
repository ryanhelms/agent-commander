package hostmode

import (
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

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
	// Installed is true when the service manager has the relay: launchd on macOS. Linux reports false.
	Installed bool   `json:"installed"`
	Name      string `json:"name,omitempty"`
	URL       string `json:"url,omitempty"`
	// Pin is the server certificate's SPKI pin, the one a client pins; empty until the relay has
	// started once. CAPin is the issuing CA's.
	Pin   string `json:"pin,omitempty"`
	CAPin string `json:"caPin,omitempty"`
	Dir   string `json:"dir"`
	// Log is the relay's error log, where a failed start explains itself.
	Log string `json:"log"`
	// Setup is what this Mac suggests for a first-time setup, only while unconfigured.
	Setup *Suggestion `json:"setup,omitempty"`
}

// Inspect reads the host's configuration, lock and certificate. A missing host.json is the
// "unconfigured" state, not an error.
func Inspect(dir string) (Report, error) {
	return InspectWith(dir, SystemProbe)
}

// InspectWith is Inspect with the probe that suggests a first-time setup.
func InspectWith(dir string, probe Probe) (Report, error) {
	report := Report{Dir: dir, Log: filepath.Join(dir, "logs", "relay.err.log")}
	installed, err := serviceInstalled()
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
	if report.CAPin, err = CAPin(dir); err != nil && !errors.Is(err, os.ErrNotExist) {
		return report, err
	}
	if report.Pin, err = ServerPin(dir); err != nil && !errors.Is(err, os.ErrNotExist) {
		return report, err
	}
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
	shown := func(pin string) string {
		if pin == "" {
			return "unavailable until first start"
		}
		return pin
	}
	_, err = fmt.Fprintf(output, "State: %s\nListen URL: %s\nServer pin: %s\nCA SPKI pin: %s\n",
		state, report.URL, shown(report.Pin), shown(report.CAPin))
	return err
}

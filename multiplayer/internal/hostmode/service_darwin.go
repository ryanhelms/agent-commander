//go:build darwin

package hostmode

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
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

// serviceInstalled is true when the launch agent is in ~/Library/LaunchAgents.
func serviceInstalled() (bool, error) {
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

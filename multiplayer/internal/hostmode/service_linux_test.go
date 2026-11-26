//go:build linux

package hostmode

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"agentcommander.network/hostkit/systemd"
)

const mockSystemctl = `#!/bin/sh
echo "$*" >> "$HOME/systemctl.log"
`

func TestSystemdUserInstallUninstall(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("user units apply to a non-root account")
	}
	dir, _ := serviceFixture(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("PATH", home)
	t.Setenv("COMMANDER_PG_BIN", filepath.Join(dir, "my postgres", "bin"))
	if err := os.WriteFile(filepath.Join(home, "systemctl"), []byte(mockSystemctl), 0700); err != nil {
		t.Fatal(err)
	}
	if err := Install(dir); err != nil {
		t.Fatal(err)
	}
	unit := filepath.Join(home, ".config", "systemd", "user", UnitName)
	data, err := os.ReadFile(unit)
	if err != nil {
		t.Fatal(err)
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	exe, _ = filepath.EvalSymlinks(exe)
	for _, line := range []string{
		"ExecStart=" + systemdQuote(exe) + ` "host" "--dir" "` + dir + `"`,
		`Environment="COMMANDER_PG_BIN=` + filepath.Join(dir, "my postgres", "bin") + `"`,
		"Restart=always", "KillMode=mixed", "WantedBy=default.target",
	} {
		if !bytes.Contains(data, []byte(line+"\n")) {
			t.Errorf("unit missing %q:\n%s", line, data)
		}
	}
	if bytes.Contains(data, []byte("User=")) {
		t.Error("a user unit must not switch accounts")
	}
	// A second install with the same unit starts it without a restart.
	if err := Install(dir); err != nil {
		t.Fatal(err)
	}
	if err := Uninstall(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(unit); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("uninstall left %s: %v", unit, err)
	}
	log, err := os.ReadFile(filepath.Join(home, "systemctl.log"))
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Join([]string{
		"--user daemon-reload", "--user enable " + UnitName, "--user restart " + UnitName,
		"--user daemon-reload", "--user enable " + UnitName, "--user start " + UnitName,
		"--user disable --now " + UnitName, "--user daemon-reload",
	}, "\n") + "\n"
	if string(log) != want {
		t.Fatalf("systemctl calls:\n%s\nwant:\n%s", log, want)
	}
	// Uninstalling a missing unit succeeds without calling systemctl.
	if err := Uninstall(); err != nil {
		t.Fatal(err)
	}
}

func TestSystemUnitSandboxesServiceAccount(t *testing.T) {
	u := relayUnit("/usr/local/bin/commander-relay", "/var/lib/agent-commander/relay", "", true)
	u.User, u.Group = "agent-commander", "agent-commander"
	data, err := systemd.Render(u)
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range []string{
		"User=agent-commander", "Group=agent-commander", "AmbientCapabilities=CAP_NET_BIND_SERVICE",
		"CapabilityBoundingSet=CAP_NET_BIND_SERVICE", "ProtectSystem=strict",
		"ReadWritePaths=/var/lib/agent-commander/relay", "NoNewPrivileges=yes", "WantedBy=multi-user.target",
	} {
		if !bytes.Contains(data, []byte(line+"\n")) {
			t.Errorf("system unit missing %q:\n%s", line, data)
		}
	}
}

func TestSystemdQuoteEscapesSpecifiers(t *testing.T) {
	if got := systemdQuote(`/srv/50% "a"\$HOME`); got != `"/srv/50%% \"a\"\\$$HOME"` {
		t.Fatalf("unexpected quoting %s", got)
	}
}

func TestSystemInstallRefusesRootOwnedDirectory(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("system units require root")
	}
	dir, _ := serviceFixture(t)
	t.Setenv("COMMANDER_SYSTEMD_UNIT_DIR", t.TempDir())
	if err := Install(dir); err == nil || !strings.Contains(err.Error(), "cannot run as root") {
		t.Fatalf("expected a service-account error, got %v", err)
	}
}

func TestPostgresBinFindsPathInstall(t *testing.T) {
	bin := t.TempDir()
	for _, name := range []string{"postgres", "initdb"} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte("#!/bin/sh\n"), 0755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("COMMANDER_PG_BIN", "")
	t.Setenv("PATH", bin)
	if len(packagedPostgres()) == 0 {
		if got := postgresBin(); got != bin {
			t.Fatalf("expected PATH PostgreSQL %s, got %s", bin, got)
		}
	}
	t.Setenv("COMMANDER_PG_BIN", "/opt/pg/bin")
	if got := postgresBin(); got != "/opt/pg/bin" {
		t.Fatalf("COMMANDER_PG_BIN ignored: %s", got)
	}
}

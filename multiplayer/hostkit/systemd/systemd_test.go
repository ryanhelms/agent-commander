package systemd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const mockSystemctl = "#!/bin/sh\necho \"$*\" >> \"$HOME/systemctl.log\"\n"

func TestRenderQuotesEveryWord(t *testing.T) {
	data, err := Render(Unit{Name: "x.service", Description: "X", Exec: []string{"/opt/a b/agentctl", "serve"},
		Environment: []string{"PATH=/usr/bin:/home/u/50%"}, Restart: "on-failure", KillMode: "process"})
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range []string{`ExecStart="/opt/a b/agentctl" "serve"`, `Environment="PATH=/usr/bin:/home/u/50%%"`,
		"Restart=on-failure", "KillMode=process", "WantedBy=default.target"} {
		if !strings.Contains(string(data), line+"\n") {
			t.Errorf("missing %q:\n%s", line, data)
		}
	}
	if strings.Contains(string(data), "User=") || strings.Contains(string(data), "ProtectSystem") {
		t.Errorf("a user unit must not switch accounts or sandbox:\n%s", data)
	}
}

func TestRenderRejectsMultilineFields(t *testing.T) {
	if _, err := Render(Unit{Name: "x.service", Exec: []string{"a\nExecStartPre=/bin/evil"}}); err == nil {
		t.Fatal("expected an error for a newline in ExecStart")
	}
	if _, err := Render(Unit{Name: "../x.service", Exec: []string{"a"}}); err == nil {
		t.Fatal("expected an error for a path in the unit name")
	}
}

func TestUserInstallRestartsOnlyWhenChanged(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("PATH", home)
	if err := os.WriteFile(filepath.Join(home, "systemctl"), []byte(mockSystemctl), 0700); err != nil {
		t.Fatal(err)
	}
	u := Unit{Name: "x.service", Description: "X", Exec: []string{"/bin/true"}}
	for _, restart := range []bool{false, false, true} {
		if err := Install(u, restart); err != nil {
			t.Fatal(err)
		}
	}
	if err := Uninstall(u.Name, false); err != nil {
		t.Fatal(err)
	}
	log, err := os.ReadFile(filepath.Join(home, "systemctl.log"))
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Join([]string{
		"--user daemon-reload", "--user enable x.service", "--user restart x.service",
		"--user daemon-reload", "--user enable x.service", "--user start x.service",
		"--user daemon-reload", "--user enable x.service", "--user restart x.service",
		"--user disable --now x.service", "--user daemon-reload",
	}, "\n") + "\n"
	if string(log) != want {
		t.Fatalf("systemctl calls:\n%s\nwant:\n%s", log, want)
	}
}

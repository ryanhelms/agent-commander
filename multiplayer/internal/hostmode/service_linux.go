//go:build linux

package hostmode

import (
	"errors"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"syscall"

	"agentcommander.network/hostkit/systemd"
)

// UnitName is the systemd unit that runs a Linux host relay.
const UnitName = "agent-commander-relay.service"

// relayUnit describes the relay service. A system unit runs as the account
// that owns the host directory, because PostgreSQL refuses to run as root. It
// may bind ports below 1024 and can write only to the host directory. The
// relay stops its PostgreSQL child with a fast, checkpointed shutdown, so a
// stop signals the main process first (KillMode=mixed).
func relayUnit(executable, dir, postgresBin string, system bool) systemd.Unit {
	u := systemd.Unit{Name: UnitName, Description: "Agent Commander relay",
		Exec: []string{executable, "host", "--dir", dir}, Restart: "always",
		KillMode: "mixed", TimeoutStopSec: 30, System: system}
	if postgresBin != "" {
		u.Environment = []string{"COMMANDER_PG_BIN=" + postgresBin}
	}
	if system {
		u.Capabilities = []string{"CAP_NET_BIND_SERVICE"}
		u.ReadWritePaths = []string{dir}
		u.Sandbox = true
	}
	return u
}

func systemdQuote(word string) string { return systemd.Quote(word) }

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
	system := os.Geteuid() == 0
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	if executable, err = filepath.EvalSymlinks(executable); err != nil {
		return err
	}
	bin := os.Getenv("COMMANDER_PG_BIN")
	if bin != "" {
		if bin, err = filepath.Abs(bin); err != nil {
			return err
		}
	}
	u := relayUnit(executable, dir, bin, system)
	if system {
		if u.User, u.Group, err = serviceAccount(dir); err != nil {
			return err
		}
	}
	return systemd.Install(u, false)
}

// Uninstall stops and disables the unit and removes its file. The host
// directory, with its database and TLS identity, stays in place.
func Uninstall() error {
	return systemd.Uninstall(UnitName, os.Geteuid() == 0)
}

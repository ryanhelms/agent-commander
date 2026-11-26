//go:build linux

package hostmode

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"syscall"
)

const (
	ServiceAccount = LinuxServiceAccount
	ServiceBase    = LinuxServiceBase
	ServiceDir     = LinuxServiceDir
	ServiceBinary  = LinuxServiceBinary
)

// Provision installs the relay as a sandboxed system service. It runs as
// root on the server: it installs the distribution's PostgreSQL server when
// none is present, creates the service account and its 0700 directory,
// moves binary into place, writes the configuration on the first run only,
// and installs the systemd unit. A redeploy keeps host.json, the database
// and the TLS identity.
func Provision(binary string, cfg Config, log func(string)) error {
	if os.Geteuid() != 0 {
		return errors.New("provision runs as root; deploy with an SSH user that is root or has passwordless sudo")
	}
	if _, err := exec.LookPath("systemctl"); err != nil {
		return errors.New("systemd is required for the service deployment")
	}
	if !serverBinaries(postgresBin()) {
		log("Installing PostgreSQL from the distribution")
		if err := installPostgres(); err != nil {
			return err
		}
	}
	if _, err := user.Lookup(ServiceAccount); err != nil {
		nologin, err := exec.LookPath("nologin")
		if err != nil {
			nologin = "/bin/false"
		}
		if err := run("useradd", "--system", "--user-group", "--home-dir", ServiceBase, "--no-create-home",
			"--shell", nologin, ServiceAccount); err != nil {
			return err
		}
	}
	account, err := user.Lookup(ServiceAccount)
	if err != nil {
		return err
	}
	uid, _ := strconv.Atoi(account.Uid)
	gid, _ := strconv.Atoi(account.Gid)
	if err := os.MkdirAll(ServiceBase, 0755); err != nil {
		return err
	}
	if err := os.Chmod(ServiceBase, 0755); err != nil {
		return err
	}
	if err := os.MkdirAll(ServiceDir, 0700); err != nil {
		return err
	}
	if err := os.Chown(ServiceDir, uid, gid); err != nil {
		return err
	}
	if err := os.Chmod(ServiceDir, 0700); err != nil {
		return err
	}
	if err := installBinary(binary); err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(ServiceDir, "host.json")); errors.Is(err, os.ErrNotExist) {
		log("Creating the relay configuration")
		args := append([]string{"host", "--dir", ServiceDir, "init"}, cfg.InitFlags()...)
		cmd := exec.Command(ServiceBinary, args...)
		cmd.Env = append(os.Environ(), "HOME="+ServiceBase)
		cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: uint32(uid), Gid: uint32(gid)}}
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("host init: %w: %s", err, out)
		}
	} else {
		log("Keeping the existing configuration in " + filepath.Join(ServiceDir, "host.json"))
	}
	// The installed binary writes the unit so that ExecStart names it.
	cmd := exec.Command(ServiceBinary, "host", "--dir", ServiceDir, "install")
	cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
	return cmd.Run()
}

func installBinary(binary string) error {
	data, err := os.ReadFile(binary)
	if err != nil {
		return err
	}
	tmp := ServiceBinary + ".new"
	if err := os.WriteFile(tmp, data, 0755); err != nil {
		return err
	}
	if err := os.Chmod(tmp, 0755); err != nil {
		return err
	}
	if err := os.Rename(tmp, ServiceBinary); err != nil {
		return err
	}
	if binary != ServiceBinary {
		_ = os.Remove(binary)
	}
	return nil
}

func installPostgres() error {
	switch {
	case lookable("apt-get"):
		// Host mode runs its own private cluster, so skip the distribution's default one.
		if err := os.MkdirAll("/etc/postgresql-common/createcluster.d", 0755); err != nil {
			return err
		}
		if err := os.WriteFile("/etc/postgresql-common/createcluster.d/agent-commander.conf", []byte("create_main_cluster = false\n"), 0644); err != nil {
			return err
		}
		if err := run("env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "update", "-qq"); err != nil {
			return err
		}
		return run("env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", "-qq", "--no-install-recommends", "postgresql")
	case lookable("dnf"):
		return run("dnf", "install", "-y", "-q", "postgresql-server")
	default:
		return errors.New("install PostgreSQL 15 or newer, then deploy again")
	}
}

func lookable(name string) bool { _, err := exec.LookPath(name); return err == nil }

func run(name string, args ...string) error {
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s: %w: %s", name, err, out)
	}
	return nil
}

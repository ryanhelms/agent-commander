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

func Status(dir string, output io.Writer) error {
	cfg, err := ReadConfig(dir)
	if err != nil {
		return err
	}
	host, port, err := net.SplitHostPort(cfg.Listen)
	if err != nil {
		return err
	}
	state := "stopped"
	addr, err := runningAddress(dir)
	if err != nil {
		return err
	}
	if addr != "" {
		state = "running"
		_, port, err = net.SplitHostPort(addr)
		if err != nil {
			return err
		}
	}
	if host == "" || net.ParseIP(host).IsUnspecified() {
		host = cfg.Hostnames[0]
	}
	listenURL := url.URL{Scheme: "https", Host: net.JoinHostPort(host, port)}
	pin, err := CAPin(dir)
	if errors.Is(err, os.ErrNotExist) {
		pin = "unavailable until first start"
	} else if err != nil {
		return err
	}
	serverPin, err := ServerPin(dir)
	if errors.Is(err, os.ErrNotExist) {
		serverPin = "unavailable until first start"
	} else if err != nil {
		return err
	}
	_, err = fmt.Fprintf(output, "State: %s\nListen URL: %s\nServer pin: %s\nCA SPKI pin: %s\n", state, listenURL.String(), serverPin, pin)
	return err
}

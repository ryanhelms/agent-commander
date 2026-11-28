package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"syscall"
	"time"
)

var errSocketOwnerUnknown = errors.New("the socket owner could not be verified")

type process struct {
	pid     int
	path    string
	started time.Time
}

// Fencing uses the process start time as well as the PID and executable.
func (p process) same(other process) bool {
	return p.pid == other.pid && p.path == other.path && p.started.Equal(other.started)
}

// Stop a known device helper, even if it cannot yet process HTTP or SIGTERM.
// The scope is the exact socket owner. A different owner or an ambiguous
// snapshot is an error, and must never authorize a process signal.
func stopHelper(ctx context.Context, socket string, allowed map[string]bool, grace, force time.Duration, report io.Writer) error {
	old, err := socketOwner(ctx, socket)
	if err != nil || old == nil {
		return err
	}
	if !allowed[old.path] {
		return fmt.Errorf("PID %d owns %s but is outside the registered Commander helper paths (%s); inspect it and retry", old.pid, socket, old.path)
	}
	sent, err := signalHelper(ctx, socket, *old, syscall.SIGTERM)
	if err != nil {
		return err
	}
	if sent {
		fmt.Fprintf(report, "Stopping the previous network helper (PID %d).\n", old.pid)
	}
	done, err := waitForStop(ctx, socket, *old, grace)
	if err != nil || done {
		return err
	}

	sent, err = signalHelper(ctx, socket, *old, syscall.SIGKILL)
	if err != nil {
		return err
	}
	if sent {
		fmt.Fprintf(report, "The previous network helper did not stop after SIGTERM. Sent SIGKILL only to the verified owner (PID %d).\n", old.pid)
	}
	done, err = waitForStop(ctx, socket, *old, force)
	if err != nil {
		return err
	}
	if !done {
		return fmt.Errorf("PID %d did not release %s and exit; inspect it before retrying", old.pid, socket)
	}
	return nil
}

func signalHelper(ctx context.Context, socket string, old process, signal syscall.Signal) (bool, error) {
	current, err := socketOwner(ctx, socket)
	if err != nil {
		return false, err
	}
	if current == nil {
		running, err := inspectProcess(old.pid)
		if err != nil {
			return false, err
		}
		if running == nil || !running.same(old) {
			// The original exited before the signal.
			return false, nil
		}
		return false, fmt.Errorf("PID %d is still running but no longer owns %s; inspect it before retrying", old.pid, socket)
	}
	if !current.same(old) {
		return false, fmt.Errorf("ownership of %s changed to PID %d during shutdown; no signal sent to it", socket, current.pid)
	}
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if err := syscall.Kill(old.pid, signal); err != nil {
		if errors.Is(err, syscall.ESRCH) {
			return false, nil
		}
		return false, fmt.Errorf("signal PID %d on %s: %w", old.pid, socket, err)
	}
	return true, nil
}

func waitForStop(ctx context.Context, socket string, old process, duration time.Duration) (bool, error) {
	deadline := time.Now().Add(duration)
	for {
		current, err := socketOwner(ctx, socket)
		if err != nil {
			return false, err
		}
		if current == nil {
			running, err := inspectProcess(old.pid)
			if err != nil {
				return false, err
			}
			if running == nil || !running.same(old) {
				return true, nil
			}
		} else if !current.same(old) {
			return false, fmt.Errorf("ownership of %s changed to PID %d during shutdown", socket, current.pid)
		}
		if !time.Now().Before(deadline) {
			return false, nil
		}
		if err := pause(ctx); err != nil {
			return false, err
		}
	}
}

func verifyHelper(ctx context.Context, socket, expected string, built time.Time) (bool, error) {
	last := "the socket has no bound helper"
	for {
		owner, err := socketOwner(ctx, socket)
		if errors.Is(err, errSocketOwnerUnknown) {
			last = err.Error()
		} else if err != nil {
			return false, err
		}
		if owner != nil {
			if owner.path != expected {
				return false, fmt.Errorf("PID %d bound %s with %s, expected %s", owner.pid, socket, owner.path, expected)
			}
			if owner.started.Add(time.Microsecond).Before(built) {
				return false, fmt.Errorf("PID %d predates the newly bundled helper at %s", owner.pid, expected)
			}
			probe, cancel := context.WithTimeout(ctx, time.Second)
			pending, err := readStatus(probe, socket)
			cancel()
			if err == nil {
				confirmed, err := socketOwner(ctx, socket)
				if err != nil && !errors.Is(err, errSocketOwnerUnknown) {
					return false, err
				}
				if confirmed != nil && confirmed.same(*owner) {
					return pending, nil
				}
				last = "the socket owner changed while reading status"
			} else {
				last = err.Error()
			}
		}
		if err := pause(ctx); err != nil {
			return false, fmt.Errorf("could not verify the newly bundled helper on %s: %s", socket, last)
		}
	}
}

func socketOwner(ctx context.Context, socket string) (*process, error) {
	pids, err := listeningProcesses(ctx, socket)
	if err != nil {
		return nil, err
	}
	if len(pids) > 1 {
		return nil, fmt.Errorf("ambiguous ownership of %s (PIDs %v); inspect the socket before retrying", socket, pids)
	}
	if len(pids) == 1 {
		current, err := inspectProcess(pids[0])
		if err != nil {
			return nil, err
		}
		if current != nil {
			return current, nil
		}
	}
	// A successful connection with no observable owner is not a vacant socket.
	conn, err := (&net.Dialer{Timeout: 200 * time.Millisecond}).DialContext(ctx, "unix", socket)
	if err == nil {
		conn.Close()
		return nil, fmt.Errorf("%w for %s, which is accepting connections", errSocketOwnerUnknown, socket)
	}
	if !errors.Is(err, os.ErrNotExist) && !errors.Is(err, syscall.ECONNREFUSED) {
		return nil, fmt.Errorf("verify that %s is vacant: %w", socket, err)
	}
	return nil, nil
}

func readStatus(ctx context.Context, socket string) (bool, error) {
	transport := &http.Transport{
		MaxResponseHeaderBytes: 64 << 10,
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", socket)
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{
		Transport:     transport,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://local/tray/servers", strings.NewReader("{}"))
	if err != nil {
		return false, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	var envelope struct {
		OK   bool
		Data struct {
			Servers []struct{ State string }
		}
	}
	if resp.StatusCode != http.StatusOK || json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(&envelope) != nil ||
		!envelope.OK || envelope.Data.Servers == nil {
		return false, errors.New("the local helper did not return a valid server list")
	}
	for _, server := range envelope.Data.Servers {
		if server.State == "keychainPending" {
			return true, nil
		}
	}
	return false, nil
}

func pause(ctx context.Context) error {
	timer := time.NewTimer(150 * time.Millisecond)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

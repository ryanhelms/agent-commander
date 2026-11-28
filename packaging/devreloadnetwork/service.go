package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"syscall"
	"time"

	"agentcommander/internal/localapi"
)

func runService(args []string) error {
	paths, err := localapi.Config()
	if err != nil {
		return fmt.Errorf("find the local service socket: %w", err)
	}
	switch {
	case len(args) == 1 && args[0] == "service-stop":
		ctx, cancel := context.WithTimeout(context.Background(), 14*time.Second)
		defer cancel()
		allowed, err := developmentExecutables(ctx, "agentctl")
		if err != nil {
			return err
		}
		return stopService(ctx, paths.Socket, allowed, 10*time.Second, os.Stdout)
	case len(args) == 2 && args[0] == "service-ready":
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		exe, err := filepath.EvalSymlinks(args[1])
		if err != nil {
			return err
		}
		file, err := os.Stat(exe)
		if err != nil {
			return err
		}
		if err := verifyService(ctx, paths.Socket, exe, file.ModTime()); err != nil {
			return err
		}
		fmt.Printf("The new Commander service owns %s and responds.\n", paths.Socket)
		return nil
	default:
		return errors.New("usage: dev-reload-network service-stop | service-ready BUNDLED_AGENTCTL")
	}
}

func stopService(ctx context.Context, socket string, allowed map[string]bool, grace time.Duration, report io.Writer) error {
	old, err := socketOwner(ctx, socket)
	if err != nil {
		return err
	}
	if old == nil {
		fmt.Fprintf(report, "No Commander service owns %s. The app can start one.\n", socket)
		return nil
	}
	if !allowed[old.path] {
		return fmt.Errorf("PID %d owns %s but is outside the registered agentctl paths (%s); inspect it before retrying", old.pid, socket, old.path)
	}
	sent, err := signalSocketOwner(ctx, socket, *old, syscall.SIGTERM, verifyServeRole)
	if err != nil {
		return err
	}
	if sent {
		fmt.Fprintf(report, "Stopping the Commander service on %s (PID %d).\n", socket, old.pid)
	}
	done, err := waitForStop(ctx, socket, *old, grace)
	if err != nil {
		return err
	}
	if !done {
		return fmt.Errorf("PID %d did not release %s and exit after SIGTERM; inspect it before retrying", old.pid, socket)
	}
	return nil
}

func verifyServeRole(owner process) error {
	serve, err := ownsServeArguments(owner.pid)
	if err != nil {
		return err
	}
	current, err := inspectProcess(owner.pid)
	if err != nil {
		return err
	}
	if current == nil || !current.same(owner) {
		return fmt.Errorf("PID %d changed while verifying the service role", owner.pid)
	}
	if !serve {
		return fmt.Errorf("PID %d is not running agentctl serve; inspect the socket owner before retrying", owner.pid)
	}
	return nil
}

func verifyService(ctx context.Context, socket, expected string, built time.Time) error {
	client := localapi.New(socket, "")
	return verifyOwner(ctx, socket, expected, built, "Commander service", func(ctx context.Context, owner process) error {
		if err := verifyServeRole(owner); err != nil {
			return err
		}
		body, err := client.Do(ctx, http.MethodGet, "/v1/health", nil)
		if err != nil {
			return err
		}
		var health struct{ Status string }
		if err := json.Unmarshal(body, &health); err != nil || health.Status != "ok" {
			return errors.New("the owner did not return a healthy Commander service response")
		}
		return nil
	})
}

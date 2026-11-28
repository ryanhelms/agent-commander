// The dev reload script uses this tool to verify the selected local socket owner.
package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"time"
)

const bundledHelper = "dist/Agent Commander.app/Contents/MacOS/commander-network"

func main() {
	if err := run(os.Args[1:]); err != nil {
		label := "Network helper:"
		if len(os.Args) > 1 && strings.HasPrefix(os.Args[1], "service-") {
			label = "Commander service:"
		}
		fmt.Fprintln(os.Stderr, label, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) > 0 && strings.HasPrefix(args[0], "service-") {
		return runService(args)
	}
	owner, err := user.Current()
	if err != nil {
		return fmt.Errorf("find the normal owner socket: %w", err)
	}
	socket := filepath.Join(owner.HomeDir, ".agent-commander", "network.sock")
	switch {
	case len(args) == 1 && args[0] == "stop":
		ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
		defer cancel()
		allowed, err := developmentExecutables(ctx, "commander-network")
		if err != nil {
			return err
		}
		return stopHelper(ctx, socket, allowed, 4*time.Second, 3*time.Second, os.Stdout)
	case len(args) == 2 && args[0] == "ready":
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		helper, err := filepath.EvalSymlinks(args[1])
		if err != nil {
			return err
		}
		file, err := os.Stat(helper)
		if err != nil {
			return err
		}
		pending, err := verifyHelper(ctx, socket, helper, file.ModTime())
		if err != nil {
			return err
		}
		fmt.Println("The new network helper owns the normal socket and responds.")
		if pending {
			fmt.Println("A relay is waiting for macOS Keychain authorization.")
		}
		return nil
	default:
		return errors.New("usage: dev-reload-network stop | ready BUNDLED_HELPER | service-stop | service-ready BUNDLED_AGENTCTL")
	}
}

func developmentExecutables(ctx context.Context, name string) (map[string]bool, error) {
	out, err := exec.CommandContext(ctx, "git", "worktree", "list", "--porcelain", "-z").Output()
	if err != nil {
		return nil, fmt.Errorf("list registered Commander checkouts: %w", err)
	}
	allowed := make(map[string]bool)
	for _, entry := range bytes.Split(out, []byte{0}) {
		root, ok := strings.CutPrefix(string(entry), "worktree ")
		if !ok {
			continue
		}
		canonical, err := filepath.EvalSymlinks(root)
		if err != nil {
			// A prunable checkout cannot authorize a process signal.
			continue
		}
		allowed[filepath.Join(canonical, "dist", "Agent Commander.app", "Contents", "MacOS", name)] = true
		allowed[filepath.Join(canonical, "dist", name)] = true
	}
	if len(allowed) == 0 {
		return nil, errors.New("no registered Commander checkout could be verified")
	}
	return allowed, nil
}

package device

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"time"

	"agentcommander.network/pilot/internal/identity"
)

const queueFile = "merge-queue.json"

func readQueue(path string) ([]queueEntry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var rows []queueEntry
	if err := json.Unmarshal(data, &rows); err != nil {
		return nil, fmt.Errorf("read merge queue: %w", err)
	}
	return rows, nil
}

// Older devices kept a single queue in the state root. The first saved
// server inherits it, even when another server is the first one opened.
func migrateQueue(dir, firstServer string) error {
	legacy := filepath.Join(dir, queueFile)
	rows, err := readQueue(legacy)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	serverDir := filepath.Join(dir, "servers", firstServer)
	if err = privateDir(serverDir); err != nil {
		return err
	}
	dst := filepath.Join(serverDir, queueFile)
	scoped, err := readQueue(dst)
	if errors.Is(err, os.ErrNotExist) {
		return os.Rename(legacy, dst)
	}
	if err != nil {
		return err
	}

	// Preserve newer states and make a retry after save but before remove
	// idempotent. Every enqueue records its addition time.
	type entryKey struct {
		workspace, branch, checkout string
		added                       time.Time
	}
	entryID := func(e queueEntry) entryKey { return entryKey{e.Workspace, e.Branch, e.Checkout, e.Added.UTC()} }
	seen := make(map[entryKey]bool, len(scoped))
	for _, e := range scoped {
		seen[entryID(e)] = true
	}
	combined := make([]queueEntry, 0, len(rows)+len(scoped))
	for _, e := range rows {
		if !seen[entryID(e)] {
			combined = append(combined, e)
		}
	}
	if len(combined) > 0 {
		if err = save(dst, append(combined, scoped...)); err != nil {
			return err
		}
	}
	return os.Remove(legacy)
}

// The relay lists only workspaces visible to this session on this server.
type queueWorkspaces struct {
	Workspaces []struct{ ID, Integration, Base string }
}

func (w queueWorkspaces) base(id string) (string, error) {
	for _, workspace := range w.Workspaces {
		if workspace.ID == id {
			if workspace.Integration != "queue" {
				return "", fmt.Errorf("workspace %s uses %s integration", id, workspace.Integration)
			}
			if workspace.Base == "" {
				return "", fmt.Errorf("workspace %s has no base branch", id)
			}
			return workspace.Base, nil
		}
	}
	return "", fmt.Errorf("unknown workspace %s", id)
}

// The manager selects the server's agent and tray serializes its mutations.
func (a *Agent) queueVerb(ctx context.Context, session identity.Session, verb string, in input) (any, error) {
	path := filepath.Join(a.cfg.Dir, queueFile)
	q, err := readQueue(path)
	if errors.Is(err, os.ErrNotExist) {
		q = []queueEntry{}
	} else if err != nil {
		return nil, err
	}
	switch verb {
	case "queue":
		return map[string]any{"queue": q}, nil
	case "queue-add":
		if !filepath.IsAbs(in.Checkout) || in.Branch == "" || in.Workspace == "" {
			return nil, errors.New("queue-add needs a workspace, a branch and the absolute checkout path")
		}
		var workspaces queueWorkspaces
		if err := a.remote(ctx, session, "GET", "/v1/workspaces", nil, &workspaces); err != nil {
			return nil, err
		}
		if _, err := workspaces.base(in.Workspace); err != nil {
			return nil, err
		}
		if err := checkQueueCheckout(ctx, in.Checkout); err != nil {
			return nil, err
		}
		q = append(q, queueEntry{Workspace: in.Workspace, Branch: in.Branch, Checkout: in.Checkout, Test: in.TestCommand, Added: time.Now().UTC(), State: "queued"})
	case "queue-remove":
		if in.Workspace == "" || in.Branch == "" {
			return nil, errors.New("queue-remove needs a workspace and a branch")
		}
		q = slices.DeleteFunc(q, func(entry queueEntry) bool {
			return entry.Workspace == in.Workspace && entry.Branch == in.Branch
		})
	case "queue-merge":
		selected := func(e queueEntry) bool {
			return e.State == "queued" && (in.Workspace == "" || e.Workspace == in.Workspace)
		}
		if !slices.ContainsFunc(q, selected) {
			return map[string]any{"queue": q}, nil
		}
		var workspaces queueWorkspaces
		if err := a.remote(ctx, session, "GET", "/v1/workspaces", nil, &workspaces); err != nil {
			return nil, err
		}
		for i := range q {
			if !selected(q[i]) {
				continue
			}
			base, err := workspaces.base(q[i].Workspace)
			if err != nil {
				q[i].State, q[i].Output = "failed", err.Error()
			} else {
				q[i].State, q[i].Output = mergeBranch(ctx, q[i], base)
			}
		}
	}
	return map[string]any{"queue": q}, save(path, q)
}

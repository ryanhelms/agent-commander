package provider

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"agentcommander/internal/service"
)

const (
	legacyJournalMaxEntries = 4096
	legacyJournalMaxFile    = 8 << 20
	legacyJournalMaxSearch  = 64 << 20
	legacyLaunchWindow      = 30 * time.Minute
)

// RecoverLegacyCoordinator links a pre-binding launch to the exact Claude
// conversation that asked Commander about this run. The working directory and
// initial prompt alone are insufficient when a task was launched more than once.
func (l *Local) RecoverLegacyCoordinator(ctx context.Context, spec service.LaunchSpec, created string) (service.NativeSession, string, error) {
	if spec.Role != "coordinator" || (spec.Host != "" && spec.Host != "localhost") ||
		!validID.MatchString(spec.ID) || !validID.MatchString(spec.RunID) || spec.Task == "" || !filepath.IsAbs(spec.Worktree) {
		return service.NativeSession{}, "", errors.New("legacy recovery requires a local coordinator with a saved checkout and launch prompt")
	}
	switch strings.ToLower(strings.TrimSpace(spec.Client)) {
	case "", "claude", "claude code":
	default:
		return service.NativeSession{}, "", errors.New("legacy coordinator recovery is available for Claude Code")
	}
	start, err := time.Parse(time.RFC3339, created)
	if err != nil {
		return service.NativeSession{}, "", errors.New("coordinator launch time is unavailable")
	}
	cwd, err := filepath.EvalSymlinks(spec.Worktree)
	if err != nil {
		return service.NativeSession{}, "", fmt.Errorf("resolve coordinator checkout: %w", err)
	}
	profile := os.Getenv("CLAUDE_CONFIG_DIR")
	if profile == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return service.NativeSession{}, "", err
		}
		profile = filepath.Join(home, ".claude")
	}
	if !filepath.IsAbs(profile) {
		return service.NativeSession{}, "", errors.New("CLAUDE_CONFIG_DIR must be an absolute path for session recovery")
	}
	sessionID, err := findLegacyCoordinatorJournal(ctx, profile, cwd, spec, start)
	if err != nil {
		return service.NativeSession{}, "", err
	}
	claude, err := executablePath("claude", "AGENT_COMMANDER_CLAUDE")
	if err != nil {
		return service.NativeSession{}, "", err
	}
	binding, err := legacyCoordinatorFingerprint(spec.Worktree, claude)
	if err != nil {
		return service.NativeSession{}, "", err
	}
	return service.NativeSession{HarnessInstance: service.LegacyClaudeHarness, SessionID: sessionID}, binding, nil
}

func findLegacyCoordinatorJournal(ctx context.Context, profile, cwd string, spec service.LaunchSpec, start time.Time) (string, error) {
	root, err := os.OpenRoot(profile)
	if err != nil {
		return "", fmt.Errorf("open Claude Code profile: %w", err)
	}
	defer root.Close()
	project, err := root.OpenRoot(filepath.Join("projects", claudeProjectSeparator.ReplaceAllString(cwd, "-")))
	if err != nil {
		return "", fmt.Errorf("open Claude Code journals for the coordinator checkout: %w", err)
	}
	defer project.Close()
	directory, err := project.Open(".")
	if err != nil {
		return "", err
	}
	defer directory.Close()
	entries, err := directory.ReadDir(legacyJournalMaxEntries + 1)
	if err != nil && !errors.Is(err, io.EOF) {
		return "", err
	}
	if len(entries) > legacyJournalMaxEntries {
		return "", errors.New("too many Claude Code journal entries to verify the original session")
	}
	var selected string
	remaining := int64(legacyJournalMaxSearch)
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		id, isJournal := strings.CutSuffix(entry.Name(), ".jsonl")
		if !isJournal || !journalSessionID.MatchString(id) || !entry.Type().IsRegular() {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return "", err
		}
		if info.ModTime().Before(start) {
			continue
		}
		if remaining <= 0 {
			return "", errors.New("Claude Code journal search exceeded its verification limit")
		}
		file, err := project.OpenFile(entry.Name(), os.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOFOLLOW, 0)
		if err != nil {
			return "", err
		}
		opened, err := file.Stat()
		if err != nil || !opened.Mode().IsRegular() || !os.SameFile(info, opened) {
			file.Close()
			return "", errors.New("Claude Code journal changed during verification")
		}
		limit := min(remaining, legacyJournalMaxFile)
		limited := &io.LimitedReader{R: file, N: limit}
		matches, err := matchesLegacyCoordinatorJournal(ctx, limited, id, cwd, spec, start)
		file.Close()
		remaining -= limit - limited.N
		if err != nil {
			return "", err
		}
		if matches {
			if selected != "" {
				return "", errors.New("more than one Claude Code journal matches the coordinator launch")
			}
			selected = id
		}
	}
	if selected == "" {
		return "", errors.New("no Claude Code journal proves the original coordinator session")
	}
	return selected, nil
}

type legacyCoordinatorRecord struct {
	Type, UUID, SessionID, Cwd, SourceToolAssistantUUID string
	IsSidechain                                         *bool
	Timestamp                                           time.Time
	Message                                             struct {
		Role    string
		Content json.RawMessage
	}
}

type legacyCoordinatorBlock struct {
	Type, Name, ID string
	ToolUseID      string `json:"tool_use_id"`
	Content        json.RawMessage
}

func matchesLegacyCoordinatorJournal(ctx context.Context, file *io.LimitedReader, id, cwd string, spec service.LaunchSpec, start time.Time) (bool, error) {
	input := bufio.NewReaderSize(file, 64<<10)
	var launchTime time.Time
	statusCalls := make(map[string]string)
	for {
		raw, _, err := readJournalLine(ctx, input)
		if err != nil {
			if file.N == 0 {
				return false, errors.New("Claude Code journal exceeded its verification limit")
			}
			if errors.Is(err, io.EOF) || errors.Is(err, errJournalIncomplete) {
				return false, nil
			}
			return false, err
		}
		var record legacyCoordinatorRecord
		if json.Unmarshal(raw, &record) != nil || record.IsSidechain == nil || *record.IsSidechain ||
			record.SessionID != id || record.Cwd != cwd || record.Type != record.Message.Role {
			continue
		}
		if launchTime.IsZero() {
			if record.Type != "user" {
				continue
			}
			var prompt string
			if json.Unmarshal(record.Message.Content, &prompt) != nil || prompt != spec.Task ||
				record.Timestamp.Before(start) || record.Timestamp.After(start.Add(legacyLaunchWindow)) {
				return false, nil
			}
			launchTime = record.Timestamp
			continue
		}
		if record.Timestamp.Before(launchTime) {
			continue
		}
		var blocks []legacyCoordinatorBlock
		if json.Unmarshal(record.Message.Content, &blocks) != nil {
			continue
		}
		for _, block := range blocks {
			if record.Type == "assistant" && block.Type == "tool_use" && block.Name == "mcp__commander__commander_status" &&
				block.ID != "" && record.UUID != "" {
				statusCalls[block.ID] = record.UUID
			}
			if record.Type == "user" && block.Type == "tool_result" && record.SourceToolAssistantUUID != "" &&
				statusCalls[block.ToolUseID] == record.SourceToolAssistantUUID && legacyStatusMatches(block, spec, cwd) {
				return true, nil
			}
		}
	}
}

func legacyStatusMatches(block legacyCoordinatorBlock, spec service.LaunchSpec, cwd string) bool {
	var parts []struct{ Type, Text string }
	if json.Unmarshal(block.Content, &parts) != nil {
		return false
	}
	for _, part := range parts {
		if part.Type != "text" {
			continue
		}
		var status struct {
			ID, Task, Path string
			CoordinatorID  string `json:"coordinator_id"`
		}
		if json.Unmarshal([]byte(part.Text), &status) == nil && status.ID == spec.RunID &&
			status.CoordinatorID == spec.ID && status.Task == spec.Task &&
			(status.Path == spec.Worktree || status.Path == cwd) {
			return true
		}
	}
	return false
}

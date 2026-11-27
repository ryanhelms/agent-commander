package provider

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agentcommander/internal/service"
)

func TestRecoverLegacyCoordinatorNeedsExactRunAndToolLink(t *testing.T) {
	cwd, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	spec := service.LaunchSpec{ID: "w-original", RunID: "r-original", Role: "coordinator",
		Host: "localhost", Client: "claude", Worktree: cwd, Task: "The exact original launch prompt.\nSecond line."}
	start := time.Now().UTC().Truncate(time.Second).Add(-time.Minute)
	for _, tc := range []struct {
		name   string
		alter  func([]map[string]any)
		accept bool
	}{
		{name: "exact", accept: true},
		{name: "another-run", alter: func(rows []map[string]any) { swapLegacyStatus(t, rows, "id", "r-other") }},
		{name: "another-coordinator", alter: func(rows []map[string]any) { swapLegacyStatus(t, rows, "coordinator_id", "w-other") }},
		{name: "another-checkout", alter: func(rows []map[string]any) { swapLegacyStatus(t, rows, "path", "/another/checkout") }},
		{name: "unlinked-source", alter: func(rows []map[string]any) { rows[2]["sourceToolAssistantUUID"] = "another-source" }},
		{name: "other-tool", alter: func(rows []map[string]any) { legacyTestBlock(rows[1])["name"] = "Read" }},
		{name: "another-native-session", alter: func(rows []map[string]any) { rows[2]["sessionId"] = journalOther }},
		{name: "sidechain", alter: func(rows []map[string]any) { rows[2]["isSidechain"] = true }},
		{name: "wrong-prompt", alter: func(rows []map[string]any) {
			rows[0]["message"].(map[string]any)["content"] = "Another launch prompt."
		}},
		{name: "before-launch", alter: func(rows []map[string]any) {
			rows[0]["timestamp"] = start.Add(-time.Second)
		}},
		{name: "outside-launch-window", alter: func(rows []map[string]any) {
			rows[0]["timestamp"] = start.Add(legacyLaunchWindow + time.Second)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			profile := t.TempDir()
			rows := legacyTestRecords(t, spec, journalFirst, start)
			if tc.alter != nil {
				tc.alter(rows)
			}
			writeLegacyTestJournal(t, profile, cwd, journalFirst, rows)
			got, err := findLegacyCoordinatorJournal(t.Context(), profile, cwd, spec, start)
			if tc.accept {
				if err != nil || got != journalFirst {
					t.Fatalf("expected original UUID, got %q, %v", got, err)
				}
			} else if err == nil || got != "" {
				t.Fatalf("accepted unverifiable journal %q, %v", got, err)
			}
		})
	}
}

func TestRecoverLegacyCoordinatorRejectsAmbiguityAndIgnoresSymlinks(t *testing.T) {
	profile, cwd := t.TempDir(), t.TempDir()
	spec := service.LaunchSpec{ID: "w-original", RunID: "r-original", Worktree: cwd, Task: "Exact launch task"}
	start := time.Now().UTC().Truncate(time.Second).Add(-time.Minute)
	first := writeLegacyTestJournal(t, profile, cwd, journalFirst, legacyTestRecords(t, spec, journalFirst, start))
	outside := writeLegacyTestJournal(t, t.TempDir(), cwd, journalOther, legacyTestRecords(t, spec, journalOther, start))
	link := filepath.Join(filepath.Dir(first), journalOther+".jsonl")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	got, err := findLegacyCoordinatorJournal(t.Context(), profile, cwd, spec, start)
	if err != nil || got != journalFirst {
		t.Fatalf("symlink must not be followed: got %q, %v", got, err)
	}
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	writeLegacyTestJournal(t, profile, cwd, journalOther, legacyTestRecords(t, spec, journalOther, start))
	got, err = findLegacyCoordinatorJournal(t.Context(), profile, cwd, spec, start)
	if got != "" || err == nil || !strings.Contains(err.Error(), "more than one") {
		t.Fatalf("must reject duplicate proofs: got %q, %v", got, err)
	}
}

func legacyTestRecords(t *testing.T, spec service.LaunchSpec, session string, start time.Time) []map[string]any {
	t.Helper()
	status, err := json.Marshal(map[string]string{
		"id": spec.RunID, "coordinator_id": spec.ID, "path": spec.Worktree, "task": spec.Task,
	})
	if err != nil {
		t.Fatal(err)
	}
	record := func(role string, content any, offset time.Duration) map[string]any {
		return map[string]any{
			"type": role, "cwd": spec.Worktree, "sessionId": session, "isSidechain": false,
			"timestamp": start.Add(offset), "message": map[string]any{"role": role, "content": content},
		}
	}
	assistant := record("assistant", []map[string]any{
		{"type": "tool_use", "id": "toolu_original", "name": "mcp__commander__commander_status"},
	}, time.Second)
	assistant["uuid"] = "assistant-uuid"
	result := record("user", []map[string]any{
		{"type": "tool_result", "tool_use_id": "toolu_original", "content": []map[string]any{
			{"type": "text", "text": string(status)},
		}},
	}, 2*time.Second)
	result["sourceToolAssistantUUID"] = "assistant-uuid"
	return []map[string]any{record("user", spec.Task, 0), assistant, result}
}

func legacyTestBlock(record map[string]any) map[string]any {
	return record["message"].(map[string]any)["content"].([]map[string]any)[0]
}

func swapLegacyStatus(t *testing.T, records []map[string]any, key, value string) {
	t.Helper()
	part := legacyTestBlock(records[2])["content"].([]map[string]any)[0]
	var status map[string]string
	if err := json.Unmarshal([]byte(part["text"].(string)), &status); err != nil {
		t.Fatal(err)
	}
	status[key] = value
	data, err := json.Marshal(status)
	if err != nil {
		t.Fatal(err)
	}
	part["text"] = string(data)
}

func writeLegacyTestJournal(t *testing.T, profile, cwd, session string, records []map[string]any) string {
	t.Helper()
	var body strings.Builder
	for _, record := range records {
		if err := json.NewEncoder(&body).Encode(record); err != nil {
			t.Fatal(err)
		}
	}
	path := filepath.Join(profile, "projects", claudeProjectSeparator.ReplaceAllString(cwd, "-"), session+".jsonl")
	writeVendorJournal(t, path, body.String())
	return path
}

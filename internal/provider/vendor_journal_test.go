package provider

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	model "agent-acp.local/sdks/go/model"
	"google.golang.org/protobuf/encoding/protojson"

	"agentcommander/internal/service"
)

const (
	journalFirst = "01999754-ffff-7000-8080-aabbccddeeff"
	journalOther = "01999754-ffff-7000-8080-aabbccddef00"
)

func TestVendorJournalSupplementPreservesScopedSource(t *testing.T) {
	for _, name := range []string{"claude", "codex"} {
		t.Run(name, func(t *testing.T) {
			profile, checkout := t.TempDir(), t.TempDir()
			cwd, err := filepath.EvalSymlinks(checkout)
			if err != nil {
				t.Fatal(err)
			}
			ref := service.NativeSession{HarnessInstance: "local-" + name, SessionID: journalFirst}
			other := service.NativeSession{HarnessInstance: ref.HarnessInstance, SessionID: journalOther}
			var journal, second, body string
			switch name {
			case "claude":
				t.Setenv("CLAUDE_CONFIG_DIR", profile)
				file := filepath.Join(profile, "projects", claudeProjectSeparator.ReplaceAllString(cwd, "-"))
				journal, second = filepath.Join(file, journalFirst+".jsonl"), filepath.Join(file, journalOther+".jsonl")
				fixture := journalFixture(t, "claude-journal.jsonl")
				var identified []string
				for _, line := range strings.Split(strings.TrimSpace(fixture), "\n") {
					var row map[string]json.RawMessage
					if err := json.Unmarshal([]byte(line), &row); err != nil {
						t.Fatal(err)
					}
					row["cwd"], _ = json.Marshal(cwd)
					row["sessionId"], _ = json.Marshal(ref.SessionID)
					row["version"] = json.RawMessage(`"2.1.330"`)
					encoded, _ := json.Marshal(row)
					identified = append(identified, string(encoded))
				}
				body = strings.Join(identified, "\n") + "\n"
				body += strings.Replace(identified[0], ref.SessionID, other.SessionID, 1) + "\n"
				body += strings.Replace(identified[1], "2.1.330", "99.9.9", 1) + "\n"
				writeVendorJournal(t, second, strings.Replace(identified[0], ref.SessionID, other.SessionID, 1)+"\n")
			case "codex":
				t.Setenv("CODEX_HOME", profile)
				journal = filepath.Join(profile, "sessions", "2026", "11", "23", "rollout-2026-11-23T00-00-00-"+journalFirst+".jsonl")
				second = filepath.Join(profile, "archived_sessions", "rollout-2026-11-21T00-00-00-"+journalOther+".jsonl")
				body = codexJournalHeader(ref.SessionID, cwd, "0.171.0") +
					journalFixture(t, "codex-rollout.jsonl") + "{\"type\":\"new_format\"}\n"
				writeVendorJournal(t, second, codexJournalHeader(other.SessionID, cwd, "0.171.0"))
			}
			writeVendorJournal(t, journal, body)
			local := &Local{}
			first := loadJournalPage(t, local, ref, checkout, "", 1)
			if len(first.GetObservations()) != 1 || first.GetNextCursor() == "" {
				t.Fatalf("expected a paged source event, got %v", first)
			}
			if _, err := local.ReadNativeJournalPage(t.Context(), other, checkout, first.GetNextCursor(), 1); err == nil {
				t.Fatal("cursor from a different worker was accepted")
			}
			var combined strings.Builder
			cursor := first.GetNextCursor()
			for count := 0; cursor != ""; count++ {
				if count == 12 {
					t.Fatal("source reader did not advance")
				}
				page := loadJournalPage(t, local, ref, checkout, cursor, 1)
				for _, event := range page.GetObservations() {
					if event.GetSession().GetSessionId() != ref.SessionID {
						t.Fatal("journal observation escaped its session")
					}
					combined.Write(event.GetExtension().GetData())
					combined.WriteString(event.GetGap().GetReason())
				}
				cursor = page.GetNextCursor()
			}
			data := combined.String()
			if !strings.Contains(data, "read-1") || !strings.Contains(data, "AAE=") ||
				strings.Contains(data, other.SessionID) {
				t.Fatalf("scoped tool references or image source missing: %s", data)
			}
			if name == "claude" {
				if !strings.Contains(data, "Provider result summary") || !strings.Contains(data, "fixture-resource") ||
					!strings.Contains(data, "outside the bound conversation") || !strings.Contains(data, "version has no verified reader") {
					t.Fatalf("source details or explicit gaps missing: %s", data)
				}
			} else {
				writeVendorJournal(t, second, codexJournalHeader(other.SessionID, cwd, "9.9.9"))
				if !strings.Contains(data, "opaque-fixture") || !strings.Contains(data, "unrecognized record") ||
					!strings.Contains(loadJournalPage(t, local, other, checkout, "", 8).Observations[0].GetGap().GetReason(), "no verified reader") {
					t.Fatalf("Codex source details or gaps missing: %s", data)
				}
				wrongCwd := t.TempDir()
				if _, err := local.ReadNativeJournalPage(t.Context(), ref, wrongCwd, "", 1); err == nil {
					t.Fatal("accepted a Codex journal in the wrong checkout")
				}
			}
			raw, err := os.ReadFile(journal)
			if err != nil || !bytes.Equal(raw, []byte(body)) {
				t.Fatal("journal read mutated the source")
			}
		})
	}
}

func TestVendorJournalRejectsSymlinkAndReplacedSource(t *testing.T) {
	profile, checkout := t.TempDir(), t.TempDir()
	cwd, err := filepath.EvalSymlinks(checkout)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("CODEX_HOME", profile)
	local := &Local{}
	ref := service.NativeSession{HarnessInstance: "local-codex", SessionID: journalFirst}
	path := filepath.Join(profile, "sessions", "2026", "11", "23", "rollout-2026-11-23T00-00-00-"+journalFirst+".jsonl")
	body := codexJournalHeader(ref.SessionID, cwd, "0.169.1") + journalFixture(t, "codex-rollout.jsonl")
	writeVendorJournal(t, path, body)
	cursor := loadJournalPage(t, local, ref, checkout, "", 1).GetNextCursor()
	original := filepath.Join(t.TempDir(), "original.jsonl")
	if err := os.Rename(path, original); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(original, path); err != nil {
		t.Fatal(err)
	}
	if page := loadJournalPage(t, local, ref, checkout, "", 1); len(page.Observations) != 1 || page.Observations[0].GetGap() == nil {
		t.Fatal("symlinked journal was read")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	writeVendorJournal(t, path, body)
	if _, err := local.ReadNativeJournalPage(t.Context(), ref, checkout, cursor, 1); err == nil {
		t.Fatal("accepted a previous cursor against a replaced journal")
	}
}

func codexJournalHeader(id, cwd, version string) string {
	row, _ := json.Marshal(map[string]any{
		"type": "session_meta", "payload": map[string]string{"id": id, "cwd": cwd, "cli_version": version},
	})
	return string(row) + "\n"
}

func writeVendorJournal(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
}

func journalFixture(t *testing.T, name string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "design", "verification", "transcript-coverage", name))
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(data)) + "\n"
}

func loadJournalPage(t *testing.T, l *Local, ref service.NativeSession, cwd, cursor string, limit uint32) *model.ReadHistoryResponse {
	t.Helper()
	raw, err := l.ReadNativeJournalPage(t.Context(), ref, cwd, cursor, limit)
	if err != nil {
		t.Fatal(err)
	}
	var page model.ReadHistoryResponse
	if err := protojson.Unmarshal(raw, &page); err != nil {
		t.Fatal(fmt.Errorf("decode journal observations: %w", err))
	}
	return &page
}

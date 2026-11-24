package provider

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	model "agent-acp.local/sdks/go/model"
	"agentcommander/internal/service"
	"google.golang.org/protobuf/encoding/protojson"
)

const (
	piFirst  = "00000000-1111-2222-3333-444444444444"
	piSecond = "55555555-1111-2222-3333-444444444444"
)

func TestPiHistoryReaderScopesAndPagesNativeRecords(t *testing.T) {
	local, workspace, source := piHistoryFixture(t)
	early := `{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"same words"},` +
		`{"type":"toolCall","id":"call-1","name":"read","arguments":{"file":"fixture"}},` +
		`{"type":"image","source":{"url":"fixture://image"}}],"future":{"complete":"field"}}}`
	result := `{"type":"message","message":{"role":"toolResult","toolName":"read","toolCallId":"call-1",` +
		`"isError":true,"content":[{"type":"text","text":"The read failed."},{"type":"image","data":"AA=="}]}}`
	writePiJournal(t, source, workspace, piFirst, piFirst, 3, early+"\n"+result+"\n")
	writePiJournal(t, source, workspace, piSecond, piSecond, 3,
		`{"type":"message","message":{"role":"user","content":[{"type":"text","text":"other worker"}]}}`+"\n")
	ref := service.NativeSession{HarnessInstance: local.acpProfiles["pi"].instance("pi"), SessionID: piFirst}
	cursor := ""
	var all []*model.Observation
	for pageNumber := range 8 {
		page := piPage(t, local, workspace, ref, cursor, 1)
		if len(page.Observations) != 1 {
			t.Fatalf("page %d has %d observations", pageNumber, len(page.Observations))
		}
		item := page.Observations[0]
		if item.GetSession().GetSessionId() != piFirst || item.GetCursor() == "" {
			t.Fatalf("bad observation identity: %v", item)
		}
		all = append(all, item)
		if pageNumber == 0 {
			other := service.NativeSession{HarnessInstance: ref.HarnessInstance, SessionID: piSecond}
			if _, err := local.ReadNativeHistoryPage(t.Context(), other, workspace, page.NextCursor, 1); err == nil {
				t.Fatal("accepted a cursor from another session in the same directory")
			}
		}
		cursor = page.NextCursor
		if cursor == "" {
			break
		}
	}
	if len(all) != 6 || cursor != "" || all[1].GetText().GetText() != "same words" ||
		all[2].GetTool().GetCallId() != "call-1" || strings.TrimSpace(string(all[3].GetExtension().GetData())) != early ||
		all[4].GetTool().GetPhase() != "failed" || !strings.Contains(all[4].GetTool().GetSummary(), "The read failed.") ||
		strings.TrimSpace(string(all[5].GetExtension().GetData())) != result {
		t.Fatalf("unexpected Pi history: %v", all)
	}
	console, err := local.ReadConsoleHistory(t.Context(), ref, workspace)
	if err != nil {
		t.Fatal(err)
	}
	if len(console) != 6 || console[4].Kind != "tool_result" || console[4].ToolID != "call-1" ||
		console[4].ACP == nil || console[4].ACP.Source != "provider" || console[4].ACP.Cursor != all[5].Cursor ||
		console[5].ACP == nil || console[5].ACP.Cursor != all[5].Cursor ||
		strings.Contains(console[5].Text, "AA==") || !strings.Contains(console[5].Text, "The read failed.") {
		t.Fatalf("console lost the tool result or retained source: %+v", console)
	}
	exact, err := local.ReadNativeHistoryRecord(t.Context(), ref, workspace, console[5].ACP.PageCursor, console[5].ACP.Cursor)
	var selected model.ReadHistoryResponse
	if err != nil || protojson.Unmarshal(exact, &selected) != nil || len(selected.Observations) != 1 ||
		strings.TrimSpace(string(selected.Observations[0].GetExtension().GetData())) != result {
		t.Fatal("the retained Pi row did not resolve to its original tool result and image")
	}
	if err := os.Remove(workspace); err != nil {
		t.Fatal(err)
	}
	archived := piPage(t, local, workspace, ref, "", 16)
	if len(archived.Observations) != len(all) {
		t.Fatal("removing the original checkout hid the archived journal")
	}
	profile := local.acpProfiles["pi"]
	profile.History = &acpHistory{Format: "pi-jsonl-v3", Directory: t.TempDir()}
	local.acpProfiles["pi"] = profile
	if _, err := local.ReadNativeHistoryPage(t.Context(), ref, workspace, "", 1); err == nil {
		t.Fatal("a changed profile retargeted existing history")
	}
}

func TestPiHistoryReportsUnknownFormatsAndChecksStoredIdentity(t *testing.T) {
	local, workspace, source := piHistoryFixture(t)
	ref := service.NativeSession{HarnessInstance: local.acpProfiles["pi"].instance("pi"), SessionID: piFirst}
	writePiJournal(t, source, workspace, piFirst, piSecond, 3, "")
	if _, err := local.ReadNativeHistoryPage(t.Context(), ref, workspace, "", 1); err == nil {
		t.Fatal("accepted a transcript whose header identified another session")
	}
	writePiJournal(t, source, workspace, piFirst, piFirst, 999, `{"type":"message"}`+"\n")
	page := piPage(t, local, workspace, ref, "", 4)
	if len(page.Observations) != 1 || !strings.Contains(page.Observations[0].GetGap().GetReason(), "999") ||
		page.GetNextCursor() != "" {
		t.Fatalf("unknown version was not marked as a history gap: %v", page)
	}
	writePiJournal(t, source, workspace, piFirst, piFirst, 3, strings.Repeat("x", maxJournalRecord)+"\n"+`{"type":`)
	page = piPage(t, local, workspace, ref, "", 4)
	if len(page.Observations) != 3 || page.Observations[1].GetGap() == nil ||
		!strings.Contains(page.Observations[2].GetGap().GetReason(), "partial") || page.GetNextCursor() != "" {
		t.Fatalf("missing gap or cursor for the damaged native journal: %v", page)
	}
}

func TestPiHistoryRetainsLargeAttachmentOutsideConsolePreview(t *testing.T) {
	local, workspace, source := piHistoryFixture(t)
	ref := service.NativeSession{HarnessInstance: local.acpProfiles["pi"].instance("pi"), SessionID: piFirst}
	data := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("attachment fixture", 2000)))
	record := fmt.Sprintf(`{"type":"message","message":{"role":"toolResult","toolName":"image","toolCallId":"image-1","content":[{"type":"image","mimeType":"image/png","data":%q}]}}`, data)
	writePiJournal(t, source, workspace, piFirst, piFirst, 3, record+"\n")
	preview, err := local.ReadConsoleHistory(t.Context(), ref, workspace)
	if err != nil {
		t.Fatal(err)
	}
	var notice bool
	for _, event := range preview {
		if strings.Contains(event.Text, data[:32]) {
			t.Fatal("console preview included attachment bytes")
		}
		notice = notice || strings.Contains(event.Text, "Large provider payload omitted from console preview")
	}
	if !notice {
		t.Fatal("console preview did not mark the large provider event")
	}
	page := piPage(t, local, workspace, ref, "", 16)
	for _, obs := range page.GetObservations() {
		if strings.TrimSpace(string(obs.GetExtension().GetData())) == record {
			return
		}
	}
	t.Fatal("native history did not retain the complete attachment record")
}

func piHistoryFixture(t *testing.T) (*Local, string, string) {
	t.Helper()
	workspace, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	data, err := json.Marshal(map[string]acpProfile{"pi": {
		Command: "/bin/echo", History: &acpHistory{Format: "pi-jsonl-v3", Directory: directory},
	}})
	if err != nil {
		t.Fatal(err)
	}
	profileDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(profileDir, "acp-profiles.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	profiles, err := loadACPProfiles(profileDir)
	if err != nil {
		t.Fatal(err)
	}
	return &Local{acpProfiles: profiles}, workspace, directory
}

func writePiJournal(t *testing.T, directory, cwd, filenameID, headerID string, version int, body string) {
	t.Helper()
	project := filepath.Join(directory, "--"+strings.ReplaceAll(strings.TrimPrefix(cwd, "/"), "/", "-")+"--")
	if err := os.MkdirAll(project, 0700); err != nil {
		t.Fatal(err)
	}
	header := fmt.Sprintf(`{"type":"session","version":%d,"id":%q,"cwd":%q}`+"\n", version, headerID, cwd)
	if err := os.WriteFile(filepath.Join(project, "fixture_"+filenameID+".jsonl"), []byte(header+body), 0600); err != nil {
		t.Fatal(err)
	}
}

func piPage(t *testing.T, local *Local, workspace string, ref service.NativeSession, cursor string, limit uint32) *model.ReadHistoryResponse {
	t.Helper()
	raw, err := local.ReadNativeHistoryPage(context.Background(), ref, workspace, cursor, limit)
	if err != nil {
		t.Fatal(err)
	}
	var page model.ReadHistoryResponse
	if err := protojson.Unmarshal(raw, &page); err != nil {
		t.Fatal(err)
	}
	return &page
}

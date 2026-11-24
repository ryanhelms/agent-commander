package provider

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	model "agent-acp.local/sdks/go/model"
	"agentcommander/internal/service"
	"google.golang.org/protobuf/encoding/protojson"
)

func TestCancelledReplayWaitPreservesTheActiveReadersSlot(t *testing.T) {
	profile := acpProfile{Command: "/fixture/adapter", History: &acpHistory{Format: acpReplayHistory}}
	ref := service.NativeSession{HarnessInstance: profile.instance("test"), SessionID: "retained"}
	local := &Local{acpProfiles: map[string]acpProfile{"test": profile}, replaySlot: make(chan struct{}, 1)}
	local.replaySlot <- struct{}{}
	for _, preview := range []bool{false, true} {
		ctx, cancel := context.WithTimeout(t.Context(), 10*time.Millisecond)
		var err error
		if preview {
			_, err = local.ReadConsoleHistory(ctx, ref, t.TempDir())
		} else {
			_, err = local.ReadNativeHistoryPage(ctx, ref, t.TempDir(), "", 1)
		}
		cancel()
		if !errors.Is(err, context.DeadlineExceeded) || len(local.replaySlot) != 1 {
			t.Fatalf("cancelled reader affected the active replay: %v", err)
		}
	}
}

func TestCodexThreadDetailsStayInSelectedProviderSource(t *testing.T) {
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("Codex app-server fixture requires Node")
	}
	dir := t.TempDir()
	bin := filepath.Join(dir, "codex")
	const peer = `#!/usr/bin/env node
require("node:readline").createInterface({input:process.stdin}).on("line", line => {
  const {id,method,params} = JSON.parse(line);
  if (method === "initialized") return;
  let result = {};
  if (method === "thread/read") {
    if (params.includeTurns !== false) process.exit(2);
    result = {thread:{id:params.threadId,cwd:"/private/selected-thread"},extra:{retained:null}};
  }
  if (method === "thread/turns/list") result = {data:[]};
  process.stdout.write(JSON.stringify({id,result})+"\n");
});
`
	if err := os.WriteFile(bin, []byte(peer), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CODEX_PATH", bin)
	local := &Local{}
	ref := service.NativeSession{HarnessInstance: "local-codex", SessionID: "fixture"}
	events, err := local.ReadConsoleHistory(t.Context(), ref, dir)
	if err != nil || len(events) != 1 {
		t.Fatalf("missing thread details row: %d events, err %v", len(events), err)
	}
	event := events[0]
	if event.Text != "Codex thread details" || event.ACP == nil || event.ACP.Source != "provider" || event.ACP.Cursor == "" {
		t.Fatalf("thread details preview has no scoped source link: %+v", event)
	}
	raw, err := local.ReadNativeHistoryPage(t.Context(), ref, dir, "", 1)
	if err != nil {
		t.Fatal(err)
	}
	var page model.ReadHistoryResponse
	if err := protojson.Unmarshal(raw, &page); err != nil || len(page.Observations) != 1 {
		t.Fatalf("unreadable source page: %v", err)
	}
	record := page.Observations[0]
	source := record.GetExtension()
	if record.Cursor != event.ACP.Cursor || record.GetSession().GetSessionId() != ref.SessionID ||
		source.GetType() != "codex.history.thread" || !strings.Contains(string(source.Data), "/private/selected-thread") ||
		!strings.Contains(string(source.Data), `"retained":null`) {
		t.Fatal("the selected thread original lost its properties or its preview identity")
	}
	selected, err := local.ReadNativeHistoryRecord(t.Context(), ref, dir, "", event.ACP.Cursor)
	if err != nil || string(selected) != string(raw) {
		t.Fatal("exact lookup lost the original observation")
	}
}

func TestSelectHistoryRecordDoesNotSubstituteAnotherRecord(t *testing.T) {
	native := service.NativeSession{HarnessInstance: "profile", SessionID: "local"}
	record := func(session, cursor string) *model.Observation {
		return &model.Observation{
			Session: &model.SessionRef{HarnessInstance: "profile", SessionId: session},
			Cursor:  cursor, Event: &model.Observation_Text{Text: &model.TextUpdate{Text: session}},
		}
	}
	wanted, neighbor, foreign := record("local", "target"), record("local", "other"), record("foreign", "target")
	page := &model.ReadHistoryResponse{Observations: []*model.Observation{foreign, neighbor, wanted}, NextCursor: "next"}
	exact := selectHistoryRecord(page, native, "target")
	if len(exact.Observations) != 1 || exact.Observations[0] != wanted || exact.NextCursor != "" {
		t.Fatal("lookup did not isolate the selected original")
	}
	for _, rows := range [][]*model.Observation{{}, {foreign, neighbor}, {wanted, wanted}} {
		selected := selectHistoryRecord(&model.ReadHistoryResponse{Observations: rows}, native, "target")
		if len(selected.Observations) != 1 || selected.Observations[0].GetGap() == nil ||
			selected.Observations[0].GetSession().GetSessionId() != native.SessionID || selected.NextCursor != "" {
			t.Fatal("absent or ambiguous identity failed to produce a scoped gap")
		}
	}
}

func TestNativeHistoryPageKeepsProviderExtensions(t *testing.T) {
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("Claude history adapter requires Node")
	}
	dir := t.TempDir()
	t.Setenv("AGENT_ACP_HARNESS_DIR", dir)
	sdk := filepath.Join(dir, "node_modules", "@anthropic-ai", "claude-agent-sdk")
	if err := os.MkdirAll(sdk, 0700); err != nil {
		t.Fatal(err)
	}
	for name, value := range map[string]string{
		"package.json": `{"type":"module","exports":"./sdk.mjs"}`,
		"sdk.mjs": `export async function getSessionMessages(id, options) {
			if (id !== "fixture") throw Error("wrong session");
			return [{type:"assistant",uuid:"native-envelope",futureMessage:{ordinal:"9007199254740993"},message:{content:[
				{type:"text",text:"first"},
				{type:"future_attachment",payload:{title:"complete payload"}}
			]}}].slice(options.offset, options.offset + options.limit);
		}`,
	} {
		if err := os.WriteFile(filepath.Join(sdk, name), []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
	}
	local := &Local{}
	ref := service.NativeSession{HarnessInstance: "local-claude", SessionID: "fixture"}
	cursor := ""
	var sourceCursor string
	for i := 0; i < 2; i++ {
		raw, err := local.ReadNativeHistoryPage(context.Background(), ref, dir, cursor, 1)
		if err != nil {
			t.Fatal(err)
		}
		var page model.ReadHistoryResponse
		if err := protojson.Unmarshal(raw, &page); err != nil {
			t.Fatal(err)
		}
		if len(page.Observations) != 1 {
			t.Fatalf("expected one observation: %s", raw)
		}
		observation := page.Observations[0]
		if i == 0 {
			sourceCursor = observation.GetSourceCursor()
			body := string(observation.GetSourceRecord().GetData())
			if sourceCursor == "" || sourceCursor != observation.Cursor || !strings.Contains(body, "native-envelope") || !strings.Contains(body, "9007199254740993") {
				t.Fatalf("provider envelope lost its identity or original fields: %s", body)
			}
		} else if observation.GetSourceCursor() != sourceCursor || observation.GetSourceRecord() != nil {
			t.Fatal("the next page must reference the original envelope once")
		}
		if i == 0 && (observation.GetText().GetText() != "first" || page.NextCursor == "") {
			t.Fatalf("missing first item or cursor: %s", raw)
		}
		if i == 1 && (!strings.Contains(string(observation.GetExtension().GetData()), "complete payload") || page.NextCursor != "") {
			t.Fatalf("missing attachment extension or unexpected cursor: %s", raw)
		}
		cursor = page.NextCursor
	}
	preview, err := local.ReadConsoleHistory(context.Background(), ref, dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(preview) != 2 || preview[1].Kind != "output" || !strings.Contains(preview[1].Text, "complete payload") {
		t.Fatalf("provider extension missing from the console preview: %+v", preview)
	}
	for _, event := range preview {
		if event.ACP == nil || event.ACP.Source != "provider" || event.ACP.Cursor != sourceCursor {
			t.Fatal("a restored row cannot open its provider envelope")
		}
	}
}

func TestProviderStderrKeepsPartialLine(t *testing.T) {
	s := &screen{}
	writer := &lineWriter{s: s}
	_, _ = writer.Write([]byte("first\npar"))
	_, _ = writer.Write([]byte("tial"))
	writer.flush()
	writer.flush()
	if len(s.events) != 2 || s.events[0].Kind != "output" ||
		s.events[0].Text != "[Provider stderr] first" || s.events[1].Text != "[Provider stderr] partial" {
		t.Fatalf("unexpected stderr projection: %+v", s.events)
	}
}

func TestRetainedCodexItemProjectsOnlyAnIdentifiedInvocation(t *testing.T) {
	for _, tc := range []struct {
		record, arguments, output string
		hasCall                   bool
	}{
		{`{"type":"mcpToolCall","id":"call","arguments":{"folder":"docs"},"result":{"text":"receipt"},"error":null}`, `{"folder":"docs"}`, `{"text":"receipt"}`, true},
		{`{"type":"commandExecution","id":"call","command":"pwd","aggregatedOutput":"/workspace"}`, "pwd", "/workspace", true},
		{`{"type":"functionCallOutput","id":"call","output":"done"}`, "", "summary", false},
		{`{"type":"mcpToolCall","id":"another","arguments":{},"result":{}}`, "", "summary", false},
	} {
		obs := &model.Observation{SourceRecord: &model.Extension{Type: "codex.history.item", Data: []byte(tc.record)}}
		result := service.ConsoleEvent{Kind: "tool_result", Phase: "completed", ToolID: "call", Name: "tool", Text: "summary"}
		call, ok := retainedCodexCall(obs, &result)
		if ok != tc.hasCall || call.Text != tc.arguments || result.Text != tc.output || ok && call.ToolID != result.ToolID {
			t.Errorf("incorrect call/result for %s: %+v / %+v", tc.record, call, result)
		}
	}
}

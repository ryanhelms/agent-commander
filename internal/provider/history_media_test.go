package provider

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	model "agent-acp.local/sdks/go/model"
	"agentcommander/internal/service"
	"google.golang.org/protobuf/encoding/protojson"
)

func TestRetainedPromptAttachmentsResolveExactOriginalAcrossPages(t *testing.T) {
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("fixture SDK requires Node")
	}
	for _, provider := range []string{"claude", "codex"} {
		t.Run(provider, func(t *testing.T) {
			dir := t.TempDir()
			const onlyFirst = "aW1hZ2VfYWxwaGE="
			const onlySecond = "aW1hZ2VfYmV0YQ=="
			// Two prompts deliberately share a turn; the original cursor is their identity.
			image := func(kind, mime, data string) map[string]any {
				if provider == "claude" {
					return map[string]any{"type": kind, "source": map[string]string{"type": "base64", "media_type": mime, "data": data}}
				}
				return map[string]any{"type": kind, "url": "data:" + mime + ";base64," + data}
			}
			first := []any{image("image", "image/png", onlyFirst), map[string]string{"type": "text", "text": "  Original $text.\n", "Text": "PRIVATE-TEXT-ALIAS"}, image("image", "image/png", onlyFirst)}
			for i := 0; i < providerProjectionPageSize; i++ {
				first = append(first, map[string]string{"type": "text", "text": "x"})
			}
			first = append(first, image("audio", "audio/wav", "U09VTkQ="))
			prompts := [][]any{first, {image("image", "image/png", onlySecond)}}
			var records []any
			for i, content := range prompts {
				if provider == "claude" {
					records = append(records, map[string]any{"type": "user", "uuid": []string{"a", "b"}[i], "message": map[string]any{"content": content}, "private": nil})
				} else {
					records = append(records, map[string]any{"type": "userMessage", "id": []string{"a", "b"}[i], "content": content, "private": nil})
				}
			}
			raw, _ := json.Marshal(records)
			file := filepath.Join(dir, "records.json")
			if err := os.WriteFile(file, raw, 0600); err != nil {
				t.Fatal(err)
			}
			t.Setenv("TEST_PROMPTS", file)
			if provider == "claude" {
				t.Setenv("AGENT_ACP_HARNESS_DIR", dir)
				sdk := filepath.Join(dir, "node_modules", "@anthropic-ai", "claude-agent-sdk")
				if err := os.MkdirAll(sdk, 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(sdk, "package.json"), []byte(`{"type":"module","exports":"./sdk.mjs"}`), 0600); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(sdk, "sdk.mjs"), []byte(`import fs from "node:fs"; export async function getSessionMessages(id,opts) { if(id!=="selected") throw Error("wrong session");return JSON.parse(fs.readFileSync(process.env.TEST_PROMPTS)).slice(opts.offset,opts.offset+opts.limit); }`), 0600); err != nil {
					t.Fatal(err)
				}
			} else {
				bin := filepath.Join(dir, "codex")
				t.Setenv("CODEX_PATH", bin)
				if err := os.WriteFile(bin, []byte(`#!/usr/bin/env node
const fs=require("node:fs");
require("node:readline").createInterface({input:process.stdin}).on("line",line=>{
const {id,method,params}=JSON.parse(line); let result;
switch(method){
case "initialize": result={}; break;
case "initialized": return;
case "thread/read": if(params.threadId!=="selected" || params.includeTurns!==false)process.exit(2); result={thread:{id:params.threadId}}; break;
case "thread/turns/list": result={data:[{id:"one-turn",status:"completed",itemsView:"full",items:JSON.parse(fs.readFileSync(process.env.TEST_PROMPTS))}]}; break;
default: process.exit(3);
}
process.stdout.write(JSON.stringify({id,result})+"\n");
});
`), 0700); err != nil {
					t.Fatal(err)
				}
			}
			native := service.NativeSession{HarnessInstance: "local-" + provider, SessionID: "selected"}
			local := &Local{}
			events, err := local.ReadConsoleHistory(t.Context(), native, dir)
			if err != nil {
				t.Fatal(err)
			}
			var users []service.ConsoleEvent
			for _, e := range events {
				if e.Kind == "user" {
					users = append(users, e)
				}
				if strings.Contains(e.Text, onlyFirst) || strings.Contains(e.Text, onlySecond) || strings.Contains(e.Text, "U09VTkQ=") || strings.Contains(e.Text, "PRIVATE-TEXT-ALIAS") {
					t.Fatal("workspace preview contains original media or private sibling")
				}
				if e.Kind == "output" && strings.Contains(e.Text, "Attachment") {
					t.Fatal("duplicate media preview on a later SDK page")
				}
			}
			if len(users) != 2 || users[0].Text != "  Original $text.\n"+strings.Repeat("x", providerProjectionPageSize) || users[1].Text != "[Attachment]" {
				t.Fatalf("incorrect user rows: %+v", users)
			}
			for i, user := range users {
				a := user.ACP
				if a == nil || a.Source != "provider" || a.Kind != "provider_prompt_media" || a.Cursor == "" || a.ItemCount == nil || !a.Valid() {
					t.Fatalf("invalid descriptor: %+v", a)
				}
				if i == 0 && (*a.ItemCount != 3 || a.ContentType != "mixed" || a.MIMEType != "" || a.PageCursor != "") {
					t.Fatalf("incorrect first descriptor: %+v", a)
				}
				if i == 1 && (*a.ItemCount != 1 || a.ContentType != "image" || a.MIMEType != "image/png" || a.PageCursor == "" || a.Cursor == users[0].ACP.Cursor || a.TurnID != users[0].ACP.TurnID) {
					t.Fatalf("incorrect second descriptor: %+v", a)
				}
				selected, err := local.ReadNativeHistoryRecord(t.Context(), native, dir, a.PageCursor, a.Cursor)
				if err != nil {
					t.Fatal(err)
				}
				var page model.ReadHistoryResponse
				if err := protojson.Unmarshal(selected, &page); err != nil || len(page.Observations) != 1 {
					t.Fatalf("bad exact response: %v", err)
				}
				owner := page.Observations[0]
				body := string(owner.GetSourceRecord().GetData())
				if owner.Cursor != a.Cursor || owner.GetSourceCursor() != a.Cursor || owner.Session.GetSessionId() != native.SessionID || !strings.Contains(body, `"private":null`) {
					t.Fatal("exact lookup lost the selected original")
				}
				if i == 0 && (strings.Count(body, onlyFirst) != 2 || strings.Contains(body, onlySecond) || !strings.Contains(body, "U09VTkQ=")) {
					t.Fatal("first record lost the repeated image or audio")
				}
				if i == 1 && (!strings.Contains(body, onlySecond) || strings.Contains(body, onlyFirst)) {
					t.Fatal("second record returned another prompt")
				}
			}
		})
	}
}

func TestHistoricalToolAndOpaqueMediaStayInProviderSource(t *testing.T) {
	const fixtureData = "opaque-test-media-content"
	for _, raw := range []string{
		`[{"type":"text","text":"also retained"},{"type":"image","source":{"type":"base64","data":"` + fixtureData + `"}}]`,
		`{"content":[{"type":"image","mimeType":"image/png","data":"` + fixtureData + `"}]}`,
		`{"result":{"futureProviderFormat":{"blob":"` + fixtureData + `"}}}`,
		`{"type":"FutureImage","source":{"data":"` + fixtureData + `","title":"visible"}}`,
		`{"payload":{"url":"data:image/png;base64,` + fixtureData + `"}}`,
	} {
		for _, phase := range []string{"completed", "failed"} {
			got := retainedToolEvent(&model.ToolActivity{CallId: "read", Phase: phase, Summary: raw})
			if strings.Contains(got.Text, fixtureData) || !strings.Contains(got.Text, "Attachment") || got.ToolID != "read" || got.Phase != phase || !strings.HasPrefix(got.Text, got.ToolFailure()) {
				t.Fatal("unsafe tool preview", phase, got.Text)
			}
		}
		o := &model.Observation{Event: &model.Observation_Extension{Extension: &model.Extension{Type: "claude.unknown", MediaType: "application/json", Data: []byte(raw)}}}
		if e := acpExtensionEvent(o, "provider"); strings.Contains(e.Text, fixtureData) || !strings.Contains(e.Text, "Attachment") {
			t.Fatal("opaque record leaked attachment bytes")
		}
	}
}

func TestRetainedMixedToolResultKeepsBoundedTextAndFailure(t *testing.T) {
	for _, size := range []int{12, 2 * maxConsoleEventBytes} {
		payload := strings.Repeat("A", size)
		raw := `[{"type":"text","text":"Beginning."},{"type":"image","data":"` + payload + `","mimeType":"image/png"},{"type":"text","text":"Ending."}]`
		e := retainedToolEvent(&model.ToolActivity{CallId: "fixture", Phase: "failed", Summary: raw})
		if e.ToolFailure() == "" || !strings.HasPrefix(e.Text, "Tool failed.") || !strings.Contains(e.Text, "Beginning.") || !strings.Contains(e.Text, "Ending.") || strings.Contains(e.Text, payload) {
			t.Fatal("mixed failure lost text or emitted inline image", size)
		}
	}
	ordinary := `{"data":"plain customer text","rows":[{"data":"ordinary reply"}]}`
	if got := historyToolSummary(ordinary); got != ordinary {
		t.Fatal("ordinary text field was treated as media", got)
	}
}

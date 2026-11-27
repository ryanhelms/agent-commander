package provider

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"

	model "agent-acp.local/sdks/go/model"
	"google.golang.org/protobuf/encoding/protojson"

	"agentcommander/internal/localapi"
	"agentcommander/internal/service"
)

func TestRegisteredACPProfilesRejectInvalidConfiguration(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "acp-profiles.json")
	for _, raw := range []string{
		`{"codex":{"command":"/bin/echo"}}`,
		`{"test":{"command":"relative"}}`,
		`{"test":{"command":"/bin/echo","env":{}}}`,
		`{"test":{"command":"/bin/echo","history":{"format":"unknown","directory":"/tmp"}}}`,
		`{"test":{"command":"/bin/echo","history":{"format":"acp-v1-replay","directory":"/tmp"}}}`,
		`{"test":{"command":"/bin/echo","history":{"format":"pi-jsonl-v3","directory":"relative"}}}`,
		`{"test":{"command":"/bin/echo","args":["\u0000"]}}`,
		`{"test":{"command":"/bin/echo"}} null`,
	} {
		if err := os.WriteFile(path, []byte(raw), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := loadACPProfiles(dir); err == nil {
			t.Fatalf("accepted invalid profile: %s", raw)
		}
	}
}

func TestACPReplayProfileKeepsTheSelectedExecutableBinding(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "acp-profiles.json")
	if err := os.WriteFile(path, []byte(`{"stock":{"command":"/bin/echo","args":["acp"],"history":{"format":"acp-v1-replay"}}}`), 0600); err != nil {
		t.Fatal(err)
	}
	local, err := New(dir, filepath.Join(dir, "s.sock"), "/bin/echo")
	if err != nil {
		t.Fatal(err)
	}
	ref := service.NativeSession{HarnessInstance: local.acpProfiles["stock"].instance("stock"), SessionID: "saved"}
	if !local.RequiresStoppedHistory(ref) {
		t.Fatal("replay profile did not carry its stopped-session policy")
	}
	profile := local.acpProfiles["stock"]
	profile.Args = []string{"different"}
	local.acpProfiles["stock"] = profile
	if _, err := local.ReadNativeHistoryPage(t.Context(), ref, dir, "", 1); err == nil {
		t.Fatal("a changed launch profile could read an earlier adapter's session")
	}
}

func TestRegisteredACPProfileCanOmitCommanderMCP(t *testing.T) {
	dir := t.TempDir()
	profiles := `{"default":{"command":"/bin/echo"},"restricted":{"command":"/bin/echo","omit_commander_mcp":true}}`
	if err := os.WriteFile(filepath.Join(dir, "acp-profiles.json"), []byte(profiles), 0600); err != nil {
		t.Fatal(err)
	}
	loaded, err := loadACPProfiles(dir)
	if err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]int{"default": 1, "restricted": 0} {
		profile := loaded[name]
		config, err := planningConfig(job{RegisteredACP: &profile, Harness: name, Executable: "/fixture/agentctl"})
		if err != nil {
			t.Fatal(err)
		}
		if len(config.MCPServers) != want {
			t.Fatalf("profile %s offers %d MCP servers, want %d", name, len(config.MCPServers), want)
		}
	}
}

func TestHistoryDirectoryKeepsTheSameBindingWhenCreated(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(t.TempDir(), "agent-store")
	if err := os.Symlink(root, alias); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(alias, "pi", "sessions")
	before, err := resolveHistoryDirectory(path)
	if err != nil || before != filepath.Join(root, "pi", "sessions") {
		t.Fatalf("missing store resolved to %q: %v", before, err)
	}
	if err := os.MkdirAll(path, 0700); err != nil {
		t.Fatal(err)
	}
	if after, err := resolveHistoryDirectory(path); err != nil || after != before {
		t.Fatalf("new store changed its configured binding from %q to %q: %v", before, after, err)
	}
}

func TestRegisteredACPExecutableEndToEnd(t *testing.T) {
	if os.Getenv("AGENT_COMMANDER_TEST_TMUX") != "1" {
		t.Skip("set AGENT_COMMANDER_TEST_TMUX=1 for an isolated tmux session")
	}
	if _, err := executablePath("tmux", "AGENT_COMMANDER_TMUX"); err != nil {
		t.Skip(err)
	}
	node, err := executablePath("node", "AGENT_COMMANDER_NODE")
	if err != nil {
		t.Skip(err)
	}
	dir, err := os.MkdirTemp("/tmp", "ac-profile-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	t.Setenv("TMUX_TMPDIR", dir)
	scriptPath := filepath.Join(dir, "independent adapter.mjs")
	transcript, err := filepath.Abs("../../design/verification/transcript-coverage/acp-updates.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	script := `
import {readFileSync, writeFileSync} from 'node:fs';
import {createInterface} from 'node:readline';
if (process.argv[2] !== '$literal ; no shell') process.exit(2);
const updates = readFileSync(process.argv[3], 'utf8').trimEnd().split('\n').map(JSON.parse);
const emit = (message) => console.log(JSON.stringify({jsonrpc:'2.0', ...message}));
const result = (id, body) => emit({id,result:body});
let sessionId = 'independent-fixture-' + process.pid, resumed = false;
let prompt;
for await (const line of createInterface({input:process.stdin})) {
  const message = JSON.parse(line);
  switch (message.method) {
    case 'initialize':
      result(message.id, {protocolVersion:1,agentCapabilities:{promptCapabilities:{image:true,audio:true},sessionCapabilities:{list:{},resume:{}}}});
      break;
    case 'session/new':
      if (message.params.mcpServers[0]?.name !== 'commander') process.exit(3);
      result(message.id, {sessionId});
      break;
    case 'session/list':
      result(message.id, {sessions:[
        {sessionId:'foreign',cwd:'/another-project'},
        {sessionId:readFileSync('media-session','utf8'),cwd:message.params.cwd,title:'Media worker'}]});
      break;
    case 'session/resume':
      sessionId = readFileSync('media-session','utf8');
      if(message.params.sessionId !== sessionId) process.exit(6);
      resumed = true;
      result(message.id, {});
      break;
    case 'session/prompt': {
      const content = message.params.prompt;
      if (resumed) {
        if (content.length !== 1 || content[0].text !== 'first prompt after explicit reattach') process.exit(7);
        emit({method:'session/update',params:{sessionId,update:{
          sessionUpdate:'agent_message_chunk',content:{type:'text',text:'REATTACHED_ORIGINAL_SESSION'}}}});
        result(message.id,{stopReason:'end_turn'});
        break;
      }
      if (content[0].text === 'Start media worker.') {
        writeFileSync('media-session',sessionId,{mode:0o600});
        result(message.id,{stopReason:'end_turn'});
        break;
      }
      if (content[0].text.startsWith('ordered text')) {
        const expected = ['ordered text', '', ' ', '\n\tΩ', ' ordered text'];
        if (content.length !== expected.length || content.some((b,i) => b.type !== 'text' || b.text !== expected[i])) process.exit(5);
        emit({method:'session/update',params:{sessionId,update:{
          sessionUpdate:'agent_message_chunk',content:{type:'text',text:'TEXT_BLOCKS_VERIFIED'}}}});
        result(message.id,{stopReason:'end_turn'});
        break;
      }
      if (content[0].text === '  before\n') {
        const [before, image, empty, middle, repeat, audio, after] = content;
        if (content.length !== 7 || before.type !== 'text' ||
            image.type !== 'image' || image.mimeType !== 'image/png' || image.data !== 'AAH/' ||
            empty.type !== 'text' || empty.text !== '' || repeat.type !== 'text' || repeat.text !== middle.text ||
            middle.type !== 'text' || middle.text !== '\tbetween\n' ||
            audio.type !== 'audio' || audio.mimeType !== 'audio/wav' || audio.data !== 'AgM=' ||
            after.type !== 'text' || after.text !== 'after  ') process.exit(4);
        emit({method:'session/update',params:{sessionId,update:{
          sessionUpdate:'agent_message_chunk',content:{type:'text',text:'MIXED_PROMPT_VERIFIED'}}}});
        result(message.id,{stopReason:'end_turn'});
        break;
      }
      prompt = message;
      emit({id:'permission',method:'session/request_permission',params:{sessionId,
        toolCall:{toolCallId:'check',title:'Allow fixture check?',rawInput:{marker:'permission-source-only'}},
        options:[{optionId:'once',name:'Allow once',kind:'allow_once'},
          {optionId:'always',name:'Remember my answer',kind:'allow_always'}],
        _meta:{providerRevision:'permission-v3'}}});
      break;
    }
    default:
      if(message.id === 'permission' && message.result?.outcome?.optionId === 'once'){
        for (const update of updates) emit({method:'session/update',params:{sessionId,update}});
        emit({method:'session/update',params:{sessionId:'unrelated-session',update:{
          sessionUpdate:'tool_call_update',toolCallId:'read-1',rawOutput:{marker:'wrong-session-fixture'}}}});
        emit({method:'session/update',params:{sessionId,update:{
          sessionUpdate:'tool_call_update',toolCallId:'image-2',status:'completed',
          rawOutput:{marker:'source-only-fixture'},content:[{type:'content',content:{
            type:'image',mimeType:'image/png',data:'QVNDUkFX' + 'AAEA'.repeat(140000)}}]}}});
        emit({method:'session/update',params:{sessionId,update:{
          sessionUpdate:'agent_message_chunk',content:{type:'text',text:prompt.params.prompt[0].text}}}});
        result(prompt.id,{stopReason:'end_turn',_meta:{meter:'terminal-source-only'},usage:{inputTokens:37}});
      }
  }
}`
	profiles, err := json.Marshal(map[string]acpProfile{"fixture": {Command: node, Args: []string{scriptPath, "$literal ; no shell", transcript}}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(scriptPath, []byte(script), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "acp-profiles.json"), profiles, 0600); err != nil {
		t.Fatal(err)
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(dir, "api.sock")
	local, err := New(dir, socket, exe)
	if err != nil {
		t.Fatal(err)
	}
	if err := local.CheckAgentClient("fixture"); err == nil {
		t.Fatal("registered profile should require explicit owner selection")
	}
	handler, err := service.New(dir, local)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: handler}
	go server.Serve(listener)
	t.Cleanup(func() { _ = server.Close() })
	client := &api{localapi.New(socket, "")}
	var run service.Run
	const task = "Check literal $value and multi\nline."
	if err := client.request("POST", "/v1/runs", map[string]string{"path": dir, "task": task, "client": "fixture"}, &run); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = local.Stop(context.Background(), run.CoordinatorID) })
	replied := false
	for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); time.Sleep(40 * time.Millisecond) {
		if err := client.request("GET", "/v1/runs/"+run.ID, nil, &run); err != nil {
			t.Fatal(err)
		}
		worker := run.Workers[0]
		if worker.State == "failed" {
			t.Fatalf("registered ACP launch failed: %s\n%s", worker.Error, worker.Output)
		}
		if !replied && len(run.Requests) == 1 {
			if choices := run.Requests[0].Choices; len(choices) != 1 || choices[0].ID != "once" {
				t.Fatalf("wrong actionable permission choices: %+v", choices)
			}
			if got := run.Requests[0].ProviderToolCallID; got != "check" {
				t.Fatalf("wrong permission tool call: %q", got)
			}
			var mediaWorker service.Worker
			if err := client.request("POST", "/v1/runs/"+run.ID+"/workers", map[string]string{
				"name": "media", "task": "Start media worker.",
			}, &mediaWorker); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = local.Stop(context.Background(), mediaWorker.ID) })
			assertACPMediaPrompt(t, handler, client, mediaWorker.ID)
			assertACPTextPrompt(t, handler, client, mediaWorker.ID)
			assertACPReattachment(t, client, run.ID, mediaWorker.ID)
			if err := client.request("POST", "/v1/requests/"+run.Requests[0].ID+"/reply", map[string]string{"answer": "once"}, nil); err != nil {
				t.Fatal(err)
			}
			replied = true
		}
		if worker.State == "completed" {
			var assignments int
			for _, event := range worker.Console {
				if event.Kind == "user" && event.Text == worker.Task {
					assignments++
				}
			}
			if assignments != 1 {
				t.Fatalf("initial assignment appeared %d times as a conversation message", assignments)
			}
			if !replied || worker.NativeSession == nil || !strings.HasPrefix(worker.NativeSession.SessionID, "independent-fixture-") ||
				!slices.ContainsFunc(worker.Console, func(e service.ConsoleEvent) bool { return e.Kind == "text" && e.Text == task }) {
				t.Fatalf("managed session lost its reply, identity or literal output: %+v", worker)
			}
			for _, marker := range []string{"Read first chunk.", "Tool failed.", "fixture://plan", "[ACP image] image/png", "Typed MCP raw result marker.",
				"Direct MCP partial result.", "[ACP audio] audio/wav", "[Structured MCP result]", "MCP tool service disconnected.", "ACP partial result."} {
				if !strings.Contains(worker.Output, marker) {
					t.Fatalf("Console omitted live ACP marker %q", marker)
				}
			}
			for _, call := range []string{"mcp-failed", "mcp-protocol-failed"} {
				found := false
				for _, event := range worker.Console {
					found = found || event.ToolID == call && event.Kind == "tool_result" && event.Phase == "failed"
				}
				if !found {
					t.Fatalf("structured console lost the MCP failure status for %s", call)
				}
			}
			for _, event := range worker.Console {
				if event.Kind == "tool_result" && event.ToolID == "read-1" && event.Phase == "failed" &&
					strings.Contains(event.Text, "[ACP content: future_block]") {
					assertACPLiveSource(t, client, worker)
					return
				}
			}
			t.Fatal("structured console lost the failed result or its unfamiliar block")
		}
	}
	t.Fatalf("registered ACP conversation did not finish: %+v", run.Workers[0])
}

func assertACPMediaPrompt(t *testing.T, handler http.Handler, client *api, workerID string) {
	t.Helper()
	path := "/v1/ag-ui/workers/" + workerID
	var info struct {
		Status             string
		PromptCapabilities service.PromptCapabilities
	}
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(25 * time.Millisecond) {
		if err := client.request("GET", path, nil, &info); err != nil {
			t.Fatal(err)
		}
		if info.Status == "completed" || info.Status == "failed" {
			break
		}
	}
	if info.Status != "completed" || !info.PromptCapabilities.Image || !info.PromptCapabilities.Audio {
		t.Fatalf("ACP worker did not publish media support: %+v", info)
	}
	control := "/v1/workers/" + workerID + "/control"
	if err := client.request("POST", control, map[string]any{"held": true, "generation": 1}, nil); err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(map[string]any{
		"threadId": workerID, "runId": "media-fixture", "forwardedProps": map[string]int{"generation": 2},
		"messages": []any{map[string]any{"role": "user", "content": []any{
			map[string]string{"type": "text", "text": "  before\n"},
			map[string]any{"type": "image", "source": map[string]string{"type": "data", "mimeType": "image/png", "value": "AAH/"}},
			map[string]string{"type": "text", "text": ""},
			map[string]string{"type": "text", "text": "\tbetween\n"},
			map[string]string{"type": "text", "text": "\tbetween\n"},
			map[string]any{"type": "audio", "source": map[string]string{"type": "data", "mimeType": "audio/wav", "value": "AgM="}},
			map[string]string{"type": "text", "text": "after  "},
		}}},
	})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(handler)
	defer server.Close()
	httpClient := &http.Client{Timeout: 5 * time.Second}
	response, err := httpClient.Post(server.URL+path+"/run", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	output, err := io.ReadAll(response.Body)
	if err != nil || response.StatusCode != 200 || !bytes.Contains(output, []byte("MIXED_PROMPT_VERIFIED")) ||
		!bytes.Contains(output, []byte("RUN_FINISHED")) || bytes.Contains(output, []byte("AAH/")) ||
		bytes.Contains(output, []byte("AgM=")) {
		t.Fatalf("unexpected media run: %s, %v", output, err)
	}

	var receipt struct{ OperationID string }
	if err := client.request("GET", path+"/operations?runId=media-fixture", nil, &receipt); err != nil || receipt.OperationID == "" {
		t.Fatalf("reconnect lost the media run receipt: %+v, %v", receipt, err)
	}
	if !bytes.Contains(output, []byte(`"kind":"acp.prompt_part"`)) ||
		!bytes.Contains(output, []byte(`"turnId":"`+receipt.OperationID+`"`)) ||
		!bytes.Contains(output, []byte(`"itemCount":2`)) {
		t.Fatal("AG-UI user message omitted the turn's attachment reference")
	}
	historyPath := "/v1/workers/" + workerID + "/history?source=live&kind=acp.prompt_part&turnId=" + url.QueryEscape(receipt.OperationID)
	for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); time.Sleep(25 * time.Millisecond) {
		raw, err := client.client.Do(t.Context(), "GET", historyPath, nil)
		if err != nil {
			t.Fatal(err)
		}
		var history model.ReadHistoryResponse
		if err := protojson.Unmarshal(raw, &history); err != nil {
			t.Fatal(err)
		}
		var image, audio bool
		for _, record := range history.GetObservations() {
			extension := record.GetExtension()
			if extension.GetType() != "acp.prompt_part" {
				if record.GetGap() != nil {
					continue
				}
				t.Fatal("an unrelated ACP update appeared in the prompt attachments")
			}
			if record.GetTurnId() != receipt.OperationID {
				t.Fatal("attachment lost the recovered operation ID")
			}
			data := extension.GetData()
			image = image || bytes.Contains(data, []byte(`"data":"AAH/"`))
			audio = audio || bytes.Contains(data, []byte(`"data":"AgM="`))
		}
		if image && audio {
			assertACPMixedSource(t, client, workerID, receipt.OperationID)
			return
		}
	}
	t.Fatal("media was missing from the scoped Live source")
}

func assertACPMixedSource(t *testing.T, client *api, workerID, turn string) {
	t.Helper()
	want := []map[string]string{
		{"type": "text", "text": "  before\n"},
		{"type": "image", "mimeType": "image/png", "data": "AAH/"},
		{"type": "text", "text": ""},
		{"type": "text", "text": "\tbetween\n"},
		{"type": "text", "text": "\tbetween\n"},
		{"type": "audio", "mimeType": "audio/wav", "data": "AgM="},
		{"type": "text", "text": "after  "},
	}
	path := "/v1/workers/" + workerID + "/history?source=live&limit=1&turnId=" + url.QueryEscape(turn)
	for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); time.Sleep(25 * time.Millisecond) {
		var count int
		for pagePath := path; ; {
			raw, err := client.client.Do(t.Context(), "GET", pagePath, nil)
			var page model.ReadHistoryResponse
			if err != nil || protojson.Unmarshal(raw, &page) != nil {
				t.Fatalf("invalid scoped mixed prompt page: %v, %s", err, raw)
			}
			for _, record := range page.Observations {
				ext := record.GetExtension()
				if ext.GetType() != service.LivePromptMediaPartKind && ext.GetType() != service.LivePromptTextPartKind {
					continue
				}
				var block map[string]string
				if count >= len(want) || record.TurnId != turn || record.Cursor != promptPartCursor(turn, count) ||
					json.Unmarshal(ext.Data, &block) != nil || !reflect.DeepEqual(block, want[count]) {
					t.Fatalf("mixed prompt block %d lost its position, fields or content: %s", count, ext.Data)
				}
				count++
			}
			if page.NextCursor == "" {
				break
			}
			pagePath = path + "&cursor=" + url.QueryEscape(page.NextCursor)
		}
		if count == len(want) {
			return
		}
	}
	t.Fatal("scoped source omitted part of the mixed prompt")
}

func assertACPTextPrompt(t *testing.T, handler http.Handler, client *api, workerID string) {
	t.Helper()
	path := "/v1/ag-ui/workers/" + workerID
	var blocks []map[string]string
	for _, text := range []string{"ordered text", "", " ", "\n\tΩ", " ordered text"} {
		blocks = append(blocks, map[string]string{"type": "text", "text": text})
	}
	input := map[string]any{
		"threadId": workerID, "runId": "ordered-text", "forwardedProps": map[string]int{"generation": 2},
		"messages": []any{map[string]any{"role": "user", "content": blocks}},
	}
	body, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequestWithContext(ctx, "POST", path+"/run", bytes.NewReader(body)))
	out := response.Body.Bytes()
	if response.Code != 200 || !bytes.Contains(out, []byte("TEXT_BLOCKS_VERIFIED")) || !bytes.Contains(out, []byte("RUN_FINISHED")) {
		t.Fatalf("adapter did not receive the original text blocks: %d, %s", response.Code, out)
	}
	var receipt struct{ OperationID string }
	if err := client.request("GET", path+"/operations?runId=ordered-text", nil, &receipt); err != nil || receipt.OperationID == "" {
		t.Fatalf("missing text operation receipt: %+v, %v", receipt, err)
	}
	cursor := "prompt-" + receipt.OperationID
	if !bytes.Contains(out, []byte(`"cursor":"`+cursor+`"`)) {
		t.Fatal("user message omitted its Live source reference")
	}
	source := "/v1/workers/" + workerID + "/history?source=live&turnId=" + url.QueryEscape(receipt.OperationID)
	for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); time.Sleep(25 * time.Millisecond) {
		raw, err := client.client.Do(t.Context(), "GET", source, nil)
		var history model.ReadHistoryResponse
		if err != nil || protojson.Unmarshal(raw, &history) != nil {
			t.Fatalf("cannot read scoped text source: %s, %v", raw, err)
		}
		for _, record := range history.Observations {
			if record.Cursor != cursor {
				continue
			}
			var request struct {
				SessionID string
				Prompt    []map[string]string
			}
			ext := record.GetExtension()
			if ext.GetType() != service.LiveTextPromptKind || json.Unmarshal(ext.GetData(), &request) != nil ||
				request.SessionID != record.Session.SessionId || !reflect.DeepEqual(request.Prompt, blocks) {
				t.Fatalf("wrong retained text prompt: %s", ext.GetData())
			}
			return
		}
	}
	t.Fatal("no Live source record for the multipart text prompt")
}

func assertACPLiveSource(t *testing.T, client *api, worker *service.Worker) {
	t.Helper()
	if strings.Contains(worker.Output, "source-only-fixture") || strings.Contains(worker.Output, "QVNDUkFX") ||
		strings.Contains(worker.Output, "mcp-structured-source-only") || strings.Contains(worker.Output, "mcp-error-source-only") {
		t.Fatal("scoped ACP data entered the console preview")
	}
	links := make(map[string]string)
	for _, event := range worker.Console {
		if strings.Contains(event.Text, "permission-source-only") || strings.Contains(event.Text, "terminal-source-only") {
			t.Fatal("private permission or terminal fields reached a workspace row")
		}
		if event.ACP != nil && event.ACP.Source == "live" && event.ACP.TurnID == "initial-"+worker.ID {
			links[event.ACP.Kind] = event.ACP.Cursor
		}
	}
	path := "/v1/workers/" + worker.ID + "/history?source=live"
	for deadline := time.Now().Add(4 * time.Second); time.Now().Before(deadline); time.Sleep(25 * time.Millisecond) {
		raw, err := client.client.Do(t.Context(), "GET", path, nil)
		if err != nil {
			t.Fatal(err)
		}
		var page model.ReadHistoryResponse
		if err := protojson.Unmarshal(raw, &page); err != nil {
			t.Fatal(err)
		}
		var first, failure, large, structuredMCP, protocolError, permission, terminal bool
		for _, record := range page.Observations {
			if original := record.GetSourceRecord(); original != nil && record.Cursor == links[original.Type] && record.GetSourceCursor() == record.Cursor {
				input := record.GetInput()
				permission = permission || original.Type == "acp.permission_request" && input.GetRequestId() != "" &&
					len(input.GetChoices()) == 1 && input.GetChoices()[0].Id == "once" && bytes.Contains(original.Data, []byte("permission-source-only")) &&
					bytes.Contains(original.Data, []byte("allow_always")) && bytes.Contains(original.Data, []byte("permission-v3"))
				terminal = terminal || original.Type == "acp.prompt_result" && record.GetTurnEnded().GetReason() == "end_turn" &&
					bytes.Contains(original.Data, []byte("terminal-source-only")) && bytes.Contains(original.Data, []byte(`"inputTokens":37`))
			}
			data := string(record.GetExtension().GetData())
			if strings.Contains(data, "wrong-session-fixture") {
				t.Fatal("live source accepted an update belonging to another ACP session")
			}
			if record.GetExtension() == nil {
				continue
			}
			if record.GetSession().GetSessionId() != worker.NativeSession.SessionID || record.GetTurnId() == "" || record.GetCursor() == "" {
				t.Fatal("live source lost the bound observation identity")
			}
			first = first || strings.Contains(data, `"rawInput":{"path":"sample.txt"}`)
			failure = failure || strings.Contains(data, `"future_update_field":{"provider":"fixture"}`)
			large = large || (strings.Contains(data, "source-only-fixture") && strings.Contains(data, "QVNDUkFX"+strings.Repeat("AAEA", 140000)))
			structuredMCP = structuredMCP || (strings.Contains(data, "mcp-structured-source-only") && strings.Contains(data, `"data":"AgM="`))
			protocolError = protocolError || strings.Contains(data, "mcp-error-source-only")
		}
		if first && failure && large && structuredMCP && protocolError && permission && terminal {
			return
		}
	}
	t.Fatal("scoped ACP source did not retain the linked permission and terminal records, original tool fields and complete attachment")
}

func assertACPReattachment(t *testing.T, client *api, runID, workerID string) {
	t.Helper()
	path := "/v1/workers/" + workerID
	call := func(method, route string, input, out any) {
		t.Helper()
		if err := client.request(method, route, input, out); err != nil {
			t.Fatal(err)
		}
	}
	wait := func(accept func(service.Worker) bool) service.Worker {
		t.Helper()
		for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
			var run service.Run
			call("GET", "/v1/runs/"+runID, nil, &run)
			for _, worker := range run.Workers {
				if worker.ID == workerID {
					if worker.State == "failed" || worker.Error != "" {
						t.Fatalf("worker error after reattach: %s\n%s", worker.Error, worker.Output)
					}
					if accept(*worker) {
						return *worker
					}
				}
			}
		}
		t.Fatal("timed out waiting for the selected worker")
		return service.Worker{}
	}
	stopped := func(w service.Worker) bool { return w.State == "stopped" }
	call("POST", path+"/stop", struct{}{}, nil)
	original := wait(stopped)
	if original.NativeSession == nil || original.Control == nil {
		t.Fatal("stopped worker lost its provider binding")
	}
	var page service.ProviderSessionPage
	call("GET", path+"/provider-sessions?limit=1", nil, &page)
	if len(page.Sessions) != 1 || page.Sessions[0].SessionID != original.NativeSession.SessionID {
		t.Fatalf("discovery leaked or omitted a session: %+v", page)
	}
	input := map[string]any{"idempotency_key": "resume-test", "generation": original.Control.Generation}
	call("POST", path+"/reattach", input, nil)
	fresh := wait(func(w service.Worker) bool { return w.State == "idle" })
	call("POST", path+"/reattach", input, nil)
	if fresh.NativeSession == nil || *fresh.NativeSession != *original.NativeSession ||
		fresh.Control == nil || !fresh.Control.Held || fresh.Control.Generation != original.Control.Generation+1 {
		t.Fatalf("original identity or lease lost: %+v", fresh)
	}
	call("POST", path+"/messages", map[string]any{
		"generation": fresh.Control.Generation, "text": "first prompt after explicit reattach",
	}, nil)
	wait(func(w service.Worker) bool {
		return w.State == "completed" && strings.Contains(w.Output, "REATTACHED_ORIGINAL_SESSION")
	})
	call("POST", path+"/stop", struct{}{}, nil)
	wait(stopped)
}

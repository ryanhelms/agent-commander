package service

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"agentcommander/internal/hosted"
	"agentcommander/internal/relay"
)

func TestHostedWorkerAccess(t *testing.T) {
	t.Run("direct HTTPS", func(t *testing.T) { testHostedWorkerAccess(t, false) })
	t.Run("outbound relay", func(t *testing.T) { testHostedWorkerAccess(t, true) })
}

func TestHostedFrontendToolRenewsExpiredCredential(t *testing.T) {
	t.Run("direct HTTPS", func(t *testing.T) { testHostedFrontendToolRenewal(t, false) })
	t.Run("outbound relay", func(t *testing.T) { testHostedFrontendToolRenewal(t, true) })
}

func testHostedFrontendToolRenewal(t *testing.T, relayed bool) {
	f := newFixture(t)
	worker := f.delegate(f.run(), "renewal")
	path := "/v1/workers/" + worker.ID
	tools := path + "/frontend-tools"
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", path+"/control/ready", worker.Token, struct{}{}, 200, "")
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed"}, 200, "")
	f.call("POST", path+"/control", "", map[string]any{"held": true, "generation": 1}, 200, "")
	f.call("POST", tools+"/ready", worker.Token, struct{}{}, 200, "")

	const observeScope, promptScope = "commander:observe", "commander:prompt"
	scopes := []string{observeScope, promptScope, frontendToolScope}
	var shortExpiry atomic.Int64
	idp := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := r.FormValue("token")
		clientID, tokenScopes := "fixture-app", scopes
		expires := time.Now().Add(time.Minute).Unix()
		switch token {
		case "original":
			expires = shortExpiry.Load()
		case "observe-only":
			tokenScopes = []string{observeScope}
		case "without-prompt":
			tokenScopes = []string{observeScope, frontendToolScope}
		case "other-app":
			clientID = "other-app"
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"active": true, "sub": "fixture-owner", "client_id": clientID, "iss": "fixture-issuer",
			"aud": "fixture-audience", "exp": expires, "scope": strings.Join(tokenScopes, " "),
		})
	}))
	defer idp.Close()
	dir := t.TempDir()
	ca, grants := filepath.Join(dir, "ca.pem"), filepath.Join(dir, "grants.json")
	if err := os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: idp.Certificate().Raw}), 0600); err != nil {
		t.Fatal(err)
	}
	bindings := []hosted.Grant{
		{Subject: "fixture-owner", ClientID: "fixture-app", Workers: map[string][]string{worker.ID: scopes}},
		{Subject: "fixture-owner", ClientID: "other-app", Workers: map[string][]string{worker.ID: scopes}},
	}
	data, err := json.Marshal(bindings)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(grants, data, 0600); err != nil {
		t.Fatal(err)
	}
	gateway, err := hosted.New(hosted.Config{Introspection: idp.URL, IntrospectionCA: ca, ClientID: "fixture",
		Issuer: "fixture-issuer", Audience: "fixture-audience"}, "fixture-secret", grants)
	if err != nil {
		t.Fatal(err)
	}
	base := "/v1/ag-ui/workers/" + worker.ID
	initialDetached := make(chan struct{})
	authorized := gateway.Handler(f.api)
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authorized.ServeHTTP(w, r)
		if r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/run") {
			close(initialDetached)
		}
	})
	var client *http.Client
	var origin string
	if relayed {
		tunnel := newHostedRelay(t, handler)
		tunnel.connect(t, base)
		client, origin = tunnel.client, tunnel.endpoint
	} else {
		server := httptest.NewTLSServer(handler)
		t.Cleanup(server.Close)
		client, origin = server.Client(), server.URL
	}
	client.Timeout = 7 * time.Second
	request := func(method, path, token, body string, want int) *http.Response {
		t.Helper()
		r, err := http.NewRequestWithContext(t.Context(), method, origin+path, strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		r.Header.Set("Authorization", "Bearer "+token)
		r.Header.Set("Content-Type", "application/json")
		res, err := client.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = res.Body.Close() })
		if res.StatusCode != want {
			detail, _ := io.ReadAll(res.Body)
			t.Fatalf("%s %s as %s returned %d, want %d: %s", method, path, token, res.StatusCode, want, detail)
		}
		return res
	}
	waitForFrame := func(scanner *bufio.Scanner, marker string, forbidden ...string) {
		t.Helper()
		for scanner.Scan() {
			frame := scanner.Text()
			for _, value := range forbidden {
				if strings.Contains(frame, value) {
					t.Fatalf("observer received a forbidden frame: %s", frame)
				}
			}
			if strings.Contains(frame, marker) {
				return
			}
		}
		t.Fatalf("missing %s in stream: %v", marker, scanner.Err())
	}
	const runID = "run-token-renewal"
	input := fmt.Sprintf(`{"threadId":%q,"runId":%q,"messages":[{"role":"user","content":"Select a document"}],
		"tools":[{"name":"select_document","description":"Select a document","parameters":{"type":"object"}}],
		"forwardedProps":{"generation":2}}`, worker.ID, runID)
	expiry := time.Now().Add(4 * time.Second).Unix()
	shortExpiry.Store(expiry)
	original := request("POST", base+"/run", "original", input, 200)
	queued := hostedSnapshot(t, bufio.NewScanner(original.Body))
	_ = original.Body.Close()
	select {
	case <-initialDetached:
	case <-time.After(3 * time.Second):
		t.Fatal("original app stream has not disconnected")
	}
	f.call("POST", path+"/messages/"+queued.OperationID+"/claim", worker.Token, struct{}{}, 200, "")
	callBody := map[string]any{"name": "select_document", "arguments": map[string]string{"folder": "private-folder"}}
	var pending frontendCall
	if err := json.Unmarshal(f.call("POST", tools+"/calls", worker.Token, callBody, 200, ""), &pending); err != nil || pending.ID == "" {
		t.Fatalf("missing pending tool call: %+v, %v", pending, err)
	}
	operationPath := base + "/operations/" + queued.OperationID
	observe := operationPath + "?runId=" + runID + "&projection=incremental"
	passive := request("GET", observe+"&frontendTools=observe", "original", "", 200)
	if passive.Header.Get("Commander-Frontend-Tools") != "observe" {
		t.Fatal("host did not acknowledge passive tool observation")
	}
	passiveFrames := bufio.NewScanner(passive.Body)
	waitForFrame(passiveFrames, "MESSAGES_SNAPSHOT")
	narrow := request("GET", observe, "observe-only", "", 200)
	narrowEvents := bufio.NewScanner(narrow.Body)
	waitForFrame(narrowEvents, "MESSAGES_SNAPSHOT")
	f.call("POST", path+"/output", worker.Token, map[string]any{"events": []ConsoleEvent{
		{Kind: "text", Text: "observer-safe-marker"},
	}}, 200, "")
	waitForFrame(narrowEvents, "observer-safe-marker", pending.ID, "private-folder")
	waitForFrame(passiveFrames, "observer-safe-marker", "TOOL_CALL_START", "TOOL_CALL_END")
	_ = passive.Body.Close()
	_ = narrow.Body.Close()
	if time.Now().Unix() >= expiry {
		t.Fatal("original token expired before the scope isolation check")
	}

	time.Sleep(time.Until(time.Unix(expiry, 0)))
	request("GET", observe, "original", "", 401).Body.Close()
	if payload := f.call("GET", tools+"/calls/"+pending.ID, worker.Token, nil, 200, ""); !bytes.Contains(payload, []byte(pending.ID)) {
		t.Fatalf("original pending call did not survive token expiry: %s", payload)
	}
	f.call("POST", tools+"/calls", worker.Token, callBody, 409, "")
	resultPath := operationPath + "/tools/" + pending.ID + "/result"
	result := fmt.Sprintf(`{"id":"fixture-result","role":"tool","toolCallId":%q,"content":"chosen.md","error":"Could not open selection"}`, pending.ID)
	request("POST", resultPath, "without-prompt", result, 409).Body.Close()
	request("POST", resultPath, "other-app", result, 404).Body.Close()

	renewed := request("GET", observe, "renewed", "", 200)
	events := bufio.NewScanner(renewed.Body)
	waitForFrame(events, "TOOL_CALL_END")
	request("POST", resultPath, "renewed", result, 200).Body.Close()
	if payload := f.call("GET", tools+"/calls/"+pending.ID, worker.Token, nil, 200, ""); !bytes.Contains(payload, []byte("chosen.md")) {
		t.Fatalf("harness did not receive the original call's result: %s", payload)
	}
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed", "message_id": queued.OperationID}, 200, "")
	waitForFrame(events, "TOOL_CALL_RESULT")
	waitForFrame(events, "MESSAGES_SNAPSHOT", "TOOL_CALL_END", "RUN_FINISHED")
	if frame := events.Text(); !strings.Contains(frame, `"error":"Could not open selection"`) || !strings.Contains(frame, "chosen.md") {
		t.Fatalf("missing error or partial tool result in the closing transcript: %s", frame)
	}
	waitForFrame(events, "RUN_FINISHED", "TOOL_CALL_END")
	_ = renewed.Body.Close()
}

func testHostedWorkerAccess(t *testing.T, relayed bool) {
	const detailMarker = "PrivacyFixtureLocalDetail"
	const promptMarker = "PrivacyFixturePrompt"
	const replyMarker = "PrivacyFixtureApprovalReply"
	const resultMarker = "PrivacyFixtureToolResult"
	const attachmentMarker = "PrivacyFixtureSourceBytes"
	const malformedMarker = "PrivacyFixtureMalformed"
	const overloadMarker = "PrivacyFixtureOverload"
	const offlineMarker = "PrivacyFixtureOffline"
	f := newFixture(t)
	history := &nativeFixtureLauncher{recorder: f.p}
	var err error
	f.api, err = New(f.dir, history)
	if err != nil {
		t.Fatal(err)
	}
	coordinator := f.run()
	worker := f.delegate(coordinator, "target")
	path := "/v1/workers/" + worker.ID
	ref := NativeSession{HarnessInstance: "local-claude", SessionID: "hosted-fixture-session"}
	f.call("POST", path+"/native-session", "", ref, 200, "")
	f.call("POST", path+"/output", worker.Token, map[string]any{"details": claudePrivateDetails(detailMarker)}, 200, "")
	attachmentData := base64.StdEncoding.EncodeToString([]byte(attachmentMarker))
	attachmentBody := fmt.Sprintf(`{"type":"image","mimeType":"image/png","data":%q}`, attachmentData)
	f.call("POST", path+"/live-source", worker.Token, LiveSourceUpdate{Session: ref, Cursor: "hosted-source", TurnID: "turn",
		Kind: "acp.prompt_part", Body: []byte(attachmentBody)}, 200, "")
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", path+"/control/ready", worker.Token, struct{}{}, 200, "")
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed"}, 200, "")
	f.call("POST", path+"/control", "", map[string]any{"held": true, "generation": 1}, 200, "")

	idp := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id, secret, ok := r.BasicAuth()
		if !ok || id != "commander" || secret != "test-secret" || r.Method != http.MethodPost {
			http.Error(w, "unauthorized", 401)
			return
		}
		token := r.FormValue("token")
		scope, audience := "commander:observe commander:prompt commander:reply commander:frontend-tools", "commander"
		if token == "observe-only" {
			scope = "commander:observe"
			token = "app-a"
		}
		if token == "wrong-audience" {
			audience = "different-service"
			token = "app-a"
		}
		if token == "no-frontend" {
			scope = "commander:observe commander:prompt commander:reply"
			token = "app-a"
		}
		if token == "history-only" {
			scope = "commander:history"
			token = "app-a"
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"active": token == "app-a" || token == "app-b",
			"sub":    "owner", "client_id": token, "iss": "test-issuer",
			"exp": time.Now().Add(time.Minute).Unix(), "aud": []string{audience}, "scope": scope,
		})
	}))
	defer idp.Close()
	dir := t.TempDir()
	ca := filepath.Join(dir, "ca.pem")
	if err := os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: idp.Certificate().Raw}), 0600); err != nil {
		t.Fatal(err)
	}
	grantPath := filepath.Join(dir, "grants.json")
	writeGrants := func(apps ...string) {
		t.Helper()
		grants := make([]hosted.Grant, 0, len(apps))
		for _, app := range apps {
			grants = append(grants, hosted.Grant{Subject: "owner", ClientID: app, Workers: map[string][]string{
				worker.ID: {"commander:observe", "commander:prompt", "commander:reply", "commander:frontend-tools", "commander:history"},
			}})
		}
		raw, err := json.Marshal(grants)
		if err != nil {
			t.Fatal(err)
		}
		replacement := grantPath + ".next"
		if err := os.WriteFile(replacement, raw, 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.Rename(replacement, grantPath); err != nil {
			t.Fatal(err)
		}
	}
	writeGrants("app-a", "app-b")
	gateway, err := hosted.New(hosted.Config{
		Introspection: idp.URL, IntrospectionCA: ca, ClientID: "commander", Issuer: "test-issuer", Audience: "commander",
	}, "test-secret", grantPath)
	if err != nil {
		t.Fatal(err)
	}
	var serviceHandler atomic.Value
	serviceHandler.Store(f.api)
	handler := gateway.Handler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		serviceHandler.Load().(http.Handler).ServeHTTP(w, r)
	}))
	var endpoint string
	var client *http.Client
	var tunnel *hostedRelayFixture
	if relayed {
		tunnel = newHostedRelay(t, handler)
		endpoint, client = tunnel.endpoint, tunnel.client
	} else {
		server := httptest.NewTLSServer(handler)
		defer server.Close()
		endpoint, client = server.URL, server.Client()
	}
	client.Timeout = 8 * time.Second
	call := func(method, path, token, body string, want int) *http.Response {
		t.Helper()
		req, err := http.NewRequest(method, endpoint+path, bytes.NewBufferString(body))
		if err != nil {
			t.Fatal(err)
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		req.Header.Set("Content-Type", "application/json")
		res, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = res.Body.Close() })
		if res.StatusCode != want {
			t.Fatalf("%s %s as %s: got %s, want %d", method, path, token, res.Status, want)
		}
		return res
	}

	base := "/v1/ag-ui/workers/" + worker.ID
	call("GET", base, "", "", 401)
	if relayed {
		call("GET", base, "app-a", "", 503)
		tunnel.connect(t, base)
	}
	call("GET", base, "wrong-audience", "", 401)
	call("GET", "/v1/ag-ui/events", "app-a", "", 404)
	call("GET", path+"/tool-details", "app-a", "", 404)
	for _, detail := range claudePrivateDetails(detailMarker) {
		call("GET", path+"/tool-details?key="+detail.Key, "history-only", "", 404)
	}
	call("GET", path+"/terminal", "app-a", "", 404)
	call("GET", "/v1/ag-ui/workers/"+coordinator.ID, "app-a", "", 403)
	call("GET", path+"/history", "app-a", "", 403)
	call("GET", path+"/history?source=journal", "app-a", "", 403)
	recordQuery := "/history?source=provider&recordCursor=selected-original&cursor=fixture-page"
	call("GET", path+recordQuery, "observe-only", "", 403)
	call("GET", "/v1/workers/"+coordinator.ID+recordQuery, "history-only", "", 403)
	recordResponse := call("GET", path+recordQuery, "history-only", "", 200)
	original, err := io.ReadAll(recordResponse.Body)
	if err != nil || !bytes.Contains(original, []byte("selected-original")) {
		t.Fatalf("history grant could not open the selected provider original: %v", err)
	}
	livePath := path + "/history?source=live"
	call("GET", livePath, "app-a", "", 403)
	call("GET", livePath+"&turnId=turn", "app-a", "", 403)
	call("POST", path+"/live-source", "history-only", "{}", 404)
	journalPath := path + "/history?source=journal&limit=2&cursor=journal-cursor"
	call("GET", "/v1/workers/"+coordinator.ID+"/history?source=journal", "history-only", "", 403)
	journal := call("GET", journalPath, "history-only", "", 200)
	var journalPage struct {
		Observations []struct {
			Extension struct {
				Type string
				Data []byte
			}
		}
	}
	if err := json.NewDecoder(journal.Body).Decode(&journalPage); err != nil || len(journalPage.Observations) != 1 {
		t.Fatalf("scoped hosted journal did not return the source observation: %+v, %v", journalPage, err)
	}
	attachment := journalPage.Observations[0].Extension
	if attachment.Type != "claude.journal.attachment" || !bytes.Equal(attachment.Data, []byte{0, 1}) {
		t.Fatalf("scoped hosted history changed the attachment: %+v", attachment)
	}
	live := call("GET", livePath+"&turnId=turn", "history-only", "", 200)
	rawLive, err := io.ReadAll(live.Body)
	encodedSource := base64.StdEncoding.EncodeToString([]byte(attachmentBody))
	if err != nil || !strings.Contains(string(rawLive), "hosted-source") || !strings.Contains(string(rawLive), encodedSource) {
		t.Fatal("scoped hosted history did not return the live ACP source", err)
	}
	var info struct {
		Generation int `json:"generation"`
	}
	res := call("GET", base, "observe-only", "", 200)
	snapshot, err := io.ReadAll(res.Body)
	if err != nil || bytes.Contains(snapshot, []byte(detailMarker)) {
		t.Fatalf("hosted snapshot read error or private detail: %v", err)
	}
	if err := json.Unmarshal(snapshot, &info); err != nil || info.Generation != 2 {
		t.Fatalf("worker info %+v: %v", info, err)
	}

	input, err := json.Marshal(map[string]any{
		"threadId": worker.ID, "runId": "hosted-run",
		"forwardedProps": map[string]int{"generation": 2},
		"messages":       []any{map[string]string{"role": "user", "content": promptMarker}},
		"tools": []any{map[string]any{
			"name": "select_document", "description": "Select a document",
			"parameters": map[string]any{
				"type": "object", "properties": map[string]any{
					"folder":   map[string]any{"type": "string"},
					"document": map[string]any{"type": "integer", "maximum": int64(9007199254740992)},
				},
				"required": []string{"folder"}, "additionalProperties": false,
			},
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	call("POST", base+"/run?diagnostic="+malformedMarker, "app-a", `{"messages":[`+malformedMarker, 400)
	call("POST", base+"/run", "observe-only", string(input), 403)
	call("POST", base+"/run", "no-frontend", string(input), 403)
	recursiveSchema := strings.Replace(string(input), `"type":"object"`, `"type":"object","$ref":"#"`, 1)
	call("POST", base+"/run", "app-a", recursiveSchema, 400)
	call("POST", base+"/run", "app-a", string(input), 501)
	toolPath := path + "/frontend-tools"
	f.call("POST", toolPath+"/ready", worker.Token, struct{}{}, 200, "")
	lookupPath := base + "/operations?runId=hosted-run"
	call("GET", lookupPath, "app-a", "", 404)
	var stream *http.Response
	if relayed {
		tunnel.dropReply.Store(true)
		call("POST", base+"/run", "app-a", string(input), 502)
		tunnel.wait(t, base, http.StatusServiceUnavailable)
		tunnel.connect(t, base)
		lookup := call("GET", lookupPath, "app-a", "", 200)
		var receipt aguiRunReceipt
		if err := json.NewDecoder(lookup.Body).Decode(&receipt); err != nil || receipt.OperationID == "" {
			t.Fatalf("missing receipt after the host disconnected before response headers: %+v, %v", receipt, err)
		}
		stream = call("GET", base+"/operations/"+receipt.OperationID+"?runId=hosted-run", "app-a", "", 200)
	} else {
		stream = call("POST", base+"/run", "app-a", string(input), 200)
	}
	defer stream.Body.Close()
	scanner := bufio.NewScanner(stream.Body)
	queued := hostedSnapshot(t, scanner)
	if queued.OperationID == "" || queued.OperationStatus != "queued" {
		t.Fatalf("missing queued operation: %+v, %v", queued, scanner.Err())
	}
	observePath := base + "/operations/" + queued.OperationID + "?runId=hosted-run"
	changedTool := strings.Replace(string(input), "Select a document", "Select a different document", 1)
	call("POST", base+"/run", "app-a", changedTool, 409)
	call("GET", observePath, "app-b", "", 404)
	call("GET", lookupPath, "app-b", "", 404)
	if relayed {
		for range 15 {
			extra := call("GET", observePath+"&frontendTools=observe", "app-a", "", 200)
			defer extra.Body.Close()
		}
		call("GET", lookupPath, "app-a", "", 429)
		call("POST", base+"/run?diagnostic="+overloadMarker, "app-a", strings.ReplaceAll(string(input), promptMarker, overloadMarker), 429)
		tunnel.disconnect()
		for scanner.Scan() {
		}
		if scanner.Err() == nil {
			t.Fatal("tunnel loss looked like a completed response")
		}
		tunnel.wait(t, base, http.StatusServiceUnavailable)
		call("POST", base+"/run?diagnostic="+offlineMarker, "app-a", strings.ReplaceAll(string(input), promptMarker, offlineMarker), 503)
		tunnel.connect(t, base)
		lookup := call("GET", lookupPath, "app-a", "", 200)
		var receipt aguiRunReceipt
		if err := json.NewDecoder(lookup.Body).Decode(&receipt); err != nil || receipt.OperationID != queued.OperationID {
			t.Fatalf("lookup found the wrong receipt: %+v, %v", receipt, err)
		}
		resumed := call("GET", observePath, "app-a", "", 200)
		scanner = bufio.NewScanner(resumed.Body)
		defer resumed.Body.Close()
		if got := hostedSnapshot(t, scanner); got.OperationID != queued.OperationID {
			t.Fatalf("observed a different operation: %+v", got)
		}
		retried := call("POST", base+"/run?frontendTools=observe", "app-a", string(input), 200)
		if got := hostedSnapshot(t, bufio.NewScanner(retried.Body)); got.OperationID != queued.OperationID {
			t.Fatalf("retry started a different operation: %+v", got)
		}
		_ = retried.Body.Close()
	}

	f.call("POST", path+"/messages/"+queued.OperationID+"/claim", worker.Token, struct{}{}, 200, "")
	if definitions := f.call("GET", toolPath, worker.Token, nil, 200, ""); !bytes.Contains(definitions, []byte("select_document")) {
		t.Fatalf("missing authorized tool definitions: %s", definitions)
	}
	f.call("POST", toolPath+"/calls", worker.Token, map[string]any{
		"name": "select_document", "arguments": map[string]any{"folder": 42},
	}, 400, "")
	f.call("POST", toolPath+"/calls", worker.Token, map[string]any{
		"name": "select_document", "arguments": map[string]any{"folder": "plans", "document": int64(9007199254740993)},
	}, 400, "")
	var frontend frontendCall
	if err := json.Unmarshal(f.call("POST", toolPath+"/calls", worker.Token, map[string]any{
		"name": "select_document", "arguments": map[string]any{"folder": "plans", "document": int64(9007199254740992)},
	}, 200, ""), &frontend); err != nil || frontend.ID == "" {
		t.Fatalf("missing frontend call: %+v, %v", frontend, err)
	}
	foundCall := false
	for scanner.Scan() {
		if strings.Contains(scanner.Text(), "TOOL_CALL_END") && strings.Contains(scanner.Text(), frontend.ID) {
			foundCall = true
			break
		}
	}
	if !foundCall {
		t.Fatalf("missing frontend AG-UI call: %v", scanner.Err())
	}
	resultPath := base + "/operations/" + queued.OperationID + "/tools/" + frontend.ID + "/result"
	result, err := json.Marshal(toolMessage{ID: "fixture-result", Role: "tool", ToolCallID: frontend.ID, Content: "selected document"})
	if err != nil {
		t.Fatal(err)
	}
	call("POST", resultPath, "app-b", string(result), 404)
	call("POST", resultPath, "no-frontend", string(result), 403)
	call("POST", strings.Replace(resultPath, worker.ID, coordinator.ID, 1), "app-a", string(result), 403)
	resultDir := filepath.Join(f.dir, "frontend-results")
	if err := os.WriteFile(resultDir, []byte("storage unavailable"), 0600); err != nil {
		t.Fatal(err)
	}
	call("POST", resultPath, "app-a", string(result), 500)
	var uncommitted frontendCall
	if err := json.Unmarshal(f.call("GET", toolPath+"/calls/"+frontend.ID, worker.Token, nil, 200, ""), &uncommitted); err != nil || uncommitted.Result != nil {
		t.Fatalf("a failed save exposed a result to the worker: %+v, %v", uncommitted, err)
	}
	if err := os.Remove(resultDir); err != nil {
		t.Fatal(err)
	}
	call("POST", resultPath, "app-a", string(result), 200)
	call("POST", resultPath, "app-a", string(result), 200)
	// Whichever terminal disposition commits first wins under the state lock.
	alreadyResolved := f.call("POST", toolPath+"/calls/"+frontend.ID+"/cancel", worker.Token, nil, 200, "")
	if !bytes.Contains(alreadyResolved, []byte(`"status":"already_resolved"`)) || bytes.Contains(alreadyResolved, []byte("selected document")) {
		t.Fatalf("late cancellation overwrote an accepted app result: %s", alreadyResolved)
	}
	var cancelled frontendCall
	if err := json.Unmarshal(f.call("POST", toolPath+"/calls", worker.Token, map[string]any{
		"name": "select_document", "arguments": map[string]string{"folder": "cancelled"},
	}, 200, ""), &cancelled); err != nil || cancelled.ID == "" {
		t.Fatalf("could not start cancelled picker: %+v, %v", cancelled, err)
	}
	cancelPath := toolPath + "/calls/" + cancelled.ID + "/cancel"
	f.call("POST", cancelPath, coordinator.Token, nil, 403, "")
	f.call("POST", cancelPath, "", nil, 403, "")
	for range 2 {
		cancelReceipt := f.call("POST", cancelPath, worker.Token, nil, 200, "")
		if !bytes.Contains(cancelReceipt, []byte(`"status":"cancelled"`)) {
			t.Fatalf("expected a worker cancellation: %s", cancelReceipt)
		}
	}
	cancelledResultPath := base + "/operations/" + queued.OperationID + "/tools/" + cancelled.ID + "/result"
	lateResult := fmt.Sprintf(`{"id":"late-selection","role":"tool","toolCallId":%q,"content":"picked.md"}`, cancelled.ID)
	call("POST", cancelledResultPath, "app-a", lateResult, 409)
	savedPath := filepath.Join(resultDir, digest(queued.OperationID)+".json")
	if info, err := os.Stat(savedPath); err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("accepted result was not stored privately: %v, %v", info, err)
	}
	if workspace := f.call("GET", "/v1/runs/"+coordinator.RunID, "", nil, 200, ""); bytes.Contains(workspace, []byte("selected document")) {
		t.Fatal("workspace view exposed the app's tool result record")
	}
	var pendingTool frontendCall
	if err := json.Unmarshal(f.call("POST", toolPath+"/calls", worker.Token, map[string]any{
		"name": "select_document", "arguments": map[string]string{"folder": "archive"},
	}, 200, ""), &pendingTool); err != nil || pendingTool.ID == "" {
		t.Fatalf("could not create pending frontend call: %+v, %v", pendingTool, err)
	}
	pendingPath := base + "/operations/" + queued.OperationID + "/tools/" + pendingTool.ID + "/result"
	for scanner.Scan() {
		if strings.Contains(scanner.Text(), "TOOL_CALL_END") && strings.Contains(scanner.Text(), pendingTool.ID) {
			break
		}
	}
	if !strings.Contains(scanner.Text(), pendingTool.ID) {
		t.Fatalf("original app missed the invocation: %v", scanner.Err())
	}
	pendingResult, err := json.Marshal(toolMessage{ID: "late-result", Role: "tool", ToolCallID: pendingTool.ID, Content: "archive.md"})
	if err != nil {
		t.Fatal(err)
	}
	replay := call("GET", observePath, "app-a", "", 200)
	replayEvents := bufio.NewScanner(replay.Body)
	foundResult := false
	for replayEvents.Scan() {
		if strings.Contains(replayEvents.Text(), "TOOL_CALL_END") {
			t.Fatal("reconnect presented a resolved frontend call as a new invocation")
		}
		if strings.Contains(replayEvents.Text(), "MESSAGES_SNAPSHOT") {
			foundResult = strings.Contains(replayEvents.Text(), "selected document")
			break
		}
	}
	_ = replay.Body.Close()
	if !foundResult {
		t.Fatalf("resolved frontend tool was missing from reconnect: %v", replayEvents.Err())
	}
	if resolved := f.call("GET", toolPath+"/calls/"+frontend.ID, worker.Token, nil, 200, ""); !bytes.Contains(resolved, []byte("selected document")) {
		t.Fatalf("worker did not receive result: %s", resolved)
	}
	changedResult := strings.Replace(string(result), "selected document", "different document", 1)
	call("POST", resultPath, "app-a", changedResult, 409)
	var question Question
	if err := json.Unmarshal(f.call("POST", path+"/questions", worker.Token, map[string]string{"question": "Reply?"}, 201, ""), &question); err != nil {
		t.Fatal(err)
	}
	for _, projection := range []string{"", "&projection=incremental"} {
		reconnected := call("GET", observePath+projection, "app-a", "", 200)
		restored := bufio.NewScanner(reconnected.Body)
		state := hostedSnapshot(t, restored)
		if state.OperationID != queued.OperationID || len(state.PendingRequests) != 1 || state.PendingRequests[0].ID != question.ID ||
			len(state.UnconfirmedToolCalls) != 1 || state.UnconfirmedToolCalls[0].ID != pendingTool.ID ||
			state.UnconfirmedToolCalls[0].Name != "select_document" || !bytes.Contains(state.UnconfirmedToolCalls[0].Arguments, []byte("archive")) {
			t.Fatalf("reconnect lost the request or unconfirmed original invocation: %+v", state)
		}
		marker := "after-reconnect-" + randomID("")
		f.call("POST", path+"/output", worker.Token, map[string]any{"events": []ConsoleEvent{{Kind: "text", Text: marker}}}, 200, "")
		recoveredTool := false
		for restored.Scan() {
			frame := restored.Text()
			if strings.Contains(frame, "TOOL_CALL_START") || strings.Contains(frame, "TOOL_CALL_END") || strings.Contains(frame, "AAE=") {
				t.Fatalf("reconnect reissued a tool or exposed an attachment: %s", frame)
			}
			recoveredTool = recoveredTool || strings.Contains(frame, "selected document")
			if strings.Contains(frame, marker) {
				break
			}
		}
		_ = reconnected.Body.Close()
		if !recoveredTool || !strings.Contains(restored.Text(), marker) {
			t.Fatalf("missing resolved result or live marker after reconnect: %v", restored.Err())
		}
	}
	replyPath := base + "/requests/" + question.ID + "/reply"
	replyBody := fmt.Sprintf(`{"answer":%q,"generation":2}`, replyMarker)
	call("POST", replyPath, "app-a", fmt.Sprintf(`{"answer":%q}`, replyMarker), 409)
	call("POST", replyPath, "app-a", replyBody, 200)
	f.call("POST", path+"/control", "", map[string]any{"held": false, "generation": 2}, 200, "")
	call("POST", pendingPath, "app-a", string(pendingResult), 409)
	f.call("GET", toolPath+"/calls/"+pendingTool.ID, worker.Token, nil, 409, "")
	call("POST", replyPath, "app-a", replyBody, 200)
	call("POST", replyPath, "app-a", `{"answer":"No","generation":2}`, 409)
	f.call("POST", path+"/output", worker.Token, map[string]any{"events": []ConsoleEvent{
		{Kind: "tool_call", ToolID: "read-fixture", Name: "Read"},
		{Kind: "tool_result", ToolID: "read-fixture", Text: resultMarker},
	}}, 200, "")
	seenResult := false
	for scanner.Scan() {
		if strings.Contains(scanner.Text(), resultMarker) {
			seenResult = true
			break
		}
	}
	if !seenResult {
		t.Fatalf("did not observe the tool result: %v", scanner.Err())
	}
	if relayed {
		stats := tunnel.readMetrics()
		if !strings.Contains(stats, "commander_relay_connected_hosts 1\n") {
			t.Fatalf("unexpected telemetry: %s", stats)
		}
		for _, value := range []string{detailMarker, promptMarker, replyMarker, resultMarker, attachmentMarker, attachmentData, encodedSource,
			malformedMarker, overloadMarker, offlineMarker, worker.ID, queued.OperationID} {
			if strings.Contains(stats, value) {
				t.Fatal("relay telemetry contained request or response data")
			}
		}
	}
	writeGrants("app-b")
	call("GET", journalPath, "history-only", "", 403)
	call("GET", livePath, "history-only", "", 403)
	call("GET", livePath+"&turnId=turn", "history-only", "", 403)
	call("POST", pendingPath, "app-a", string(pendingResult), 403)
	call("GET", observePath, "app-a", "", 403)
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed", "message_id": queued.OperationID}, 200, "")
	for scanner.Scan() {
		if strings.Contains(scanner.Text(), "RUN_FINISHED") {
			t.Fatal("revoked app received completion")
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("revoked stream failed to close: %v", err)
	}

	writeGrants("app-a", "app-b")
	var control WorkerControl
	rawControl := f.call("POST", path+"/control", "", map[string]any{"held": true, "generation": 3}, 200, "")
	if err := json.Unmarshal(rawControl, &control); err != nil || control.Generation != 4 {
		t.Fatalf("could not reacquire input: %+v, %v", control, err)
	}
	laterInput := strings.Replace(string(input), `"runId":"hosted-run"`, `"runId":"later-run"`, 1)
	laterInput = strings.Replace(laterInput, `"generation":2`, `"generation":4`, 1)
	later := call("POST", base+"/run", "app-a", laterInput, 200)
	laterState := hostedSnapshot(t, bufio.NewScanner(later.Body))
	if laterState.OperationID == "" || laterState.OperationID == queued.OperationID {
		t.Fatal("later run reused the original operation")
	}
	_ = later.Body.Close()
	f.call("POST", path+"/messages/"+laterState.OperationID+"/claim", worker.Token, struct{}{}, 200, "")
	f.call("POST", path+"/output", worker.Token, map[string]any{"events": []ConsoleEvent{
		{Kind: "text", Text: "hosted-later-operation-output"},
	}}, 200, "")
	f.call("POST", path+"/questions", worker.Token, map[string]string{"question": "Later hosted approval?"}, 201, "")
	var unconfirmed frontendCall
	if err := json.Unmarshal(f.call("POST", toolPath+"/calls", worker.Token, map[string]any{
		"name": "select_document", "arguments": map[string]string{"folder": "unconfirmed"},
	}, 200, ""), &unconfirmed); err != nil || unconfirmed.ID == "" {
		t.Fatalf("could not create a pending invocation before restart: %+v, %v", unconfirmed, err)
	}
	checkArchived := func(token, expected string) {
		t.Helper()
		res := call("GET", observePath, token, "", 200)
		raw, err := io.ReadAll(res.Body)
		_ = res.Body.Close()
		if err != nil || !bytes.Contains(raw, []byte("RUN_FINISHED")) || bytes.Contains(raw, []byte("TOOL_CALL_END")) {
			t.Fatalf("archived run did not finish passively: %s, %v", raw, err)
		}
		if bytes.Contains(raw, []byte("hosted-later-operation-output")) || bytes.Contains(raw, []byte("Later hosted approval?")) {
			t.Fatalf("archived run received newer worker records: %s", raw)
		}
		content, args := bytes.Contains(raw, []byte("selected document")), bytes.Contains(raw, []byte(`\"folder\":\"plans\"`))
		switch expected {
		case "result":
			if !content || !args || !bytes.Contains(raw, []byte(frontend.ID)) ||
				!bytes.Contains(raw, []byte(cancelled.ID)) || !bytes.Contains(raw, []byte("cancelled its wait")) {
				t.Fatalf("retained call or result missing: %s", raw)
			}
		case "gap":
			if content || !bytes.Contains(raw, []byte("Retained frontend tool results are unavailable")) {
				t.Fatalf("unreadable result did not produce a scoped gap: %s", raw)
			}
		default:
			if content || args || bytes.Contains(raw, []byte(frontend.ID)) {
				t.Fatalf("observer received retained frontend tool payload: %s", raw)
			}
		}
	}
	checkArchived("app-a", "result")

	restarted, err := New(f.dir, history)
	if err != nil {
		t.Fatal(err)
	}
	serviceHandler.Store(restarted)
	checkArchived("app-a", "result")
	checkArchived("observe-only", "")
	call("GET", observePath, "app-b", "", 404)
	call("POST", resultPath, "app-a", string(result), 200)
	call("POST", resultPath, "app-a", changedResult, 409)
	call("POST", cancelledResultPath, "app-a", lateResult, 409)
	call("POST", resultPath, "app-b", string(result), 404)
	laterPath := base + "/operations/" + laterState.OperationID
	resumedLater := call("GET", laterPath+"?runId=later-run", "app-a", "", 200)
	rawLater, err := io.ReadAll(resumedLater.Body)
	_ = resumedLater.Body.Close()
	if err != nil || !bytes.Contains(rawLater, []byte("delivery_unknown")) ||
		bytes.Contains(rawLater, []byte(unconfirmed.ID)) || bytes.Contains(rawLater, []byte(frontend.ID)) {
		t.Fatalf("restart replayed unresolved work or mixed tool history between runs: %s, %v", rawLater, err)
	}
	call("POST", laterPath+"/tools/"+unconfirmed.ID+"/result", "app-a",
		fmt.Sprintf(`{"id":"after-restart","role":"tool","toolCallId":%q,"content":"unconfirmed.md"}`, unconfirmed.ID), 404)

	if err := os.WriteFile(savedPath, []byte("unreadable result"), 0600); err != nil {
		t.Fatal(err)
	}
	checkArchived("app-a", "gap")
}

func hostedSnapshot(t *testing.T, scanner *bufio.Scanner) aguiRunState {
	t.Helper()
	for scanner.Scan() {
		line, ok := strings.CutPrefix(scanner.Text(), "data: ")
		if !ok {
			continue
		}
		var event struct {
			Type     string       `json:"type"`
			Snapshot aguiRunState `json:"snapshot"`
		}
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Fatal(err)
		}
		if event.Type == "STATE_SNAPSHOT" {
			return event.Snapshot
		}
	}
	t.Fatalf("missing state snapshot: %v", scanner.Err())
	return aguiRunState{}
}

type hostedRelayFixture struct {
	endpoint    string
	client      *http.Client
	start       func(context.Context) error
	disconnect  context.CancelFunc
	dropReply   atomic.Bool
	readMetrics func() string
}

func newHostedRelay(t *testing.T, handler http.Handler) *hostedRelayFixture {
	t.Helper()
	testTLS := httptest.NewTLSServer(http.NotFoundHandler())
	certificate := testTLS.TLS.Certificates[0]
	roots := x509.NewCertPool()
	roots.AddCert(testTLS.Certificate())
	testTLS.Close()
	proxy, err := relay.New([]relay.Instance{
		{Host: "first.example.com", CertificateSHA256: fmt.Sprintf("%x", sha256.Sum256(certificate.Certificate[0]))},
		{Host: "second.example.com", CertificateSHA256: fmt.Sprintf("%x", [sha256.Size]byte{1})},
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	tunnels, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tunnels.Close() })
	go func() { _ = proxy.Accept(ctx, tunnels, certificate) }()
	public := httptest.NewTLSServer(proxy)
	t.Cleanup(public.Close)
	transport := &http.Transport{
		TLSClientConfig: &tls.Config{RootCAs: roots},
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, public.Listener.Addr().String())
		},
	}
	t.Cleanup(transport.CloseIdleConnections)
	f := &hostedRelayFixture{
		endpoint: "https://first.example.com",
		client:   &http.Client{Transport: transport},
		readMetrics: func() string {
			rec := httptest.NewRecorder()
			proxy.Metrics(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
			return rec.Body.String()
		},
	}
	invalidCtx, cancelInvalid := context.WithTimeout(ctx, time.Second)
	defer cancelInvalid()
	if err := relay.Connect(invalidCtx, tunnels.Addr().String(), &tls.Config{RootCAs: roots}, http.NotFoundHandler()); err == nil || invalidCtx.Err() != nil {
		t.Fatalf("tunnel permitted a connector without a certificate: %v", err)
	}
	f.start = func(ctx context.Context) error {
		ctx, disconnect := context.WithCancel(ctx)
		defer disconnect()
		return relay.Connect(ctx, tunnels.Addr().String(), &tls.Config{
			Certificates: []tls.Certificate{certificate}, RootCAs: roots,
		}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/run") && f.dropReply.Swap(false) {
				handler.ServeHTTP(disconnectOnWrite{w, disconnect, r.Context()}, r)
				return
			}
			handler.ServeHTTP(w, r)
		}))
	}
	return f
}

type disconnectOnWrite struct {
	http.ResponseWriter
	disconnect context.CancelFunc
	ctx        context.Context
}

func (w disconnectOnWrite) Write([]byte) (int, error) {
	w.disconnect()
	<-w.ctx.Done()
	return 0, net.ErrClosed
}

func (w disconnectOnWrite) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (f *hostedRelayFixture) connect(t *testing.T, path string) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	f.disconnect = cancel
	t.Cleanup(cancel)
	done := make(chan error, 1)
	go func() { done <- f.start(ctx) }()
	f.wait(t, path, http.StatusOK)
	select {
	case err := <-done:
		t.Fatalf("connector ended during startup: %v", err)
	default:
	}
	req, err := http.NewRequest(http.MethodGet, "https://second.example.com"+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer app-a")
	res, err := f.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("one host certificate routed another instance: %s", res.Status)
	}
	req, err = http.NewRequest(http.MethodGet, "https://second.example.com"+path, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Host = "first.example.com"
	req.Header.Set("Authorization", "Bearer app-a")
	res, err = f.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusMisdirectedRequest {
		t.Fatalf("HTTP authority overrode tunnel TLS routing: %s", res.Status)
	}
	_, _ = io.Copy(io.Discard, res.Body)
}

func (f *hostedRelayFixture) wait(t *testing.T, path string, want int) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	for ctx.Err() == nil {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, f.endpoint+path, nil)
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Authorization", "Bearer app-a")
		resp, err := f.client.Do(req)
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode == want {
				return
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("relay never returned %d", want)
}

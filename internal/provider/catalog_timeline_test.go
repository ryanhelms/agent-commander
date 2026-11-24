package provider

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"agentcommander/internal/catalog"
	"agentcommander/internal/catalog/testfixture"
	"agentcommander/internal/localapi"
	"agentcommander/internal/service"
)

func TestCatalogUpdateKeepsLiveWorkersOnTheirLaunchVersions(t *testing.T) {
	if os.Getenv("AGENT_COMMANDER_TEST_TMUX") != "1" {
		t.Skip("set AGENT_COMMANDER_TEST_TMUX=1 for isolated tmux sessions")
	}
	if _, err := executablePath("tmux", "AGENT_COMMANDER_TMUX"); err != nil {
		t.Skip(err)
	}
	for _, distribution := range []string{"binary", "npm", "python"} {
		t.Run(distribution, func(t *testing.T) {
			testCatalogWorkerTimeline(t, distribution)
		})
	}
}

func testCatalogWorkerTimeline(t *testing.T, distribution string) {
	t.Helper()
	if distribution != "python" {
		node, err := executablePath("node", "AGENT_COMMANDER_NODE")
		if err != nil {
			t.Skip(err)
		}
		t.Setenv("PATH", filepath.Dir(node)+string(os.PathListSeparator)+os.Getenv("PATH"))
	}
	if distribution != "binary" {
		installer := distribution
		if installer == "python" {
			installer = "python3"
		}
		if _, err := exec.LookPath(installer); err != nil {
			t.Skip(err)
		}
	}
	dir, err := os.MkdirTemp("/tmp", "ac-catalog-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	t.Setenv("TMUX_TMPDIR", dir)

	type publication struct {
		registry  []byte
		entry     []byte
		signature []byte
	}
	var published atomic.Pointer[publication]
	var badSignature atomic.Bool
	var updateDownloads atomic.Int64
	artifacts := make(map[string][]byte)
	command, suffix := "./adapter", ""
	for _, version := range []string{"1.0.0", "2.0.0"} {
		script := strings.ReplaceAll(catalogTimelineAdapter, "FIXTURE_VERSION", version)
		switch distribution {
		case "binary":
			artifacts[version] = []byte(script)
		case "npm":
			artifacts[version], command = testfixture.NPM(t, version, script)
			suffix = ".zip"
		case "python":
			artifacts[version], command = testfixture.Python(t, version, strings.ReplaceAll(catalogTimelinePython, "FIXTURE_VERSION", version))
			suffix = ".zip"
		}
	}
	registry := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/registry":
			_, _ = w.Write(published.Load().registry)
		case "/publisher/entry":
			_, _ = w.Write(published.Load().entry)
		case "/publisher/signature":
			signature := published.Load().signature
			if badSignature.Load() {
				signature = make([]byte, ed25519.SignatureSize)
			}
			_, _ = w.Write(signature)
		case "/2.0.0" + suffix:
			updateDownloads.Add(1)
			fallthrough
		case "/1.0.0" + suffix:
			_, _ = w.Write(artifacts[strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/"), suffix)])
		default:
			http.NotFound(w, r)
		}
	}))
	defer registry.Close()
	// Trust only this test registry through the HTTP client's default transport.
	transport := http.DefaultTransport
	http.DefaultTransport = registry.Client().Transport
	defer func() { http.DefaultTransport = transport }()
	key, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(key)
	if err != nil {
		t.Fatal(err)
	}
	publicKey := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})
	publish := func(version string) catalog.BinaryProof {
		t.Helper()
		binary := catalog.Binary{Archive: registry.URL + "/" + version + suffix, Command: command,
			SHA256: fmt.Sprintf("%x", sha256.Sum256(artifacts[version]))}
		entry := catalog.Agent{ID: "fixture", Name: "Fixture", Version: version, Distribution: catalog.Distribution{
			Binary: map[string]catalog.Binary{
				"darwin-aarch64": binary, "darwin-x86_64": binary,
				"linux-aarch64": binary, "linux-x86_64": binary,
			},
		}}
		switch distribution {
		case "npm":
			entry.Distribution.NPX = &catalog.Package{Package: "fixture@" + version}
		case "python":
			entry.Distribution.UVX = &catalog.Package{Package: "fixture==" + version}
		}
		body, err := json.Marshal(catalog.Snapshot{Version: "1.0.0", Agents: []catalog.Agent{entry}})
		if err != nil {
			t.Fatal(err)
		}
		manifest, err := json.Marshal(entry)
		if err != nil {
			t.Fatal(err)
		}
		signature := ed25519.Sign(private, manifest)
		published.Store(&publication{registry: body, entry: manifest, signature: signature})
		return catalog.BinaryProof{Manifest: manifest, Signature: signature, PublicKey: publicKey}
	}
	activate := func(staged catalog.StagedBinary) {
		t.Helper()
		if _, err := catalog.Activate(t.Context(), dir, filepath.Base(staged.Directory), staged.PublisherKeySHA256); err != nil {
			t.Fatal(err)
		}
	}
	proof := publish("1.0.0")
	snapshot, err := catalog.Read(t.Context(), registry.URL+"/registry")
	if err != nil {
		t.Fatal(err)
	}
	stageDir := filepath.Join(dir, "catalog", "staged")
	var initial catalog.StagedBinary
	if distribution == "binary" {
		initial, err = catalog.StageBinary(t.Context(), stageDir, snapshot, "fixture", "1.0.0", proof)
	} else {
		initial, err = catalog.StagePackage(t.Context(), stageDir, snapshot, "fixture", "1.0.0", distribution, proof)
	}
	if err != nil {
		t.Fatal(err)
	}
	activate(initial)
	if err := catalog.SetUpdateSource(t.Context(), dir, "fixture", registry.URL+"/publisher/entry", registry.URL+"/publisher/signature", publicKey); err != nil {
		t.Fatal(err)
	}
	if update, err := catalog.Refresh(t.Context(), dir, "fixture"); err != nil || update != nil {
		t.Fatalf("refresh should skip the active version: %+v, %v", update, err)
	}

	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(dir, "api.sock")
	local, err := New(dir, socket, executable)
	if err != nil {
		t.Fatal(err)
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
	request := func(method, path string, body, result any) {
		t.Helper()
		if err := client.request(method, path, body, result); err != nil {
			t.Fatal(err)
		}
	}
	request("POST", "/v1/runs", map[string]string{"path": dir, "task": "Coordinator", "client": "fixture"}, &run)
	path := "/v1/runs/" + run.ID
	stop := func(id string) {
		t.Cleanup(func() { _ = local.Stop(context.Background(), id) })
	}
	stop(run.CoordinatorID)
	start := func(name, version string) (service.Worker, string) {
		t.Helper()
		var worker service.Worker
		request("POST", path+"/workers", map[string]string{"name": name, "task": name, "client": "fixture"}, &worker)
		stop(worker.ID)
		for deadline := time.Now().Add(8 * time.Second); time.Now().Before(deadline); time.Sleep(25 * time.Millisecond) {
			request("GET", path, nil, &run)
			for _, item := range run.Workers {
				if item.ID == worker.ID && item.State == "failed" {
					t.Fatalf("%s failed: %s\n%s", name, item.Error, item.Output)
				}
			}
			for _, question := range run.Requests {
				if question.WorkerID == worker.ID && question.Status == "pending" {
					title, _, _ := strings.Cut(question.Question, "\n")
					if title != "Fixture "+version {
						t.Fatalf("%s launched a different version: %s", name, question.Question)
					}
					return worker, question.ID
				}
			}
		}
		t.Fatalf("%s did not reach its addressed approval", name)
		return service.Worker{}, ""
	}

	first, firstQuestion := start("first", "1.0.0")
	publish("2.0.0")
	badSignature.Store(true)
	if update, err := catalog.Refresh(t.Context(), dir, "fixture"); err == nil || update != nil || updateDownloads.Load() != 0 {
		t.Fatalf("unverified update reached the archive or returned a notice: %+v, %v", update, err)
	}
	badSignature.Store(false)
	type refreshResult struct {
		update *catalog.Update
		err    error
	}
	retry := make(chan refreshResult, 1)
	go func() {
		update, err := catalog.Refresh(t.Context(), dir, "fixture")
		retry <- refreshResult{update: update, err: err}
	}()
	update, err := catalog.Refresh(t.Context(), dir, "fixture")
	again := <-retry
	if err != nil || update == nil || update.Version != "2.0.0" || updateDownloads.Load() != 1 {
		t.Fatalf("refresh did not stage the verified update: %+v, %v", update, err)
	}
	if again.err != nil || again.update == nil || again.update.Stage != update.Stage {
		t.Fatalf("concurrent refresh did not reuse the verified archive: %+v, %v", again.update, again.err)
	}
	notices, err := catalog.Updates(dir)
	if err != nil || len(notices) != 1 || notices[0].Stage != update.Stage {
		t.Fatalf("missing verified update notice: %+v, %v", notices, err)
	}
	activate(update.StagedBinary)
	second, secondQuestion := start("second", "2.0.0")
	if _, err := catalog.Rollback(t.Context(), dir, "fixture"); err != nil {
		t.Fatal(err)
	}
	afterRollback, err := catalog.Refresh(t.Context(), dir, "fixture")
	if err != nil || afterRollback == nil || afterRollback.Stage != update.Stage {
		t.Fatalf("rollback lost the configured update source: %+v, %v", afterRollback, err)
	}
	third, thirdQuestion := start("third", "1.0.0")
	for _, question := range []string{firstQuestion, secondQuestion, thirdQuestion} {
		request("POST", "/v1/requests/"+question+"/reply", map[string]string{"answer": "once"}, nil)
	}
	for _, target := range []struct {
		id, version string
	}{{first.ID, "1.0.0"}, {second.ID, "2.0.0"}, {third.ID, "1.0.0"}} {
		completed := false
		for deadline := time.Now().Add(8 * time.Second); !completed && time.Now().Before(deadline); time.Sleep(25 * time.Millisecond) {
			request("GET", path, nil, &run)
			for _, worker := range run.Workers {
				if worker.ID == target.id && worker.State == "completed" {
					if !strings.Contains(worker.Output, "Approved in "+target.version) {
						t.Fatalf("worker %s completed on a different version: %s", worker.Name, worker.Output)
					}
					completed = true
				}
			}
		}
		if !completed {
			t.Fatalf("worker %s did not finish after its addressed approval", target.id)
		}
	}
}

const catalogTimelineAdapter = `#!/usr/bin/env node
const readline = require('node:readline');
const version = 'FIXTURE_VERSION';
const sessionId = 'catalog-fixture-' + process.pid;
let prompt;
const send = fields => console.log(JSON.stringify({jsonrpc: '2.0', ...fields}));
const result = (id, body) => send({id, result: body});
readline.createInterface({input: process.stdin}).on('line', line => {
  const frame = JSON.parse(line);
  switch (frame.method) {
    case 'initialize':
      result(frame.id, {protocolVersion: 1});
      break;
    case 'session/new':
      result(frame.id, {sessionId});
      break;
    case 'session/prompt':
      prompt = frame.id;
      send({id: 'approval', method: 'session/request_permission', params: {
        sessionId, toolCall: {toolCallId: 'read', title: 'Fixture ' + version},
        options: [{optionId: 'once', name: 'Allow once', kind: 'allow_once'}]
      }});
      break;
    default:
      if (frame.id === 'approval' && frame.result?.outcome?.optionId === 'once') {
        send({method: 'session/update', params: {sessionId, update: {
          sessionUpdate: 'agent_message_chunk', content: {type: 'text', text: 'Approved in ' + version}
        }}});
        result(prompt, {stopReason: 'end_turn'});
      }
  }
});
`

const catalogTimelinePython = `import json
import os
import sys

def send(**frame):
    print(json.dumps({"jsonrpc": "2.0", **frame}), flush=True)

def main():
    version = "FIXTURE_VERSION"
    session = "catalog-fixture-" + str(os.getpid())
    for line in sys.stdin:
        frame = json.loads(line)
        method = frame.get("method")
        if method == "initialize":
            send(id=frame["id"], result={"protocolVersion": 1})
        elif method == "session/new":
            send(id=frame["id"], result={"sessionId": session})
        elif method == "session/prompt":
            prompt = frame["id"]
            send(id="approval", method="session/request_permission", params={
                "sessionId": session,
                "toolCall": {"toolCallId": "read", "title": "Fixture " + version},
                "options": [{"optionId": "once", "name": "Allow once", "kind": "allow_once"}],
            })
        elif frame.get("id") == "approval" and frame["result"]["outcome"]["optionId"] == "once":
            send(method="session/update", params={"sessionId": session, "update": {
                "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Approved in " + version},
            }})
            send(id=prompt, result={"stopReason": "end_turn"})
`

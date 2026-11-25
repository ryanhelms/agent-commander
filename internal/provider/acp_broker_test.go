package provider

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"agentcommander/internal/localapi"
	"agentcommander/internal/service"
)

func TestACPBrokerSharesOneAdapterAcrossManagedTmuxWorkers(t *testing.T) {
	if os.Getenv("AGENT_COMMANDER_TEST_TMUX") != "1" {
		t.Skip("set AGENT_COMMANDER_TEST_TMUX=1 for real isolated tmux runners")
	}
	node, err := executablePath("node", "AGENT_COMMANDER_NODE")
	if err != nil {
		t.Skip(err)
	}
	if _, err := TmuxExecutable(); err != nil {
		t.Skip(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{"off", "prewarm", "share"} {
		t.Run(mode, func(t *testing.T) {
			dir, err := os.MkdirTemp("/tmp", "ac-broker-test-")
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = os.RemoveAll(dir) })
			t.Setenv("TMUX_TMPDIR", dir)
			script := filepath.Join(dir, "adapter.mjs")
			if err := os.WriteFile(script, []byte(brokerFixtureSource), 0600); err != nil {
				t.Fatal(err)
			}
			starts := filepath.Join(dir, "starts")
			profiles := map[string]acpProfile{"fixture": {Command: node, Args: []string{script, filepath.Base(starts)}, OmitCommanderMCP: true}}
			body, err := json.Marshal(profiles)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, "acp-profiles.json"), body, 0600); err != nil {
				t.Fatal(err)
			}

			socket := filepath.Join(dir, "api.sock")
			local, err := New(dir, socket, executable)
			if err != nil {
				t.Fatal(err)
			}
			stopBroker, err := local.EnableACPBroker(t.Context(), mode)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(stopBroker)
			handler, err := service.New(dir, local)
			if err != nil {
				t.Fatal(err)
			}
			listener, err := net.Listen("unix", socket)
			if err != nil {
				t.Fatal(err)
			}
			server := &http.Server{Handler: handler}
			go func() { _ = server.Serve(listener) }()
			t.Cleanup(func() { _ = server.Close() })
			client := &api{localapi.New(socket, "")}
			var run service.Run
			if err := client.request("POST", "/v1/runs", map[string]string{"path": dir, "task": "coordinator", "client": "fixture"}, &run); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = local.Stop(context.Background(), run.CoordinatorID) })
			workerIDs := make([]string, 0, 2)
			startedAt := time.Now()
			for _, task := range []string{"fixture-alpha", "fixture-beta"} {
				var worker service.Worker
				if err := client.request("POST", "/v1/runs/"+run.ID+"/workers", map[string]string{"name": task, "task": task}, &worker); err != nil {
					t.Fatal(err)
				}
				id := worker.ID
				t.Cleanup(func() { _ = local.Stop(context.Background(), id) })
				workerIDs = append(workerIDs, id)
			}
			workers := waitForBrokerFixtureWorkers(t, client, run.ID, workerIDs)
			for i, worker := range workers {
				wanted := []string{"fixture-alpha", "fixture-beta"}[i]
				if worker.NativeSession == nil || !strings.Contains(worker.Output, "Peer delivered "+wanted) ||
					strings.Contains(worker.Output, []string{"fixture-beta", "fixture-alpha"}[i]) {
					t.Fatalf("worker did not retain its own peer output: %+v", worker)
				}
			}
			if workers[0].NativeSession.SessionID == workers[1].NativeSession.SessionID {
				t.Fatal("worker sessions shared a native ID")
			}
			data, err := os.ReadFile(starts)
			if err != nil {
				t.Fatal(err)
			}
			sessions := strings.Fields(string(data))
			numProcesses := 3
			if mode == "share" {
				numProcesses = 2 // The coordinator and worker roles use independent peers.
			}
			if len(sessions) != numProcesses {
				t.Fatalf("mode %s started %d physical adapters, want %d: %v", mode, len(sessions), numProcesses, sessions)
			}
			delivered := time.Since(startedAt)
			rss, err := exec.Command("ps", "-o", "rss=", "-p", strings.Join(sessions, ",")).Output()
			if err != nil {
				t.Fatal(err)
			}
			totalRSS := 0
			for _, sample := range strings.Fields(string(rss)) {
				kibibytes, err := strconv.Atoi(sample)
				if err != nil {
					t.Fatal(err)
				}
				totalRSS += kibibytes
			}
			t.Logf("%s started %d adapters at %.2f MiB sampled adapter RSS and delivered two real tmux worker prompts in %s",
				mode, len(sessions), float64(totalRSS)/1024, delivered)
		})
	}
}

func waitForBrokerFixtureWorkers(t *testing.T, client *api, runID string, ids []string) []*service.Worker {
	t.Helper()
	var run service.Run
	for deadline := time.Now().Add(12 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		if err := client.request("GET", "/v1/runs/"+runID, nil, &run); err != nil {
			t.Fatal(err)
		}
		list := make([]*service.Worker, 0, len(ids))
		for _, id := range ids {
			for _, w := range run.Workers {
				if w.ID != id {
					continue
				}
				if w.State == "failed" {
					t.Fatalf("tmux runner failed: %s\n%s", w.Error, w.Output)
				}
				if w.State == "completed" {
					list = append(list, w)
				}
			}
		}
		if len(list) == len(ids) {
			return list
		}
	}
	for _, w := range run.Workers {
		t.Logf("worker %s state=%s output=%s", w.ID, w.State, w.Output)
	}
	t.Fatalf("ACP workers of run %s did not complete", runID)
	return nil
}

const brokerFixtureSource = `
import fs from 'node:fs'
import {createInterface} from 'node:readline'
fs.appendFileSync(process.argv[2], process.pid + '\n')
const write = result => console.log(JSON.stringify({jsonrpc:'2.0', ...result}))
const active = new Set()
let opens = 0
for await (const line of createInterface({input:process.stdin})) {
  const call = JSON.parse(line)
  switch(call.method) {
    case 'initialize':
      write({id:call.id,result:{protocolVersion:1,agentCapabilities:{sessionCapabilities:{close:{}}}}})
      break
    case 'session/new': {
      const sessionId = process.pid + ':' + (++opens)
      active.add(sessionId)
      write({id:call.id,result:{sessionId}})
      break
    }
    case 'session/prompt': {
      const {sessionId,prompt} = call.params
      if (!active.has(sessionId)) process.exit(2)
      if (prompt[0].text === 'coordinator') continue
      write({method:'session/update',params:{sessionId,update:{sessionUpdate:'agent_message_chunk',
        content:{type:'text',text:'Peer delivered ' + prompt[0].text + '\n'}}}})
      write({id:call.id,result:{stopReason:'end_turn'}})
      break
    }
    case 'session/close':
      active.delete(call.params.sessionId)
      write({id:call.id,result:{}})
      break
    default:
      write({id:call.id,error:{code:-32601,message:'unavailable'}})
  }
}
`

package provider

import (
	"agentcommander/internal/localapi"
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	agentacp "agent-acp.local/sdks/go"
	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"
	"agentcommander/internal/service"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

func TestCommanderParamsPeer(t *testing.T) {
	if os.Getenv("COMMANDER_PARAMS_FIXTURE") != "1" {
		return
	}
	enc := json.NewEncoder(os.Stdout)
	send := func(m map[string]any) {
		m["jsonrpc"] = "2.0"
		if enc.Encode(m) != nil {
			os.Exit(3)
		}
	}
	update := func(id, secret string, inner any, extra any) {
		send(map[string]any{"method": "session/update", "params": map[string]any{"sessionId": id, "update": inner, "_meta": map[string]any{"trace": secret, "nullable": nil}, "future": extra}})
	}
	chunk := func(role, text string) any {
		return map[string]any{"sessionUpdate": role + "_message_chunk", "messageId": "m-" + text, "content": map[string]string{"type": "text", "text": text}}
	}
	in := bufio.NewScanner(os.Stdin)
	for in.Scan() {
		var req struct {
			Method string
			ID     json.RawMessage
		}
		if json.Unmarshal(in.Bytes(), &req) != nil {
			os.Exit(2)
		}
		result := func(body any) { send(map[string]any{"id": req.ID, "result": body}) }
		switch req.Method {
		case "initialize":
			result(map[string]any{"protocolVersion": 1, "agentCapabilities": map[string]any{}})
		case "session/new":
			result(map[string]any{"sessionId": "selected"})
			for n := 0; n < 400; n++ {
				if _, err := os.Stat(os.Getenv("COMMANDER_PARAMS_READY")); err == nil {
					break
				}
				time.Sleep(5 * time.Millisecond)
			}
			update("foreign", "WRONG-OUTER", chunk("user", "WRONG-TEXT"), nil)
			update("selected", "PRIVATE-IDLE", chunk("user", "idle-before"), nil)
		case "session/prompt":
			update("selected", "PRIVATE-ACTIVE", chunk("agent", "reply"), json.Number("9007199254740993"))
			update("selected", "PRIVATE-ECHO", chunk("user", "peer-user"), true)
			update("selected", "PRIVATE-TOOL", map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": "call-1", "title": "Read", "status": "completed", "content": []any{map[string]any{"type": "content", "content": map[string]any{"type": "text", "text": "result"}}}}, false)
			update("selected", "PRIVATE-PASSIVE", nil, nil)
			update("selected", "PRIVATE-LARGE", chunk("agent", "small-preview"), strings.Repeat("x", service.MaxLiveSourceRecord))
			result(map[string]any{"stopReason": "end_turn"})
			update("selected", "PRIVATE-AFTER", chunk("agent", "idle-after"), nil)
			if closeAfter := os.Getenv("COMMANDER_PARAMS_CLOSE_AFTER"); closeAfter != "" {
				// This fixture closes an idle connection. EOF while the transport
				// still delivers earlier notifications is a different outcome.
				for deadline := time.Now().Add(12 * time.Second); time.Now().Before(deadline); {
					if _, err := os.Stat(closeAfter); err == nil {
						os.Exit(0)
					} else if !os.IsNotExist(err) {
						break
					}
					time.Sleep(5 * time.Millisecond)
				}
				os.Exit(4)
			}
		}
	}
	os.Exit(0)
}

func TestEnrichedCommanderWorkerLifecycle(t *testing.T) {
	for _, wire := range []bool{true, false} {
		t.Run(fmt.Sprintf("callback-%t", wire), func(t *testing.T) {
			p := newACPSourcePublisher()
			p.portable = !wire
			ready := filepath.Join(t.TempDir(), "ready")
			cfg := runtime.Config{HarnessInstance: "fixture", WorkingDirectory: t.TempDir(), Command: os.Args[0], Args: []string{"-test.run=^TestCommanderParamsPeer$"}, Env: map[string]string{"COMMANDER_PARAMS_FIXTURE": "1", "COMMANDER_PARAMS_READY": ready}}
			if wire {
				cfg.OnACPUpdate = p.capture
			} else {
				cfg.Env["COMMANDER_PARAMS_CLOSE_AFTER"] = ready + ".drained"
			}
			rt, err := runtime.New(cfg)
			if err != nil {
				t.Fatal(err)
			}
			defer rt.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
			defer cancel()
			c := agentacp.New(rt)
			opened, err := c.Open(ctx, &model.OpenRequest{HarnessInstance: "fixture"})
			if err != nil {
				t.Fatal(err)
			}
			ref := opened.Session.Ref
			p.queue.bind(service.NativeSession{HarnessInstance: "fixture", SessionID: "selected"})
			scr := &screen{}
			watch, stop := context.WithCancel(ctx)
			updates, done, life := workerObservations(watch, c, ref, p, scr)
			defer func() { stop(); <-done }()
			if err := os.WriteFile(ready, []byte("ready"), 0600); err != nil {
				t.Fatal(err)
			}
			wait := func(text string) {
				t.Helper()
				for {
					scr.mu.Lock()
					hit := false
					for _, event := range scr.events {
						if event.Text == text {
							hit = true
							break
						}
					}
					scr.mu.Unlock()
					if hit {
						return
					}
					select {
					case <-ctx.Done():
						t.Fatal("idle event never appeared", text)
					case <-time.After(5 * time.Millisecond):
					}
				}
			}
			wait("idle-before")
			req := &model.SendRequest{Session: ref, OperationId: "one", Text: "go"}
			state, err := runACPTurn(ctx, c, req, p, nil, scr, "", false, opened.Session.Capabilities, updates)
			if state != "completed" || err != nil {
				t.Fatal(state, err)
			}
			wait("idle-after")
			if !wire {
				if err := os.WriteFile(cfg.Env["COMMANDER_PARAMS_CLOSE_AFTER"], nil, 0600); err != nil {
					t.Fatal(err)
				}
				select {
				case <-life.Done():
				case <-ctx.Done():
					t.Fatal("idle EOF failed to end stream")
				}
				if context.Cause(life) != errACPDisconnected {
					t.Fatalf("incorrect disconnect cause: %v", context.Cause(life))
				}
				if _, ok := waitForFollowUp(life, nil, "/v1/workers/fixture"); ok {
					t.Fatal("claimed after disconnect")
				}
			}
			stop()
			<-done
			p.queue.close()
			pages := map[string]*model.Observation{}
			for {
				batch := p.queue.get(nil)
				if len(batch) == 0 {
					break
				}
				for _, u := range batch {
					if len(u.Observation) == 0 {
						continue
					}
					var o model.Observation
					if err := protojson.Unmarshal(u.Observation, &o); err != nil {
						t.Fatal(err)
					}
					if ext := paramsSource(&o); ext != nil {
						if pages[u.Cursor] != nil || o.GetSourceCursor() != u.Cursor || o.Session.SessionId != "selected" {
							t.Fatal("duplicate or crossed source")
						}
						if bytes.Contains(ext.Data, []byte("WRONG")) {
							t.Fatal("foreign payload retained")
						}
						pages[u.Cursor] = &o
					}
				}
			}
			if len(pages) != 7 {
				t.Fatalf("got %d distinct rich cursors", len(pages))
			}
			events := map[string]string{"idle-before": "user", "peer-user": "user", "reply": "text", "result": "tool_result", "small-preview": "text", "idle-after": "text"}
			seen := map[string]bool{}
			for _, event := range scr.events {
				raw, _ := json.Marshal(event)
				if bytes.Contains(raw, []byte("PRIVATE")) || bytes.Contains(raw, []byte("WRONG")) {
					t.Fatal("scoped data entered preview")
				}
				kind, known := events[event.Text]
				if !known {
					continue
				}
				if seen[event.Text] || event.Kind != kind || event.ACP == nil || pages[event.ACP.Cursor] == nil {
					t.Fatalf("incorrect projection %+v", event)
				}
				seen[event.Text] = true
				if event.Text == "reply" && event.ACP.MessageID != "m-reply" {
					t.Fatal("lost rich message ID")
				}
				if event.Text == "small-preview" {
					ext := paramsSource(pages[event.ACP.Cursor])
					if ext.GetType() != "acp.source_omitted" || !bytes.Contains(ext.Data, []byte("commander_live_record_limit")) || len(ext.Data) > 220 {
						t.Fatal("missing precise size gap")
					}
				}
			}
			if len(seen) != len(events) {
				t.Fatal("missing fixture projection", seen)
			}
		})
	}
}

func TestIdlePortableSignalAndStreamFailure(t *testing.T) {
	for _, how := range []string{"gap", "cancel"} {
		t.Run(how, func(t *testing.T) {
			cwd := t.TempDir()
			rt, err := compiledFixture.Open(runtime.Config{HarnessInstance: compiledFixtureInstance, WorkingDirectory: cwd})
			if err != nil {
				t.Fatal(err)
			}
			defer rt.Close()
			c := agentacp.New(rt)
			ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
			defer cancel()
			opened, err := c.Open(ctx, &model.OpenRequest{HarnessInstance: compiledFixtureInstance, WorkingDirectory: cwd})
			if err != nil {
				t.Fatal(err)
			}
			ref := opened.Session.Ref
			p := newACPSourcePublisher()
			p.portable = true
			scr := &screen{}
			watch, stop := context.WithCancel(ctx)
			defer stop()
			_, done, life := workerObservations(watch, c, ref, p, scr)
			direct := rt.(*fixtureRuntime)
			direct.mu.Lock()
			s := direct.sessions[ref.SessionId]
			// A hybrid runtime supplied the ordinary source through its wire callback.
			p.capture(runtime.ACPUpdate{Session: ref, Cursor: ref.SessionId + "/1", Body: json.RawMessage(`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"wire-only"}}`)})
			s.say(model.Speaker_SPEAKER_ASSISTANT, "wire-only")
			s.say(model.Speaker_SPEAKER_ASSISTANT, "bare text")
			s.append(&model.Observation{Event: &model.Observation_Tool{Tool: &model.ToolActivity{CallId: "id", Name: "read", Phase: "completed", Summary: "bare tool"}}})
			s.append(&model.Observation{Event: &model.Observation_Extension{Extension: &model.Extension{Type: "notice", MediaType: "application/json", Data: []byte(`{"sessionUpdate":"notice","title":"bare notice"}`)}}})
			s.append(&model.Observation{Event: &model.Observation_Extension{Extension: &model.Extension{Type: "acp.permission_request", MediaType: "application/json", Data: []byte(`{"secret":"NO-PREVIEW"}`)}}})
			direct.mu.Unlock()
			for {
				scr.mu.Lock()
				n := len(scr.events)
				scr.mu.Unlock()
				if n >= 4 {
					break
				}
				select {
				case <-ctx.Done():
					t.Fatal("missed bare portable events")
				case <-time.After(time.Millisecond):
				}
			}
			if how == "gap" {
				direct.mu.Lock()
				s.append(&model.Observation{Event: &model.Observation_Gap{Gap: &model.HistoryGap{Reason: "window expired"}}})
				direct.mu.Unlock()
			} else {
				stop()
			}
			select {
			case <-done:
			case <-ctx.Done():
				t.Fatal("observer did not stop")
			}
			if life.Err() == nil {
				t.Fatal("standby control still allowed claims")
			}
			data, _ := json.Marshal(scr.events)
			if bytes.Contains(data, []byte("NO-PREVIEW")) || bytes.Contains(data, []byte("wire-only")) || !bytes.Contains(data, []byte("bare notice")) || !bytes.Contains(data, []byte("Permission request without an available choice")) {
				t.Fatalf("invalid idle signal: %s", data)
			}
			if (how == "gap") != bytes.Contains(data, []byte("observations expired")) {
				t.Fatal("incorrect visible gap or cancellation", how)
			}
		})
	}
}

func TestIdleDisconnectPreventsFollowUpClaim(t *testing.T) {
	dir, err := os.MkdirTemp("", "params-net-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	socket := filepath.Join(dir, "s")
	ln, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	waiting, release := make(chan struct{}), make(chan struct{})
	var claims atomic.Int32
	server := http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "GET" {
			close(waiting)
			<-release
			fmt.Fprint(w, `{"live":true,"next_message_id":"queued"}`)
			return
		}
		claims.Add(1)
		fmt.Fprint(w, `{"id":"queued","text":"work"}`)
	})}
	go server.Serve(ln)
	defer server.Close()
	live, stop := context.WithCancelCause(ctx)
	finished := make(chan bool, 1)
	go func() {
		_, ok := waitForFollowUp(live, &api{client: localapi.New(socket, "")}, "/v1/workers/fixture")
		finished <- ok
	}()
	select {
	case <-waiting:
	case <-ctx.Done():
		t.Fatal("control request absent")
	}
	stop(errACPDisconnected)
	close(release)
	select {
	case claimed := <-finished:
		if claimed || claims.Load() != 0 {
			t.Fatal("claimed work after known disconnect")
		}
	case <-ctx.Done():
		t.Fatal("follow-up poll ignored disconnect")
	}
}

func TestUpdateParamsNeverDisplaysDifferentlyCasedOuterFields(t *testing.T) {
	private := `{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"PRIVATE-OUTER"}}`
	public := `{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"public"}}`
	for _, tc := range []struct{ rest, kind, text string }{
		{`"update":` + public + `,"Update":` + private, "user", "public"},
		{`"Update":` + private + `,"update":` + public, "user", "public"},
		{`"Update":` + private, "output", ""},
		{`"UPDATE":` + private + `,"update":null`, "output", ""},
	} {
		ext := &model.Extension{Type: runtime.ACPUpdateParamsSource, MediaType: "application/json", Data: []byte(`{"sessionId":"selected",` + tc.rest + `}`)}
		obs := &model.Observation{Session: &model.SessionRef{HarnessInstance: "h", SessionId: "selected"}, Cursor: "c", Event: &model.Observation_Extension{Extension: ext}}
		got := acpExtensionEvent(obs, "live")
		if got.Kind != tc.kind || tc.text != "" && got.Text != tc.text || strings.Contains(got.Text, "PRIVATE") {
			t.Fatalf("exposed a private outer sibling or lost the exact inner update: %+v", got)
		}
	}
}

func TestWorkerGapPreservesItsPrivateOriginalWhileActiveAndIdle(t *testing.T) {
	for _, tc := range []struct {
		name, turn, cursor string
		portable           bool
	}{{"idle-no-cursor", "", "", true}, {"active-with-cursor", "current", "sdk-gap", false}} {
		t.Run(tc.name, func(t *testing.T) {
			cwd := t.TempDir()
			rt, err := compiledFixture.Open(runtime.Config{HarnessInstance: compiledFixtureInstance, WorkingDirectory: cwd})
			if err != nil {
				t.Fatal(err)
			}
			defer rt.Close()
			c := agentacp.New(rt)
			ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
			defer cancel()
			opened, err := c.Open(ctx, &model.OpenRequest{HarnessInstance: compiledFixtureInstance, WorkingDirectory: cwd})
			if err != nil {
				t.Fatal(err)
			}
			ref := opened.Session.Ref
			p := newACPSourcePublisher()
			p.portable = tc.portable
			p.queue.bind(service.NativeSession{HarnessInstance: ref.HarnessInstance, SessionID: ref.SessionId})
			scr := &screen{}
			updates, done, life := workerObservations(ctx, c, ref, p, scr)
			original := &model.Observation{Session: ref, TurnId: tc.turn, Cursor: tc.cursor, SourceCursor: proto.String("provider-source"), SourceRecord: &model.Extension{Type: "provider/private-gap-evidence", MediaType: "application/json", Data: []byte(`{"hidden":"PRIVATE-FIELD"}`)}, Event: &model.Observation_Gap{Gap: &model.HistoryGap{Reason: "PRIVATE-GAP-REASON"}}}
			direct := rt.(*fixtureRuntime)
			direct.mu.Lock()
			s := direct.sessions[ref.SessionId]
			s.events = append(s.events, original)
			close(s.changed)
			s.changed = make(chan struct{})
			direct.mu.Unlock()
			select {
			case <-done:
			case <-ctx.Done():
				t.Fatal("gap failed to stop observer")
			}
			if context.Cause(life) != errACPObservationGap {
				t.Fatal("lost gap boundary cause", context.Cause(life))
			}
			first := <-updates
			if first.err != errACPObservationGap {
				t.Fatal("active consumer did not receive gap terminal state")
			}
			if len(scr.events) != 1 || scr.events[0].ACP == nil {
				t.Fatal("missing linked gap preview", scr.events)
			}
			public, _ := json.Marshal(scr.events)
			if bytes.Contains(public, []byte("PRIVATE")) {
				t.Fatal("private gap details reached public screen")
			}
			p.queue.close()
			batch := p.queue.get(nil)
			if len(batch) != 1 || batch[0].Cursor != scr.events[0].ACP.Cursor || !strings.HasPrefix(batch[0].Cursor, "gap-") || batch[0].Kind != service.LiveObservationKind {
				t.Fatal("ambiguous or absent gap source")
			}
			var got model.Observation
			if err := protojson.Unmarshal(batch[0].Body, &got); err != nil || !proto.Equal(&got, original) {
				t.Fatal("scoped source changed the original gap", err)
			}
		})
	}
}

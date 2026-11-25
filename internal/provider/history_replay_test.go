package provider

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	model "agent-acp.local/sdks/go/model"
	"agentcommander/internal/service"
	"google.golang.org/protobuf/encoding/protojson"
)

func TestStoppedReplaySharesOneUnpacedLoadAcrossHistoryConsumers(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	cwd := t.TempDir()
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(cwd, "adapter-shim")
	if err := os.Symlink(binary, alias); err != nil {
		t.Fatal(err)
	}
	t.Setenv("COMMANDER_TEST_REPLAY_PEER", "1")
	configured := acpProfile{
		Command: alias, Args: []string{"-test.run=^TestStoppedReplayPeer$"},
		History: &acpHistory{Format: acpReplayHistory},
	}
	launched := configured
	launched.Command, err = launched.executable()
	if err != nil {
		t.Fatal(err)
	}
	ref := service.NativeSession{HarnessInstance: launched.instance("test"), SessionID: "saved"}
	local := &Local{acpProfiles: map[string]acpProfile{"test": configured}, replaySlot: make(chan struct{}, 1)}
	type previewResult struct {
		rows []service.ConsoleEvent
		err  error
	}
	projected := make(chan previewResult, 1)
	go func() {
		rows, err := local.ReadConsoleHistory(ctx, ref, cwd)
		projected <- previewResult{rows: rows, err: err}
	}()
	var cursor, lastRecord string
	for index := 0; index < 2048; {
		raw, err := local.ReadNativeHistoryPage(ctx, ref, cwd, cursor, 128)
		if err != nil {
			t.Fatal(err)
		}
		page := decodeReplayFixturePage(t, raw)
		if len(page.Observations) == 0 {
			t.Fatal("replay ended before the last update")
		}
		for _, observation := range page.Observations {
			var plan struct{ Entries []struct{ Content string } }
			data := observation.GetExtension().GetData()
			if observation.GetSession().GetSessionId() != ref.SessionID || observation.GetInput() != nil ||
				json.Unmarshal(data, &plan) != nil || len(plan.Entries) != 1 || plan.Entries[0].Content != fmt.Sprint(index) {
				t.Fatalf("unexpected replay observation at %d: %s", index, data)
			}
			if !strings.Contains(string(data), `"ordinal" : 9007199254740993`) {
				t.Fatalf("replay rewrote the source observation: %s", data)
			}
			index++
			lastRecord = observation.Cursor
		}
		cursor = page.NextCursor
		if (cursor == "") != (index == 2048) {
			t.Fatalf("unexpected continuation at %d", index)
		}
	}
	preview := <-projected
	if preview.err != nil || len(preview.rows) != 128 || preview.rows[127].ACP.Cursor != lastRecord {
		t.Fatalf("inconsistent console tail, %d records, %v", len(preview.rows), preview.err)
	}
	raw, err := local.ReadNativeHistoryRecord(ctx, ref, cwd, "", lastRecord)
	if err != nil {
		t.Fatal(err)
	}
	result := decodeReplayFixturePage(t, raw)
	if len(result.Observations) != 1 || result.Observations[0].Cursor != lastRecord {
		t.Fatal("record lookup did not select the final original")
	}
	assertReplayFixtureLoads(t, cwd, 1)

	// Expiration forces a new passive load. Content-identical records keep the
	// cursor links already shown in the console.
	key := replayCacheKey{native: ref, cwd: cwd}
	expired := local.replayCache.items[key]
	expired.expires = time.Now().Add(-time.Second)
	local.replayCache.items[key] = expired
	if raw, err := local.ReadNativeHistoryRecord(ctx, ref, cwd, "", lastRecord); err != nil ||
		decodeReplayFixturePage(t, raw).Observations[0].Cursor != lastRecord {
		t.Fatalf("unchanged replay failed to resolve old cursor: %v", err)
	}
	assertReplayFixtureLoads(t, cwd, 2)

	if err := os.Remove(alias); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/bin/echo", alias); err != nil {
		t.Fatal(err)
	}
	if _, err := local.ReadNativeHistoryPage(ctx, ref, cwd, "", 1); err == nil {
		t.Fatal("retargeted shim reopened an existing session")
	}
	assertReplayFixtureLoads(t, cwd, 2)
}

func decodeReplayFixturePage(t *testing.T, data json.RawMessage) *model.ReadHistoryResponse {
	t.Helper()
	page := new(model.ReadHistoryResponse)
	if err := protojson.Unmarshal(data, page); err != nil {
		t.Fatal(err)
	}
	return page
}

func assertReplayFixtureLoads(t *testing.T, cwd string, loads int) {
	t.Helper()
	counts, err := os.ReadFile(filepath.Join(cwd, "replay-counts"))
	want := strings.Repeat("initialize\nload 2048\n", loads)
	if err != nil || string(counts) != want {
		t.Fatalf("unexpected peer work %q, want %q: %v", counts, want, err)
	}
}

func TestStoppedReplayPeer(t *testing.T) {
	if os.Getenv("COMMANDER_TEST_REPLAY_PEER") != "1" {
		t.Skip("started by the replay test")
	}
	counts, err := os.OpenFile("replay-counts", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer counts.Close()
	peer := json.NewDecoder(os.Stdin)
	for {
		var request struct {
			Method string
			ID     json.RawMessage
			Params struct {
				SessionID  string
				MCPServers []any
			}
		}
		if err := peer.Decode(&request); errors.Is(err, io.EOF) {
			return
		} else if err != nil {
			t.Fatal(err)
		}
		switch request.Method {
		case "initialize":
			fmt.Fprintln(counts, "initialize")
			fmt.Fprintf(os.Stdout, `{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}}`+"\n", request.ID)
		case "session/load":
			if request.Params.SessionID != "saved" || request.Params.MCPServers == nil || len(request.Params.MCPServers) != 0 {
				t.Fatal("replay did not exclusively select its original session without MCP")
			}
			for index := range 2048 {
				fmt.Fprintf(os.Stdout, `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"saved","update":{"sessionUpdate":"plan","entries":[{"content":"%d","priority":"medium","status":"completed"}],"ordinal" : 9007199254740993}}}`+"\n", index)
			}
			fmt.Fprintln(counts, "load 2048")
			fmt.Fprintln(os.Stdout, `{"jsonrpc":"2.0","id":"permission","method":"session/request_permission","params":{"sessionId":"saved","options":[],"toolCall":{"toolCallId":"historic"}}}`)
			var decision struct {
				ID     string
				Result struct{ Outcome struct{ Outcome string } }
			}
			if err := peer.Decode(&decision); err != nil || decision.ID != "permission" || decision.Result.Outcome.Outcome != "cancelled" {
				t.Fatalf("passive load requested an actionable approval: %+v, %v", decision, err)
			}
			fmt.Fprintf(os.Stdout, `{"jsonrpc":"2.0","id":%s,"result":{}}`+"\n", request.ID)
		default:
			t.Fatalf("unexpected replay request %q", request.Method)
		}
	}
}

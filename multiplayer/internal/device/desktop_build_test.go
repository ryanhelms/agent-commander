package device

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/actions"
	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/testpilot"
)

func TestDesktopBuildProofAcrossRelayEdges(t *testing.T) {
	pilot := testpilot.Start(t)
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Minute)
	defer cancel()
	const firstLaunch = "12345678-1234-4000-8000-123456789abc"
	const secondLaunch = "12345678-1234-4000-8000-123456789def"
	const revision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	const inbox = "bob-coordinator"
	start := time.Now().UTC().Add(-time.Minute)
	var launch atomic.Value
	launch.Store(firstLaunch)
	var reads atomic.Int32
	alice := startPeer(t, ctx, pilot, 0, "alice", nil)
	bob := startPeer(t, ctx, pilot, 1, "bob", func(cfg actions.Config) actions.Config {
		cfg.ReadDesktopBuild = func(_ context.Context, socket string) (actions.DesktopBuild, error) {
			if socket != cfg.CommanderSocket {
				t.Error("build evidence was read from the wrong local service")
			}
			reads.Add(1)
			return actions.DesktopBuild{Version: "0.1.0-pilot.6-9-gaaaaaaa", Revision: revision,
				Tree: "clean", Started: start, LaunchID: launch.Load().(string)}, nil
		}
		return cfg
	})
	for _, peer := range []*pilotPeer{alice, bob} {
		peer.must(t, ctx, "/tray/login", input{Handle: peer.handle}, nil)
		peer.waitOnline(t, ctx)
	}
	alice.must(t, ctx, "/tray/request", input{Handle: bob.handle}, nil)
	bob.must(t, ctx, "/tray/accept", input{Handle: alice.handle}, nil)
	bob.must(t, ctx, "/tray/resource-add", input{ID: inbox, Kind: "agent", Name: "Bob's coordinator", Target: bob.actor}, nil)

	// Emulate the previous published coordinator capability list, as with a
	// resource its owner has not refreshed after upgrading.
	ownerSession, err := bob.agent.getSession(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err = bob.agent.remote(ctx, ownerSession, http.MethodPut, "/v1/resources/"+inbox, map[string]any{
		"kind": "agent", "name": "Bob's coordinator", "actions": []string{"agent.message"},
	}, nil); err != nil {
		t.Fatal(err)
	}
	bob.must(t, ctx, "/tray/grant", input{Handle: alice.handle, Resource: inbox, Capability: "agent.message", Approval: "auto"}, nil)
	checkOffer := func(want bool) {
		t.Helper()
		var directory struct {
			Resources       []control.Resource
			ActionContracts map[string]actions.ActionContract
		}
		alice.must(t, ctx, "/coordinator/discover", struct{}{}, &directory)
		index := slices.IndexFunc(directory.Resources, func(resource control.Resource) bool { return resource.ID == inbox })
		_, described := directory.ActionContracts["app.build"]
		if index < 0 || slices.Contains(directory.Resources[index].Actions, "app.build") != want || described != want {
			t.Fatalf("receiver build-offer mismatch: %+v", directory)
		}
	}
	checkOffer(false)
	bob.must(t, ctx, "/tray/resource-update", input{ID: inbox}, nil)
	checkOffer(false) // Updating a resource never adds the new action to its existing note grant.

	operation := func(id, nonce string, issued time.Time) Submit {
		t.Helper()
		payload, err := json.Marshal(map[string]any{"nonce": nonce, "issuedAt": issued})
		if err != nil {
			t.Fatal(err)
		}
		return Submit{ID: id, Targets: []Target{{inbox, "app.build", payload}}}
	}
	if _, reason := alice.call(t, ctx, "/coordinator/submit", operation("ungranted", strings.Repeat("a", 32), time.Now().UTC())); reason == "" || reads.Load() != 0 {
		t.Fatalf("note-only grant let peer request build evidence: %q, reads=%d", reason, reads.Load())
	}
	bob.must(t, ctx, "/tray/grant", input{Handle: alice.handle, Resource: inbox, Capability: "app.build", Approval: "auto"}, nil)
	checkOffer(true)
	for i, want := range []string{firstLaunch, firstLaunch, secondLaunch} {
		launch.Store(want)
		nonce := strings.Repeat(string(rune('a'+i)), 32)
		request := operation("build-"+nonce, nonce, time.Now().UTC())
		alice.must(t, ctx, "/coordinator/submit", request, nil)
		row := alice.completed(t, ctx, request.ID, 1)[inbox]
		value := row.Result
		if row.BuildEvidence != "verified" || value["launchId"] != want || value["revision"] != revision || value["nonce"] != nonce ||
			value["tree"] != "clean" || value["observedAt"] == nil || len(value) != 7 {
			t.Fatalf("wrong authenticated build result: %+v", value)
		}
	}
	expired := operation("expired-build-request", strings.Repeat("e", 32), time.Now().UTC().Add(-2*time.Minute))
	alice.must(t, ctx, "/coordinator/submit", expired, nil)
	for {
		var receipt struct{ Children []childOutcome }
		alice.must(t, ctx, "/coordinator/receipt", map[string]string{"id": expired.ID}, &receipt)
		if len(receipt.Children) != 1 {
			t.Fatalf("wrong signed result: %+v", receipt)
		}
		row := receipt.Children[0]
		if row.Status == "declined" {
			if row.Result["code"] != "build_request_expired" || reads.Load() != 3 {
				t.Fatalf("expired request sampled the native app: %+v, reads=%d", row, reads.Load())
			}
			break
		}
		if !wait(ctx, 100*time.Millisecond) {
			t.Fatalf("timed out waiting for expired request: %+v", row)
		}
	}
}

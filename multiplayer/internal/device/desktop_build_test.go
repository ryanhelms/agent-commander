package device

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/actions"
	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/devicekeys"
	"agentcommander.network/pilot/internal/identity"
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
		"kind": "agent", "name": "Bob's relay coordinator", "actions": []string{"agent.message"},
		"capabilities": &control.Capabilities{Harness: "claude", Model: "test-model"}, "listed": true,
	}, nil); err != nil {
		t.Fatal(err)
	}
	noteExpiry := time.Now().UTC().Add(30 * time.Minute).Truncate(time.Second)
	bob.must(t, ctx, "/tray/grant", input{Handle: alice.handle, Resource: inbox, Capability: "agent.message",
		MaxUses: 3, ExpiresAt: noteExpiry, Approval: "auto"}, nil)
	checkNote := func() {
		t.Helper()
		for _, g := range bob.state(t, ctx).Grants {
			if g.Resource == inbox && g.Handle == alice.handle && g.Capability == "agent.message" &&
				g.MaxUses == 3 && g.ExpiresAt.Equal(noteExpiry) && g.Approval == "auto" {
				return
			}
		}
		t.Fatal("the note grant limits changed")
	}
	checkNote()
	matchesInbox := func(resource control.Resource) bool { return resource.ID == inbox }
	checkOwnerOffer := func(want bool) {
		t.Helper()
		var owner struct{ Resources []control.Resource }
		bob.must(t, ctx, "/tray/status", input{}, &owner)
		index := slices.IndexFunc(owner.Resources, matchesInbox)
		if index < 0 || slices.Contains(owner.Resources[index].Actions, "app.build") != want {
			t.Fatalf("owner build-offer mismatch, wanted %v: %+v", want, owner.Resources)
		}
	}
	checkRelayOffer := func(want bool) {
		t.Helper()
		rows, err := bob.agent.resources(ctx, ownerSession)
		if err != nil {
			t.Fatal(err)
		}
		index := slices.IndexFunc(rows, matchesInbox)
		if index < 0 {
			t.Fatal("coordinator enrollment missing")
		}
		r := rows[index]
		if slices.Contains(r.Actions, "app.build") != want || !slices.Contains(r.Actions, "agent.message") ||
			r.Name != "Bob's relay coordinator" || r.Capabilities == nil || r.Capabilities.Model != "test-model" || !r.Listed {
			t.Fatalf("relay coordinator metadata mismatch, wanted build offer %v: %+v", want, r)
		}
	}
	checkOwnerOffer(true)
	checkRelayOffer(false)
	if err := bob.agent.ensureDesktopBuildOffer(ctx, ownerSession, actions.Resource{
		ID: inbox, Kind: "agent", Target: bob.actor, Run: bob.otherRun.run, Coordinator: true,
	}); err == nil {
		t.Fatal("rebound run could refresh the enrolled coordinator resource")
	}
	checkRelayOffer(false)
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
	grantBuild := input{Handle: alice.handle, Resource: inbox, Capability: "app.build", Approval: "auto"}
	foreignGrant := grantBuild
	foreignGrant.Handle = bob.handle
	if _, why := alice.call(t, ctx, "/tray/grant", foreignGrant); why == "" {
		t.Fatal("another device could refresh the owner's resource")
	}
	invalidGrant := grantBuild
	invalidGrant.MaxUses = -1
	if _, why := bob.call(t, ctx, "/tray/grant", invalidGrant); why == "" {
		t.Fatal("invalid grant unexpectedly succeeded")
	}
	checkRelayOffer(false)

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
	bob.must(t, ctx, "/tray/grant", grantBuild, nil)
	checkOffer(true)
	checkRelayOffer(true)
	checkNote()
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
	if _, reason := alice.call(t, ctx, "/coordinator/submit", expired); reason != actions.ErrBuildRequestExpired.Error() {
		t.Fatalf("already-expired challenge was not rejected before sending: %q", reason)
	}

	// A previous sender may already have sealed a 24-hour child. Keep its
	// frozen request and receipt verifiable while limiting the owner's wait.
	guest, err := alice.agent.getSession(ctx)
	if err != nil {
		t.Fatal(err)
	}
	pinned, err := alice.agent.pin(ctx, guest, ownerSession.User, ownerSession.Device)
	if err != nil {
		t.Fatal(err)
	}
	bob.must(t, ctx, "/tray/grant", input{Handle: alice.handle, Resource: inbox, Capability: "app.build", Approval: "ask"}, nil)
	legacy := operation("legacy-long-wire-deadline", strings.Repeat("f", 32), time.Now().UTC().Add(-81*time.Second))
	challenge, err := actions.ParseDesktopBuildChallenge(legacy.Targets[0].Payload)
	if err != nil {
		t.Fatal(err)
	}
	wire := control.Addressed{ID: "legacy-build-child", Device: ownerSession.Device, Resource: inbox, Action: "app.build",
		ExpiresAt: time.Now().UTC().Add(maxApprovalWait).Truncate(time.Microsecond)}
	wire.Envelope, err = alice.agent.keys.Seal(pinned, devicekeys.Header{Sender: guest.User, SenderDevice: guest.Device,
		Recipient: ownerSession.User, RecipientDevice: ownerSession.Device, Operation: wire.ID, Resource: wire.Resource,
		Action: wire.Action, Kind: "request", ExpiresAt: wire.ExpiresAt}, legacy.Targets[0].Payload)
	if err != nil {
		t.Fatal(err)
	}
	intent, err := json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if err := save(filepath.Join(alice.agent.cfg.Dir, key(guest.User), "submissions", key(legacy.ID)+".json"), sendRecord{
		Digest: key(string(intent)), Wire: outbound{ID: legacy.ID, Children: []control.Addressed{wire}},
		BuildChallenges: map[string]actions.DesktopBuildChallenge{wire.ID: challenge},
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := alice.agent.submit(ctx, guest, legacy); err != nil {
		t.Fatal(err)
	}
	var queued Approval
	for queued.ID == "" {
		var rows struct{ Approvals []Approval }
		bob.must(t, ctx, "/tray/approvals", input{}, &rows)
		for _, approval := range rows.Approvals {
			if approval.ID == wire.ID {
				queued = approval
			}
		}
		if queued.ID == "" && (!time.Now().Before(challenge.ExpiresAt()) || !wait(ctx, 50*time.Millisecond)) {
			t.Fatal("owner never saw the legacy build approval")
		}
	}
	if !queued.Expires.Equal(challenge.ExpiresAt()) {
		t.Fatalf("approval uses the wire deadline instead of proof expiry: %v", queued.Expires)
	}

	expectExpired := func(next func() (any, error)) {
		t.Helper()
		for {
			result, err := next()
			if err != nil {
				t.Fatal(err)
			}
			rows := allRows(result)
			if len(rows) != 1 {
				t.Fatalf("wrong signed result: %+v", rows)
			}
			row := rows[0]
			if row["status"] == "declined" {
				value, _ := row["result"].(map[string]any)
				if value["code"] != "expired" || reads.Load() != 3 {
					t.Fatalf("expired request sampled the native app: %+v, reads=%d", row, reads.Load())
				}
				return
			}
			if !wait(ctx, 100*time.Millisecond) {
				t.Fatalf("timed out waiting for the signed expired result: %+v", row)
			}
		}
	}
	expectExpired(func() (any, error) { return alice.agent.receipt(ctx, guest, legacy.ID) })
	expectExpired(func() (any, error) { return alice.agent.submit(ctx, guest, legacy) })
	var remaining struct{ Approvals []Approval }
	bob.must(t, ctx, "/tray/approvals", input{}, &remaining)
	if len(remaining.Approvals) != 0 {
		t.Fatalf("expired approval remains visible: %+v", remaining.Approvals)
	}
	bob.ended.Store(true)
	if _, why := bob.call(t, ctx, "/tray/grant", grantBuild); why == "" {
		t.Fatal("ended coordinator accepted a new build grant")
	}
	// The independently published relay lifecycle lets the status menu hide
	// the offer without an owner-socket request for an existing advertisement.
	bob.agent.mu.Lock()
	lease := bob.agent.lease
	bob.agent.mu.Unlock()
	ended := proof(lease)
	ended["ended"] = true
	if err := bob.agent.remote(ctx, ownerSession, http.MethodPut, "/v1/resources/"+inbox+"/coordinator-inbox", ended, nil); err != nil {
		t.Fatal(err)
	}
	checkOwnerOffer(false)
	checkRelayOffer(true) // The offer and prior grants survive coordinator reattachment.
	checkNote()
}

func TestOwnerBuildActionsShareProbeBudget(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "ac-offer-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socket := filepath.Join(dir, "commander.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	var requests atomic.Int32
	server := &http.Server{Handler: http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		<-r.Context().Done()
	})}
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })
	a := &Agent{cfg: Config{CommanderSocket: socket, configureActions: func(cfg actions.Config) actions.Config {
		cfg.ReadDesktopBuild = func(context.Context, string) (actions.DesktopBuild, error) {
			t.Error("offering metadata must never read the native build")
			return actions.DesktopBuild{}, actions.ErrDesktopBuildUnavailable
		}
		return cfg
	}}}
	s := identity.Session{User: "owner", Device: "owner-device"}
	var local []actions.Resource
	var stale []control.Resource
	for i := range 24 {
		id := fmt.Sprintf("coordinator-%d", i)
		local = append(local, actions.Resource{ID: id, Kind: "agent", Coordinator: true, Target: id, Run: "run-" + id})
		stale = append(stale, control.Resource{ID: id, Kind: "agent", Owner: s.User, Device: s.Device, Actions: []string{"agent.message"}})
	}
	modern := stale[0]
	modern.Actions = []string{"agent.message", "app.build"}
	if got := a.ownerBuildActions(t.Context(), s, modern, local); !slices.Equal(got, modern.Actions) || requests.Load() != 0 {
		t.Fatalf("existing build offer needed a local probe: %v, requests=%d", got, requests.Load())
	}
	modern.InboxEnded = true
	if got := a.ownerBuildActions(t.Context(), s, modern, local); slices.Contains(got, "app.build") || requests.Load() != 0 {
		t.Fatalf("ended offer used a local probe: %v, requests=%d", got, requests.Load())
	}
	probe, cancel := context.WithTimeout(t.Context(), ownerBuildProbeBudget)
	defer cancel()
	for _, resource := range stale {
		if got := a.ownerBuildActions(probe, s, resource, local); !slices.Equal(got, resource.Actions) {
			t.Fatalf("unresponsive service exposed a stale build offer: %v", got)
		}
	}
	if probe.Err() != context.DeadlineExceeded || requests.Load() != 1 {
		t.Fatalf("stale offers exceeded their shared probe budget: %v, requests=%d", probe.Err(), requests.Load())
	}
}

func TestDesktopBuildApprovalDeadline(t *testing.T) {
	now := time.Now().UTC()
	wire := now.Add(time.Hour)
	pending := claimedRequest{arrived: now, child: control.Child{Addressed: control.Addressed{ExpiresAt: wire}}}
	if got := pending.approvalDeadline(); !got.Equal(wire) {
		t.Fatalf("ordinary approval deadline changed: %v", got)
	}
	pending.buildExpires = now.Add(time.Minute)
	if got := pending.approvalDeadline(); !got.Equal(pending.buildExpires) {
		t.Fatalf("build approval outlives the challenge: %v", got)
	}
	pending.child.ExpiresAt = now.Add(time.Second)
	if got := pending.approvalDeadline(); !got.Equal(pending.child.ExpiresAt) {
		t.Fatalf("challenge extended the signed transport window: %v", got)
	}
}

func TestDesktopBuildReceiptStopsWaitingForOfflineOwner(t *testing.T) {
	challenge := actions.DesktopBuildChallenge{Nonce: strings.Repeat("1", 32), IssuedAt: time.Now().UTC().Add(-2 * time.Minute)}
	const owner, device, parent = "owner", "owner-device", "parent"
	targets := []control.Addressed{
		{ID: "build", Device: device, Resource: "inbox", Action: "app.build", ExpiresAt: time.Now().UTC().Add(time.Hour)},
		{ID: "note", Device: device, Resource: "inbox", Action: "agent.message", ExpiresAt: time.Now().UTC().Add(time.Hour)},
	}
	record := sendRecord{Wire: outbound{ID: parent, Children: targets},
		BuildChallenges: map[string]actions.DesktopBuildChallenge{"build": challenge}}
	agent := &Agent{policy: localPolicy{Pins: map[string]devicekeys.Public{device: {User: owner}}}}
	sender := identity.Session{User: "sender", Device: "sender-device"}
	sub := control.Submission{ID: parent}
	for _, target := range targets {
		sub.Children = append(sub.Children, control.Child{Addressed: target, Parent: parent, Sender: sender.User,
			SenderDevice: sender.Device, Owner: owner, Status: "processing"})
	}
	path := filepath.Join(t.TempDir(), "submission.json")
	for range 2 {
		got, err := agent.projectSubmission(sender, path, &record, sub)
		if err != nil {
			t.Fatal(err)
		}
		rows := allRows(got)
		if len(rows) != 2 || rows[0]["status"] != "expired" || rows[0]["buildEvidence"] != "expired" ||
			rows[0]["result"] != nil || rows[1]["status"] != "processing" {
			t.Fatalf("wrong local projection before signed receipts arrive: %+v", rows)
		}
	}
}

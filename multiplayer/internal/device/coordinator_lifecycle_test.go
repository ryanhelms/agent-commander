package device

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/testpilot"
)

func TestCoordinatorInboxLifecycleAcrossRelayEdges(t *testing.T) {
	p := testpilot.Start(t)
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Minute)
	defer cancel()

	sender := startPeer(t, ctx, p, 0, "alice", nil)
	owner := startPeer(t, ctx, p, 1, "bob", nil)
	for _, peer := range []*pilotPeer{sender, owner} {
		peer.must(t, ctx, "/tray/login", input{Handle: peer.handle}, nil)
		peer.waitOnline(t, ctx)
	}
	sender.must(t, ctx, "/tray/request", input{Handle: owner.handle}, nil)
	owner.must(t, ctx, "/tray/accept", input{Handle: sender.handle}, nil)
	const inbox = "bob-inbox"
	owner.must(t, ctx, "/tray/resource-add", input{ID: inbox, Kind: "agent", Name: "Bob's coordinator", Target: owner.actor}, nil)

	operation := func(id string) Submit {
		return Submit{ID: id, Targets: []Target{{inbox, "agent.message", json.RawMessage(`{"text":"Bound to this inbox"}`)}}}
	}
	waitForDiscovery := func(active, ended bool) {
		t.Helper()
		discovery, cancel := context.WithTimeout(ctx, 25*time.Second)
		defer cancel()
		matchesInbox := func(resource control.Resource) bool { return resource.ID == inbox }
		for {
			var catalog struct {
				Resources               []control.Resource
				EndedCoordinatorInboxes []control.Resource
			}
			sender.must(t, ctx, "/coordinator/discover", struct{}{}, &catalog)
			if slices.ContainsFunc(catalog.Resources, matchesInbox) == active &&
				slices.ContainsFunc(catalog.EndedCoordinatorInboxes, matchesInbox) == ended {
				return
			}
			if !wait(discovery, 100*time.Millisecond) {
				t.Fatalf("expected active=%v, ended=%v: %+v", active, ended, catalog)
			}
		}
	}
	senderSession, err := sender.agent.getSession(ctx)
	if err != nil {
		t.Fatal(err)
	}
	path := "/v1/resources/" + inbox + "/coordinator-inbox"
	sender.agent.mu.Lock()
	lease := sender.agent.lease
	sender.agent.mu.Unlock()
	body := proof(lease)
	body["ended"] = true
	err = sender.agent.remote(ctx, senderSession, http.MethodPut, path, body, nil)
	var refusal statusError
	if !errors.As(err, &refusal) || refusal.code != http.StatusForbidden {
		t.Fatalf("peer could update another device's status: %v", err)
	}

	owner.ended.Store(true)
	waitForDiscovery(false, false)
	if _, why := sender.call(t, ctx, "/coordinator/submit", operation("ungranted")); why == "" {
		t.Fatal("an ended inbox disclosed its state to an ungranted peer")
	}
	owner.must(t, ctx, "/tray/grant", input{Handle: sender.handle, Resource: inbox, Capability: "agent.message", Approval: "auto"}, nil)
	waitForDiscovery(false, true)
	sender.must(t, ctx, "/coordinator/submit", operation("ended"), nil)

	var stale childOutcome
	for {
		var receipt struct{ Children []childOutcome }
		sender.must(t, ctx, "/coordinator/receipt", map[string]string{"id": "ended"}, &receipt)
		if len(receipt.Children) != 1 {
			t.Fatalf("invalid addressed receipt: %+v", receipt)
		}
		stale = receipt.Children[0]
		if stale.Status == "declined" {
			break
		}
		if !wait(ctx, 100*time.Millisecond) {
			t.Fatalf("waiting for signed stale receipt: %+v", stale)
		}
	}
	if stale.Result["code"] != "coordinator_inbox_ended" {
		t.Fatalf("expected signed inbox-ended receipt: %+v", stale)
	}
	owner.ended.Store(false)
	waitForDiscovery(true, false)
	sender.must(t, ctx, "/coordinator/submit", operation("after-reopen"), nil)
	accepted := sender.completed(t, ctx, "after-reopen", 1)[inbox]
	var delivery struct{ Messages []struct{ ID string } }
	owner.must(t, ctx, "/coordinator/inbox", struct{}{}, &delivery)
	if len(delivery.Messages) != 1 || delivery.Messages[0].ID != accepted.Result["messageId"] {
		t.Fatalf("inbox should contain only the message explicitly sent after reopen: %+v", delivery)
	}
	var previous struct{ Children []childOutcome }
	sender.must(t, ctx, "/coordinator/receipt", map[string]string{"id": "ended"}, &previous)
	if len(previous.Children) != 1 || previous.Children[0].ID != stale.ID || previous.Children[0].Result["code"] != "coordinator_inbox_ended" {
		t.Fatalf("reopen changed the original receipt: %+v", previous)
	}
}

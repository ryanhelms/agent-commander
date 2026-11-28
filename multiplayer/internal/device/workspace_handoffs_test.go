package device

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/testpilot"
)

func TestWorkspaceHandoffAcrossRelayEdges(t *testing.T) {
	pilot := testpilot.Start(t)
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Minute)
	defer cancel()
	sender := startPeer(t, ctx, pilot, 0, "alice", nil)
	owner := startPeer(t, ctx, pilot, 1, "bob", nil)
	for _, peer := range []*pilotPeer{sender, owner} {
		peer.must(t, ctx, "/tray/login", input{Handle: peer.handle}, nil)
		peer.waitOnline(t, ctx)
	}
	sender.must(t, ctx, "/tray/request", input{Handle: owner.handle}, nil)
	owner.must(t, ctx, "/tray/accept", input{Handle: sender.handle}, nil)
	var group, workspace struct{ ID string }
	owner.must(t, ctx, "/tray/group-create", input{Name: "Handoff partner"}, &group)
	owner.must(t, ctx, "/tray/workspace-create", input{
		Name: "Pilot", Goal: "Check delivery", Repository: "commander/test",
		Base: "develop", Group: group.ID, Integration: "pull_request",
	}, &workspace)
	const inbox = "durable-bob"
	owner.must(t, ctx, "/tray/resource-add", input{ID: inbox, Workspace: workspace.ID, Kind: "agent", Name: "Bob's workspace", Target: owner.run}, nil)
	for _, action := range []string{"agent.handoff", "agent.status", "agent.result"} {
		owner.must(t, ctx, "/tray/grant", input{Resource: inbox, Handle: sender.handle, Capability: action, Approval: "auto", MaxUses: 100}, nil)
	}
	var offered struct{ Resources []control.Resource }
	sender.must(t, ctx, "/coordinator/discover", struct{}{}, &offered)
	if slices.ContainsFunc(offered.Resources, func(r control.Resource) bool { return r.ID == inbox }) {
		t.Fatal("paired friend outside the workspace discovered its handoff grant")
	}
	owner.must(t, ctx, "/tray/group-add", input{Group: group.ID, Handle: sender.handle}, nil)
	const expected = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	payload := json.RawMessage(`{"title":"Pilot restart check","task":"Check this revision","expectedHead":"` + expected + `"}`)

	// The real requester waits for an authenticated, durable recipient receipt.
	// Separate real clients use private TLS, PostgreSQL, and JetStream, with
	// local Commander provider calls stubbed at the owner's Unix socket.
	const samples = 40
	latencies := make([]time.Duration, 0, samples)
	handoffs := make([]string, 0, samples)
	var failures int
	for i := 0; i < samples; i++ {
		started := time.Now()
		raw, why := sender.call(t, ctx, "/tray/send", input{Resource: inbox, Capability: "agent.handoff", Payload: payload})
		var receipt struct {
			Result struct{ Run, DeliveredAt, AcceptedAt, VerifiedAt string }
			Status string
		}
		if why != "" || json.Unmarshal(raw, &receipt) != nil || receipt.Status != "completed" ||
			receipt.Result.Run == "" || receipt.Result.DeliveredAt == "" || receipt.Result.AcceptedAt != "" || receipt.Result.VerifiedAt != "" {
			t.Errorf("sample %d did not produce a delivered-only receipt: %s %s", i, raw, why)
			failures++
			continue
		}
		latencies = append(latencies, time.Since(started))
		handoffs = append(handoffs, receipt.Result.Run)
	}
	if len(latencies) != samples {
		t.Fatalf("%d of %d online handoff samples failed", failures, samples)
	}
	slices.Sort(latencies)
	p95 := latencies[(95*len(latencies)+99)/100-1]
	t.Logf("two TLS device clients on independent local Go relay edges, PostgreSQL + JetStream: samples=%d failed=%d min=%s p50=%s p95=%s max=%s",
		samples, failures, latencies[0], latencies[len(latencies)/2-1], p95, latencies[len(latencies)-1])
	if p95 > 2*time.Second {
		t.Errorf("online p95 %s exceeds 2s", p95)
	}
	if owner.workspaceStarts.Load() != 0 {
		t.Fatal("workspace started while auto-start was disabled")
	}

	// Simulate a helper dying after claiming delivery but before it writes the
	// inbox. The restarted helper uses the same origin and durable state. The
	// sender continues on its own relay edge.
	previous := owner.agent
	cfg := previous.cfg
	session, err := previous.getSession(ctx)
	if err != nil {
		t.Fatal(err)
	}
	previous.mu.Lock()
	lease := previous.lease
	previous.mu.Unlock()
	previous.Close()
	interrupted := Submit{ID: "interrupted-workspace-delivery", Targets: []Target{{inbox, "agent.handoff", payload}}}
	sender.must(t, ctx, "/coordinator/submit", interrupted, nil)
	var outstanding struct{ Children []control.Child }
	inboxURL := "/v1/inbox?generation=" + strconv.FormatInt(lease.Generation, 10) + "&session=" + url.QueryEscape(lease.Session)
	if err = previous.remote(ctx, session, http.MethodGet, inboxURL, nil, &outstanding); err != nil || len(outstanding.Children) != 1 {
		t.Fatalf("find interrupted delivery: %v, %d children", err, len(outstanding.Children))
	}
	var claim struct{ Claimed bool }
	if err = previous.remote(ctx, session, http.MethodPost, "/v1/children/"+outstanding.Children[0].ID+"/claim", proof(lease), &claim); err != nil || !claim.Claimed {
		t.Fatalf("claim immediately before simulated helper failure: %v", err)
	}
	owner.agent, err = New(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(owner.agent.Close)
	owner.api = owner.agent.Handler()
	owner.waitOnline(t, ctx)
	recovered := sender.completed(t, ctx, interrupted.ID, 1)[inbox]
	if recovered.ID != outstanding.Children[0].ID || recovered.Result["deliveredAt"] == nil {
		t.Fatalf("restarted helper did not recover original claim: %+v", recovered)
	}
	optIn := true
	owner.must(t, ctx, "/tray/resource-update", input{Resource: inbox, AutoStart: &optIn}, nil)
	deadline := time.Now().Add(20 * time.Second)
	for owner.workspaceStarts.Load() < samples+1 && time.Now().Before(deadline) {
		if !wait(ctx, 50*time.Millisecond) {
			t.Fatal(ctx.Err())
		}
	}
	if n := owner.workspaceStarts.Load(); n != samples+1 {
		t.Fatalf("durable handoffs did not resume uniquely: got %d of %d", n, samples+1)
	}
	for _, id := range []string{handoffs[0], handoffs[samples-1]} {
		statusBody, _ := json.Marshal(map[string]string{"run": id})
		var receipt struct {
			Result struct{ Run, DeliveredAt, AcceptedAt, VerifiedAt, Head string }
			Status string
		}
		sender.must(t, ctx, "/tray/send", input{Resource: inbox, Capability: "agent.result", Payload: statusBody}, &receipt)
		if receipt.Status != "completed" || receipt.Result.Run != id || receipt.Result.DeliveredAt == "" ||
			receipt.Result.AcceptedAt == "" || receipt.Result.VerifiedAt == "" || receipt.Result.Head != expected {
			t.Fatalf("missing persisted authenticated lifecycle for %s: %+v", id, receipt)
		}
	}
	// Stable operation IDs reconcile to one handoff even when the sender
	// resubmits and the recipient reconnects before reading the result.
	req := Submit{ID: "retry-after-reconnect", Targets: []Target{{inbox, "agent.handoff", payload}}}
	sender.must(t, ctx, "/coordinator/submit", req, nil)
	first := sender.completed(t, ctx, req.ID, 1)[inbox]
	sender.must(t, ctx, "/coordinator/submit", req, nil)
	replayed := sender.completed(t, ctx, req.ID, 1)[inbox]
	if first.ID != replayed.ID || first.Result["deliveredAt"] != replayed.Result["deliveredAt"] {
		t.Fatal(fmt.Errorf("duplicate delivery did not return original receipt: %v, %v", first, replayed))
	}
	owner.must(t, ctx, "/tray/grant", input{Resource: inbox, Handle: sender.handle, Capability: "agent.handoff", Approval: "ask", MaxUses: 100}, nil)
	req.ID = "workspace-review-required"
	sender.must(t, ctx, "/coordinator/submit", req, nil)
	ask := sender.completed(t, ctx, req.ID, 1)[inbox]
	if ask.Result["deliveredAt"] == nil || ask.Result["acceptedAt"] != nil {
		t.Fatalf("a personal approval must not gate delivery or imply acceptance: %+v", ask)
	}
	var approvals struct{ Approvals []Approval }
	owner.must(t, ctx, "/tray/approvals", input{}, &approvals)
	if !slices.ContainsFunc(approvals.Approvals, func(row Approval) bool { return row.ID == ask.ID }) {
		t.Fatalf("durably delivered workspace handoff not in normal approval queue: %+v", approvals)
	}
	if _, launched := owner.workspaceRuns.Load(ask.ID); launched {
		t.Fatal("unapproved workspace handoff reached the coordinator")
	}
	owner.must(t, ctx, "/tray/approve", input{ID: ask.ID}, nil)
	for {
		if _, launched := owner.workspaceRuns.Load(ask.ID); launched {
			break
		}
		if !wait(ctx, 100*time.Millisecond) {
			t.Fatal("approved workspace handoff did not resume")
		}
	}
	owner.must(t, ctx, "/tray/group-remove", input{Group: group.ID, Handle: sender.handle}, nil)
	req.ID = "departed-workspace-request"
	if _, why := sender.call(t, ctx, "/coordinator/submit", req); why == "" {
		t.Fatal("removed member could still hand off to workspace")
	}
}

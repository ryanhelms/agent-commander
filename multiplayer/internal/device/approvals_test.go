package device

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/actions"
	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/testpilot"
)

func TestApprovalModes(t *testing.T) {
	for _, tc := range []struct {
		action, approval string
		handover, ask    bool
	}{
		{"agent.ask", "", false, true},
		{"agent.ask", "ask", false, true},
		{"agent.ask", "auto", false, false},
		{"agent.suggest", "auto", false, true},
		{"agent.suggest", "ask", true, false},
		{"agent.ask", "ask", true, false},
		{"agent.status", "ask", false, false},
		{"agent.result", "ask", false, false},
		{"thread.read", "", false, false},
		{"thread.comment", "ask", false, false},
	} {
		child := control.Child{Addressed: control.Addressed{Resource: "worker", Action: tc.action}, Sender: "friend"}
		a := &Agent{policy: localPolicy{Grants: []actions.Grant{{Resource: child.Resource, Action: tc.action, Peer: child.Sender, Approval: tc.approval}}}}
		if tc.handover {
			a.handovers = map[string]time.Time{"friend|worker": time.Now().Add(time.Hour)}
		}
		if got := a.needsApproval(child); got != tc.ask {
			t.Errorf("needsApproval(%+v) = %t", tc, got)
		}
	}
}

func TestConsultDecisionsAndAuditAcrossDevices(t *testing.T) {
	p := testpilot.Start(t)
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Minute)
	defer cancel()
	owner := startPeer(t, ctx, p, 0, "owner", nil)
	guest := startPeer(t, ctx, p, 1, "guest", nil)
	for _, peer := range []*pilotPeer{owner, guest} {
		peer.must(t, ctx, "/tray/login", input{Handle: peer.handle}, nil)
		peer.waitOnline(t, ctx)
	}
	guest.must(t, ctx, "/tray/request", input{Handle: owner.handle}, nil)
	owner.must(t, ctx, "/tray/accept", input{Handle: guest.handle}, nil)
	owner.must(t, ctx, "/tray/resource-add", input{ID: "worker", Name: "Owner's worker", Kind: "agent", Target: owner.worker}, nil)

	until := time.Now().Add(time.Hour)
	grant := func(action, mode string, uses, budget int) {
		t.Helper()
		owner.must(t, ctx, "/tray/grant", input{Resource: "worker", Handle: guest.handle, Capability: action, Approval: mode, MaxUses: uses, BudgetTokens: budget, ExpiresAt: until}, nil)
	}
	grant("agent.ask", "", 10, 7)
	grant("thread.read", "ask", 1, 0)
	grant("thread.comment", "ask", 1, 0)
	question := json.RawMessage(`{"text":"Review this."}`)
	submit := func(id, action string, payload json.RawMessage) string {
		t.Helper()
		var result struct{ Children []childOutcome }
		guest.must(t, ctx, "/coordinator/submit", Submit{ID: id, Targets: []Target{{Resource: "worker", Action: action, Payload: payload}}}, &result)
		if len(result.Children) != 1 {
			t.Fatalf("%s returned %+v", id, result)
		}
		return result.Children[0].ID
	}
	waitPending := func(id string) {
		t.Helper()
		for {
			var rows struct{ Approvals []Approval }
			owner.must(t, ctx, "/tray/approvals", input{}, &rows)
			if slices.ContainsFunc(rows.Approvals, func(r Approval) bool { return r.ID == id && r.Handle == guest.handle }) {
				return
			}
			if !wait(ctx, 100*time.Millisecond) {
				t.Fatalf("owner never saw pending request %s", id)
			}
		}
	}
	audited := func(peer *pilotPeer, id, outcome string, tokens int) AuditEntry {
		t.Helper()
		for {
			var audit struct{ Entries []AuditEntry }
			peer.must(t, ctx, "/tray/audit", input{Resource: "worker"}, &audit)
			seen := 0
			var got AuditEntry
			for _, e := range audit.Entries {
				if e.Request == id {
					seen++
					got = e
				}
			}
			if seen > 1 {
				t.Fatalf("duplicate audit entries for %s", id)
			}
			if seen == 1 && got.Outcome != "pending" {
				if got.Outcome != outcome || got.Tokens != tokens || got.Peer == "" || got.Started.IsZero() || got.Ended.Before(got.Started) {
					t.Fatalf("%s audit for %s: %+v, want %s and %d tokens", peer.handle, id, got, outcome, tokens)
				}
				return got
			}
			if !wait(ctx, 100*time.Millisecond) {
				t.Fatalf("%s failed to record %s for %s", peer.handle, outcome, id)
			}
		}
	}
	check := func(id, outcome string, tokens int) {
		t.Helper()
		audited(owner, id, outcome, tokens)
		audited(guest, id, outcome, tokens)
	}

	denied := submit("denied", "agent.ask", question)
	waitPending(denied)
	owner.must(t, ctx, "/tray/deny", input{ID: denied, Reason: "Try after lunch."}, nil)
	check(denied, "denied", 0)
	var receipt struct{ Children []childOutcome }
	guest.must(t, ctx, "/coordinator/receipt", map[string]string{"id": "denied"}, &receipt)
	if receipt.Children[0].Result["reason"] != "Try after lunch." || receipt.Children[0].Result["code"] != "denied" {
		t.Fatalf("denial lost its reason: %+v", receipt)
	}

	expired := submit("late", "agent.ask", question)
	waitPending(expired)
	owner.agent.mu.Lock()
	pending := owner.agent.pending[expired]
	pending.arrived = time.Now().Add(-maxApprovalWait)
	owner.agent.pending[expired] = pending
	owner.agent.mu.Unlock()
	owner.must(t, ctx, "/tray/approve", input{ID: expired}, nil)
	check(expired, "expired", 0)

	accepted := submit("approved", "agent.ask", question)
	waitPending(accepted)
	owner.must(t, ctx, "/tray/approve", input{ID: accepted}, nil)
	check(accepted, "completed", 7)
	spent := submit("spent", "agent.ask", question)
	check(spent, "budget_exhausted", 0)
	if owner.turns.Load() != 1 {
		t.Fatalf("refused requests launched extra turns: %d", owner.turns.Load())
	}

	for i := 0; i < 2; i++ {
		for _, action := range []string{"thread.comment", "thread.read"} {
			body := map[string]string{"request": accepted}
			if action == "thread.comment" {
				body["text"] = "Follow-up"
			}
			payload, _ := json.Marshal(body)
			id := submit(fmt.Sprintf("%s-%d", action, i), action, payload)
			check(id, "completed", 0)
		}
	}
	grant("agent.ask", "auto", 10, 0)
	bad := submit("invalid", "agent.ask", json.RawMessage(`{}`))
	check(bad, "failed", 0)
	auto := submit("auto", "agent.ask", question)
	check(auto, "completed", 7)
	if owner.turns.Load() != 2 {
		t.Fatalf("want two completed turns, got %d", owner.turns.Load())
	}
}

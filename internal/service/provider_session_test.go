package service

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

type discoveringLauncher struct {
	recorder
	discovery chan ProviderSessionScope
}

func (l discoveringLauncher) ListProviderSessions(_ context.Context, scope ProviderSessionScope, _ string, _ uint32) (ProviderSessionPage, error) {
	l.discovery <- scope
	return ProviderSessionPage{Sessions: []ProviderSessionSummary{{SessionID: scope.Ref.SessionID, Title: "Selected"}}}, nil
}

func (l discoveringLauncher) ProviderHistoryAvailability(NativeSession) string { return "after_stop" }

func TestProviderSessionReattachKeepsUncertainDeliveryAndScopesDiscovery(t *testing.T) {
	f := newFixture(t)
	discovery := make(chan ProviderSessionScope, 1)
	var err error
	f.api, err = New(f.dir, discoveringLauncher{f.p, discovery})
	if err != nil {
		t.Fatal(err)
	}
	worker := f.delegate(f.run(), "")
	path := "/v1/workers/" + worker.ID
	ref := NativeSession{HarnessInstance: "fixture", SessionID: "selected"}
	fingerprint := strings.Repeat("ab", 32)
	caps := SessionCapabilities{CanResume: true, CanListSessions: true}
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", path+"/native-session", "", map[string]any{
		"harness_instance": ref.HarnessInstance, "session_id": ref.SessionID, "provider_binding": fingerprint, "peer_capabilities": caps,
	}, 200, "")
	f.call("POST", path+"/control/ready", worker.Token, map[string]any{"session_capabilities": caps}, 200, "")
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed"}, 200, "")
	f.call("GET", path+"/provider-sessions", worker.Token, nil, 403, "")
	f.call("GET", path+"/provider-sessions?limit=1", "", nil, 200, "")
	scope := <-discovery
	if scope.Worktree != worker.Worktree || scope.Token != "" || scope.ProviderBinding != fingerprint || scope.Ref != ref {
		t.Fatalf("discovery scope was not restricted to the existing workspace and provider: %+v", scope)
	}
	f.call("POST", path+"/control", "", map[string]any{"generation": 1, "held": true}, 200, "")
	message := f.call("POST", path+"/messages", "", map[string]any{"generation": 2, "text": "may already have run"}, 202, "")
	var queued WorkerFollowUp
	if err := json.Unmarshal(message, &queued); err != nil {
		t.Fatal(err)
	}
	f.call("POST", path+"/messages/"+queued.ID+"/claim", worker.Token, struct{}{}, 200, "")
	f.call("POST", path+"/stop", "", struct{}{}, 202, "")
	select {
	case <-f.p.stops:
	case <-time.After(3 * time.Second):
		t.Fatal("worker stop was not dispatched")
	}

	status := func() providerSessionStatus {
		var current providerSessionStatus
		raw := f.call("GET", path+"/session", "", nil, 200, "")
		if err := json.Unmarshal(raw, &current); err != nil {
			t.Fatal(err)
		}
		return current
	}
	for deadline := time.Now().Add(3 * time.Second); !status().CanReattach; {
		if time.Now().After(deadline) {
			t.Fatal("stopped worker was not available for reattachment")
		}
		time.Sleep(time.Millisecond)
	}
	if got := status(); got.History != "available" || got.DeliveryUnknown != 1 {
		t.Fatalf("incorrect history or delivery state: %+v", got)
	}
	f.call("POST", path+"/reattach", "", reattachRequest{Generation: 1, AcknowledgeDeliveryUnknown: true}, 409, "stale")
	f.call("POST", path+"/reattach", "", reattachRequest{Generation: 2}, 409, "needs-acknowledgement")
	f.call("POST", path+"/reattach", "", reattachRequest{Generation: 2, AcknowledgeDeliveryUnknown: true}, 202, "reattach")
	resumed := f.launched()
	if resumed.ID != worker.ID || resumed.Token == worker.Token ||
		resumed.Reattach == nil || resumed.Reattach.Ref != ref || resumed.Reattach.Generation != 3 {
		t.Fatalf("reattachment did not reserve the original binding with a new lease: %+v", resumed.Reattach)
	}
	f.call("POST", path+"/reattach", "", reattachRequest{Generation: 2, AcknowledgeDeliveryUnknown: true}, 200, "reattach")
	select {
	case <-f.p.starts:
		t.Fatal("reattachment retry launched a duplicate")
	default:
	}
	binding := struct{ ReattachSpec }{*resumed.Reattach}
	f.call("POST", path+"/control/reattached", worker.Token, binding, 401, "")
	f.call("POST", path+"/control/reattached", resumed.Token, binding, 200, "")
	var run Run
	raw := f.call("GET", "/v1/runs/"+worker.RunID, "", nil, 200, "")
	if err := json.Unmarshal(raw, &run); err != nil {
		t.Fatal(err)
	}
	for _, found := range run.Workers {
		if found.ID == worker.ID {
			if found.State != "idle" || found.Control.next() != nil || found.Control.message(queued.ID).Status != "delivery_unknown" {
				t.Fatalf("reattachment changed the prior operation or queued a prompt: %+v", found.Control)
			}
			return
		}
	}
	t.Fatal("reattached worker disappeared")
}

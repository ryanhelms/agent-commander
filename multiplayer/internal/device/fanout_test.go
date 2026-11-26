package device

import (
	"encoding/json"
	"fmt"
	"maps"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"agentcommander.network/pilot/internal/actions"
	"agentcommander.network/pilot/internal/control"
)

func TestFanoutTargetCount(t *testing.T) {
	var targets []Target
	var resources []control.Resource
	for i := range 33 {
		id := fmt.Sprintf("worker-%d", i)
		targets = append(targets, Target{Resource: id, Action: "agent.ask"})
		resources = append(resources, control.Resource{ID: id, Actions: []string{"agent.ask"}})
	}
	children := 0
	a := newRequester(t, resources, false, func(control.Child, json.RawMessage) any {
		children++
		return "done"
	})
	p := &pilotPeer{api: a.Handler()}
	in := input{Payload: json.RawMessage(`{"text":"compare"}`)}
	for _, n := range []int{0, 1, 33} {
		in.Targets = targets[:n]
		if _, why := p.call(t, t.Context(), "/tray/fanout", in); why == "" || children != 0 {
			t.Fatalf("fanout with %d targets: error %q, %d children submitted", n, why, children)
		}
	}
	in.Targets = targets[:32]
	p.must(t, t.Context(), "/tray/fanout", in, nil)
	if children != 32 {
		t.Fatalf("fanout at the upper limit submitted %d children", children)
	}
}

func TestFanoutSentChildrenAndCoordinatorThread(t *testing.T) {
	ctx := t.Context()
	owner := actions.Config{StateDir: t.TempDir()}
	resources := []control.Resource{
		{ID: "alpha", Actions: []string{"agent.ask", "thread.comment", "thread.read"}},
		{ID: "beta", Actions: []string{"agent.ask", "thread.comment", "thread.read"}},
	}
	childID := map[string]string{}
	a := newRequester(t, resources, false, func(c control.Child, payload json.RawMessage) any {
		var in struct{ Text, Request string }
		if err := json.Unmarshal(payload, &in); err != nil {
			t.Fatal(err)
		}
		if c.Action == "agent.ask" {
			if in.Text != "compare" {
				t.Fatalf("%s received payload %s", c.Resource, payload)
			}
			childID[c.Resource] = c.ID
			return map[string]string{"text": "answer from " + c.Resource}
		}
		if in.Request != childID[c.Resource] {
			t.Fatalf("%s routed to %s with child ID %q, want %q", c.Action, c.Resource, in.Request, childID[c.Resource])
		}
		switch c.Action {
		case "thread.comment":
			comment, err := actions.AddComment(owner, in.Request, actions.Comment{Author: c.Sender, Text: in.Text})
			if err != nil {
				t.Fatal(err)
			}
			return comment
		case "thread.read":
			thread, err := actions.ReadThread(owner, in.Request)
			if err != nil {
				t.Fatal(err)
			}
			return thread
		default:
			t.Fatalf("unexpected action %s", c.Action)
			return nil
		}
	})
	// The accepted submission already identifies each child, even if a receipt
	// cannot be fetched again until the user opens Sent.
	relay := a.http.Transport.(relayTransport)
	receiptsAvailable := false
	a.http.Transport = relayTransport{http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !receiptsAvailable && r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/v1/submissions/") {
			http.Error(w, "temporarily unavailable", http.StatusServiceUnavailable)
			return
		}
		relay.ServeHTTP(w, r)
	})}
	a.handle = "requester"
	p := coordinatorPeer(t, a)
	var sent struct{ Request string }
	p.must(t, ctx, "/tray/fanout", input{
		Targets: []Target{{Resource: "alpha", Action: "agent.ask"}, {Resource: "beta", Action: "agent.ask"}},
		Payload: json.RawMessage(`{"text":"compare"}`),
	}, &sent)
	if sent.Request == "" || childID["alpha"] == "" || childID["beta"] == "" || childID["alpha"] == childID["beta"] {
		t.Fatalf("fanout request %q has child IDs %v", sent.Request, childID)
	}

	b, err := os.ReadFile(filepath.Join(a.cfg.Dir, "sent.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	var record SentRequest
	if err := json.Unmarshal(b, &record); err != nil {
		t.Fatalf("decode sent.jsonl: %v", err)
	}
	wantChildren := []SentChild{{ID: childID["alpha"], Resource: "alpha"}, {ID: childID["beta"], Resource: "beta"}}
	if record.ID != sent.Request || len(record.Children) != len(wantChildren) {
		t.Fatalf("sent.jsonl recorded children %+v for %q, want %+v for %q", record.Children, record.ID, wantChildren, sent.Request)
	}
	for _, c := range wantChildren {
		if !slices.Contains(record.Children, c) {
			t.Errorf("sent.jsonl omitted %+v", c)
		}
	}
	receiptsAvailable = true
	var history struct {
		Sent []struct {
			Request  string
			Children []struct {
				ID, Resource, Status string
				Value                struct{ Text string }
			}
		}
	}
	p.must(t, ctx, "/tray/sent", input{}, &history)
	if len(history.Sent) != 1 || history.Sent[0].Request != sent.Request {
		t.Fatalf("sent history = %+v", history.Sent)
	}
	values := map[string]string{}
	for _, child := range history.Sent[0].Children {
		if child.ID != childID[child.Resource] || child.Status != "completed" {
			t.Errorf("sent child = %+v", child)
		}
		values[child.Resource] = child.Value.Text
	}
	if len(history.Sent[0].Children) != 2 || !maps.Equal(values, map[string]string{"alpha": "answer from alpha", "beta": "answer from beta"}) {
		t.Fatalf("sent child values = %+v", history.Sent[0].Children)
	}

	var comment actions.Comment
	p.must(t, ctx, "/coordinator/thread", map[string]string{"request": childID["beta"], "text": "Use beta's answer."}, &comment)
	if comment.Text != "Use beta's answer." || comment.ID == "" {
		t.Fatalf("thread comment = %+v", comment)
	}
	for _, path := range []string{"/tray/thread", "/coordinator/thread"} {
		var thread struct {
			Request  string
			Comments []actions.Comment
		}
		p.must(t, ctx, path, map[string]string{"request": childID["beta"]}, &thread)
		if thread.Request != childID["beta"] || !slices.Equal(thread.Comments, []actions.Comment{comment}) {
			t.Fatalf("%s returned %+v", path, thread)
		}
	}
}

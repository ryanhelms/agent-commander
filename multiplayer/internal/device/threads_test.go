package device

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/control"
)

type threadRow struct {
	Request, Resource, Action, Title, Direction, Peer, Handle string
	At                                                        time.Time
	Comments                                                  *int
	LastCommentAt                                             *time.Time
	Children                                                  []struct{ Request, Resource string }
}

func listThreads(t *testing.T, a *Agent) []threadRow {
	t.Helper()
	raw, err := call(t, a.Handler(), "threads", input{})
	var list struct{ Threads []threadRow }
	if err != "" || json.Unmarshal(raw, &list) != nil {
		t.Fatalf("threads: %s %s", raw, err)
	}
	return list.Threads
}

func TestThreadsListsSentAndReceived(t *testing.T) {
	resources := []control.Resource{{ID: "shared", Actions: []string{"agent.ask", "agent.status"}}}
	a := newRequester(t, resources, false, func(control.Child, json.RawMessage) any {
		return map[string]any{"answer": "yes"}
	})
	h := a.Handler()
	data, err := call(t, h, "send", input{Capability: "agent.ask", Resource: "shared", Name: "Is the build green?", Payload: json.RawMessage(`{"text":"is the build green?"}`)})
	var sent struct{ Request string }
	if err != "" || json.Unmarshal(data, &sent) != nil || sent.Request == "" {
		t.Fatalf("send consult: %s %s", data, err)
	}
	if _, err = call(t, h, "send", input{Capability: "agent.status", Resource: "shared", Payload: json.RawMessage(`{"run":"r1"}`)}); err != "" {
		t.Fatalf("send follow-up: %s", err)
	}

	me := a.creds.Session.User
	base := time.Now().Add(time.Minute).UTC()
	a.record(AuditEntry{Request: "received-ask", Peer: "friend-user-id", Resource: "agent", Action: "agent.ask", Recipient: me, Started: base})
	a.record(AuditEntry{Request: "received-status", Peer: "friend-user-id", Resource: "agent", Action: "agent.status", Recipient: me, Started: base.Add(time.Second)})
	a.record(AuditEntry{Request: "someone-else", Peer: "friend-user-id", Resource: "agent", Action: "agent.ask", Recipient: "another-user", Started: base.Add(2 * time.Second)})
	a.record(AuditEntry{Request: "unverified", Peer: "friend-user-id", Resource: "agent", Action: "agent.ask", Recipient: me, Unverified: true, Started: base.Add(3 * time.Second)})
	for _, text := range []string{"looking", "done"} {
		if _, err = call(t, h, "comment", input{Request: "received-ask", Text: text}); err != "" {
			t.Fatalf("comment: %s", err)
		}
	}

	rows := listThreads(t, a)
	if len(rows) != 2 {
		t.Fatalf("want the consult and the received request only, got %+v", rows)
	}
	got, consult := rows[0], rows[1]
	if got.Request != "received-ask" || got.Direction != "received" || got.Peer != "friend-user-id" || got.Handle != "sam" ||
		got.Title != "agent.ask" || got.Comments == nil || *got.Comments != 2 || got.LastCommentAt == nil || got.LastCommentAt.IsZero() {
		t.Fatalf("received row: %+v", got)
	}
	if consult.Request != sent.Request || consult.Direction != "sent" || consult.Action != "agent.ask" || consult.Title != "Is the build green?" ||
		consult.Resource != "shared" || consult.Peer != "" || consult.Comments != nil || consult.LastCommentAt != nil {
		t.Fatalf("sent consult row: %+v", consult)
	}
}

func TestThreadsNewestFirstAndCapped(t *testing.T) {
	a := newRequester(t, nil, false, func(control.Child, json.RawMessage) any { return nil })
	me := a.creds.Session.User
	base := time.Date(2026, 11, 1, 9, 0, 0, 0, time.UTC)
	for i := range 60 {
		a.record(AuditEntry{Request: fmt.Sprintf("req-%02d", i), Peer: "friend-user-id", Resource: "agent", Action: "agent.review", Recipient: me, Started: base.Add(time.Duration(i) * time.Minute)})
	}
	// A later audit row for the same request appears once.
	a.record(AuditEntry{Request: "req-59", Peer: "friend-user-id", Resource: "agent", Action: "agent.review", Recipient: me, Started: base.Add(time.Hour)})
	rows := listThreads(t, a)
	if len(rows) != 50 {
		t.Fatalf("want 50 rows, got %d", len(rows))
	}
	if rows[0].Request != "req-59" || !rows[0].At.Equal(base.Add(time.Hour)) || rows[1].Request != "req-58" || rows[49].Request != "req-10" {
		t.Fatalf("order: first %+v, second %+v, last %+v", rows[0], rows[1], rows[49])
	}
	for i := 1; i < len(rows); i++ {
		if rows[i].At.After(rows[i-1].At) {
			t.Fatalf("row %d is newer than row %d", i, i-1)
		}
		if rows[i].Comments == nil || *rows[i].Comments != 0 || rows[i].LastCommentAt != nil {
			t.Fatalf("row without comments: %+v", rows[i])
		}
	}
}

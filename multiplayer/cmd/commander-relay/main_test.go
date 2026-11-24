package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/devicekeys"
	"agentcommander.network/pilot/internal/identity"
	"agentcommander.network/pilot/internal/testpilot"
	"github.com/nats-io/nats.go"
)

func TestTwoEdgeNetwork(t *testing.T) {
	p := testpilot.Start(t)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	type device struct {
		identity.Client
		key     *devicekeys.Keys
		session identity.Session
		pub     devicekeys.Public
	}
	login := func(user string, edge int) device {
		key, err := devicekeys.Generate()
		if err != nil {
			t.Fatal(err)
		}
		cli := identity.Client{BaseURL: p.Edges[edge], HTTP: p.Client(t, key), OIDCHTTP: p.OIDCHTTP()}
		t.Cleanup(cli.OIDCHTTP.CloseIdleConnections)
		sess, err := cli.Login(ctx, key, p.Browser(user))
		if err != nil {
			t.Fatal(err)
		}
		pub, err := key.Public()
		if err != nil {
			t.Fatal(err)
		}
		pub.User = sess.User
		return device{cli, key, sess, pub}
	}
	a, b := login("alice", 0), login("bob", 1)
	b2 := login("bob", 0)
	if a.session.User == b.session.User || b2.session.User != b.session.User || b2.session.Device == b.session.Device {
		t.Fatal("two-user/device enrollment failed")
	}
	call := func(d device, edge int, method, path string, in any, code int) map[string]any {
		t.Helper()
		data, _ := json.Marshal(in)
		req, err := http.NewRequestWithContext(ctx, method, p.Edges[edge]+path, bytes.NewReader(data))
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Authorization", "Bearer "+d.session.AccessToken)
		req.Header.Set("Content-Type", "application/json")
		res, err := d.HTTP.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		var out map[string]any
		_ = json.NewDecoder(res.Body).Decode(&out)
		if res.StatusCode != code {
			t.Fatalf("%s %s: %d %v", method, path, res.StatusCode, out)
		}
		return out
	}
	call(a, 0, "PUT", "/v1/profile", map[string]string{"handle": "alice"}, 200)
	call(b, 1, "PUT", "/v1/profile", map[string]string{"handle": "bob"}, 200)
	call(a, 0, "POST", "/v1/friends/bob", nil, 200)
	call(b, 1, "PUT", "/v1/friends/alice", nil, 200)
	exp := time.Now().Add(time.Hour).UTC().Truncate(time.Microsecond)
	lease := func(d device, edge int) map[string]any {
		fresh := call(d, edge, "POST", "/v1/session", nil, 200)
		proof := map[string]any{"session": fresh["session"], "generation": fresh["generation"]}
		call(d, 1-edge, "PUT", "/v1/session", proof, 200)
		return proof
	}
	leaseB := lease(b, 1)
	leaseB2 := lease(b2, 0)
	nc, err := nats.Connect(p.BrokerURL)
	if err != nil {
		t.Fatal(err)
	}
	defer nc.Close()
	observed := make(chan *nats.Msg, 8)
	sub, err := nc.ChanSubscribe("commander.v1.edge.*", observed)
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Unsubscribe()
	if err = nc.Flush(); err != nil {
		t.Fatal(err)
	}
	var children []map[string]any
	targets := []device{b, b2, b}
	for i, id := range []string{"loom", "lathe", "mill"} {
		d := targets[i]
		base := "/v1/resources/" + id
		call(d, i%2, "PUT", base, map[string]any{"kind": "agent", "name": id, "actions": []string{"ask.v1"}}, 200)
		call(d, 1-i%2, "PUT", "/v1/grants/"+id+"/alice", map[string]any{"actions": []string{"ask.v1"}, "max_uses": 1, "expires_at": exp}, 200)
		peer, err := a.Lookup(ctx, a.session.AccessToken, d.session.Device)
		if err != nil {
			t.Fatal(err)
		}
		header := devicekeys.Header{Sender: a.session.User, SenderDevice: a.session.Device, Recipient: d.session.User, RecipientDevice: d.session.Device, Operation: id, Resource: id, Action: "ask.v1", Kind: "request", ExpiresAt: exp}
		sealed, err := a.key.Seal(peer, header, json.RawMessage(`{"question":"schedule"}`))
		if err != nil {
			t.Fatal(err)
		}
		children = append(children, map[string]any{"id": id, "resource": id, "device": d.session.Device, "envelope": sealed, "action": "ask.v1", "expires_at": exp})
	}
	in := map[string]any{"id": "batch", "children": children}
	call(a, 0, "POST", "/v1/submissions", in, 200)
	call(a, 1, "POST", "/v1/submissions", in, 200)
	hints := map[string]int{}
	for range children {
		select {
		case msg := <-observed:
			hints[msg.Subject+" "+string(msg.Data)]++
		case <-ctx.Done():
			t.Fatal("missing JetStream delivery wake")
		}
	}
	if hints["commander.v1.edge.pilot-2 "+b.session.Device] != 2 || hints["commander.v1.edge.pilot-1 "+b2.session.Device] != 1 {
		t.Fatal("each edge should see only its addressed device wake")
	}
	bound := map[string]any{"session": leaseB["session"], "generation": leaseB["generation"]}
	for i, id := range []string{"loom", "lathe", "mill"} {
		d := targets[i]
		proof := bound
		if i == 1 {
			proof = leaseB2
		}
		out := call(d, i%2, "POST", "/v1/children/"+id+"/claim", proof, 200)
		if !out["claimed"].(bool) {
			t.Fatal("missing first claim")
		}
		c := out["child"].(map[string]any)
		peer, err := d.Lookup(ctx, d.session.AccessToken, c["sender_device"].(string))
		if err != nil {
			t.Fatal(err)
		}
		h := devicekeys.Header{Sender: peer.User, SenderDevice: peer.Device, Recipient: d.pub.User, RecipientDevice: d.pub.Device, Operation: id, Resource: id, Action: "ask.v1", Kind: "request", ExpiresAt: exp}
		raw, _ := json.Marshal(c["envelope"])
		got, err := d.key.Open(peer, h, raw)
		if err != nil || !bytes.Contains(got, []byte("schedule")) {
			t.Fatalf("device could not decrypt its addressed child: %v", err)
		}
		h.Sender, h.Recipient = h.Recipient, h.Sender
		h.SenderDevice, h.RecipientDevice = h.RecipientDevice, h.SenderDevice
		h.Kind = "result"
		result, err := d.key.Seal(peer, h, json.RawMessage(`{"ok":true}`))
		if err != nil {
			t.Fatal(err)
		}
		call(d, 1-i%2, "PUT", "/v1/children/"+id+"/receipt", map[string]any{"session": proof["session"], "generation": proof["generation"], "status": "completed", "result": result}, 200)
	}
	final := call(a, 0, "GET", "/v1/submissions/batch", nil, 200)["children"].([]any)
	public := map[string]devicekeys.Public{b.pub.Device: b.pub, b2.pub.Device: b2.pub}
	for _, v := range final {
		c := v.(map[string]any)
		if c["status"] != "completed" {
			t.Fatal("child outcome lost")
		}
		peer := public[c["device"].(string)]
		h := devicekeys.Header{Sender: peer.User, SenderDevice: peer.Device, Recipient: a.pub.User, RecipientDevice: a.pub.Device, Operation: c["id"].(string), Resource: c["resource"].(string), Action: "ask.v1", Kind: "result", ExpiresAt: exp}
		raw, err := json.Marshal(c["result"])
		if err != nil {
			t.Fatal(err)
		}
		got, err := a.key.Open(peer, h, raw)
		if err != nil || string(got) != `{"ok":true}` {
			t.Fatalf("originator could not verify receipt %s: %v", h.Operation, err)
		}
	}

	queue := func(sender, recipient device, parent, child, resource string) {
		t.Helper()
		h := devicekeys.Header{Sender: sender.pub.User, SenderDevice: sender.pub.Device, Recipient: recipient.pub.User,
			RecipientDevice: recipient.pub.Device, Operation: child, Resource: resource, Action: "ask.v1", Kind: "request", ExpiresAt: exp}
		payload, err := sender.key.Seal(recipient.pub, h, json.RawMessage(`{"question":"keep working"}`))
		if err != nil {
			t.Fatal(err)
		}
		call(sender, 0, "POST", "/v1/submissions", map[string]any{"id": parent, "children": []map[string]any{{
			"id": child, "device": recipient.pub.Device, "resource": resource, "action": "ask.v1", "expires_at": exp, "envelope": payload,
		}}}, 200)
	}
	share := func(owner device, resource string, uses int) {
		t.Helper()
		call(owner, 1, "PUT", "/v1/resources/"+resource, map[string]any{"kind": "agent", "name": resource, "actions": []string{"ask.v1"}}, 200)
		call(owner, 0, "PUT", "/v1/grants/"+resource+"/alice", map[string]any{"actions": []string{"ask.v1"}, "max_uses": uses, "expires_at": exp}, 200)
	}
	a2 := login("alice", 1)
	share(b, "spindle", 2)
	queue(a2, b, "old-sender", "old-child", "spindle")
	if err := a.Revoke(ctx, a.session.AccessToken, a2.pub.Device); err != nil {
		t.Fatal(err)
	}
	stale := call(b, 1, "POST", "/v1/children/old-child/claim", bound, 200)
	if stale["claimed"] != false || stale["child"].(map[string]any)["status"] != "revoked" {
		t.Fatalf("revoked sender's queued child remained executable: %v", stale)
	}
	call(a2, 1, "POST", "/v1/session", nil, 401)
	queue(a, b, "from-sibling", "admitted-child", "spindle")
	queue(a, b, "still-pending", "pending-child", "spindle")
	if outcome := call(b, 1, "POST", "/v1/children/admitted-child/claim", bound, 200); outcome["claimed"] != true {
		t.Fatalf("the healthy sibling device's work was interrupted: %v", outcome)
	}
	if err := b2.Revoke(ctx, b2.session.AccessToken, b.pub.Device); err != nil {
		t.Fatal(err)
	}
	childStatus := func(parent string) any {
		t.Helper()
		result := call(a, 1, "GET", "/v1/submissions/"+parent, nil, 200)
		return result["children"].([]any)[0].(map[string]any)["status"]
	}
	if childStatus("from-sibling") != "uncertain" || childStatus("still-pending") != "revoked" {
		t.Fatal("executor revocation lost an admitted outcome or left pending work open")
	}
	call(b, 0, "PUT", "/v1/session", bound, 401)
	call(b2, 1, "PUT", "/v1/session", leaseB2, 200)
	for _, raw := range call(a, 0, "GET", "/v1/resources", nil, 200)["resources"].([]any) {
		if raw.(map[string]any)["device"] == b.pub.Device {
			t.Fatal("discovery retained a revoked executor")
		}
	}
}

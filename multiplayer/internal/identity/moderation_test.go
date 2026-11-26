package identity

import (
	"errors"
	"net/http"
	"slices"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/devicekeys"
	"github.com/go-jose/go-jose/v4/jwt"
)

func TestAdminModeration(t *testing.T) {
	ctx := t.Context()
	pool := identityTestPool(t)
	f := issuer(t, "")
	auth, err := New(ctx, pool, Config{Issuer: f.URL, ClientID: "native", AllowLoopbackHTTP: true, Admins: []string{"owner@example.test"}})
	if err != nil {
		t.Fatal(err)
	}
	s, err := control.New(ctx, pool, "moderation", auth.Authenticate, auth.DeviceActive)
	if err != nil {
		t.Fatal(err)
	}
	if err = auth.SetRevocationHandler(ctx, control.RevokeDevice); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	auth.Register(mux)
	mux.Handle("/v1/", s.Handler())
	edge := identityEdge(t, mux)

	type device struct {
		Client
		keys *devicekeys.Keys
		Session
	}
	newDevice := func() *device {
		c, k := identityClient(t, edge)
		return &device{Client: c, keys: k}
	}
	check := func(call string, err error, status int) {
		t.Helper()
		if status == 200 && err == nil {
			return
		}
		var httpErr HTTPError
		if errors.As(err, &httpErr) && httpErr.Status == status {
			return
		}
		t.Fatalf("%s: expected %d, got %v", call, status, err)
	}
	request := func(d *device, method, path string, in, out any, status int) {
		t.Helper()
		check(method+" "+path, d.request(ctx, method, path, d.AccessToken, in, out), status)
	}
	enroll := func(d *device, subject, email string, verified bool, status int) {
		t.Helper()
		pub, err := d.keys.Public()
		if err != nil {
			t.Fatal(err)
		}
		var ch challenge
		check("enrollment challenge", d.request(ctx, "POST", "/v1/auth/challenge", "", map[string]any{"public": pub}, &ch), 200)
		proof, err := jwt.Signed(f.signer).Claims(map[string]any{"iss": f.name, "sub": subject, "aud": "native", "exp": time.Now().Add(time.Hour).Unix(),
			"nonce": ch.Nonce, "email": email, "email_verified": verified}).Serialize()
		if err != nil {
			t.Fatal(err)
		}
		var session Session
		check("enrollment finish", d.request(ctx, "POST", "/v1/auth/finish", "", map[string]string{"id_token": proof}, &session), status)
		if status == 200 {
			d.Session = session
		}
	}
	admin, member, sibling, unverified := newDevice(), newDevice(), newDevice(), newDevice()
	enroll(admin, "manager", "OWNER@Example.Test", true, 200)
	enroll(member, "dev", "member@example.test", true, 200)
	enroll(sibling, "dev", "member@example.test", true, 200)
	enroll(unverified, "other", "owner@example.test", false, 200)
	request(admin, "PUT", "/v1/profile", map[string]string{"handle": "manager"}, nil, 200)
	request(member, "PUT", "/v1/profile", map[string]string{"handle": "member"}, nil, 200)
	const suspend = "/v1/admin/members/member/suspend"
	const unsuspend = "/v1/admin/members/member/unsuspend"
	revoke := "/v1/admin/devices/" + member.Device
	for _, nonAdmin := range []*device{unverified, member} {
		request(nonAdmin, "POST", suspend, nil, nil, 403)
		request(nonAdmin, "POST", unsuspend, nil, nil, 403)
		request(nonAdmin, "DELETE", revoke, nil, nil, 403)
	}
	open := func(d *device) map[string]any {
		t.Helper()
		var lease control.Lease
		request(d, "POST", "/v1/session", nil, &lease, 200)
		proof := map[string]any{"session": lease.Session, "generation": lease.Generation}
		request(d, "PUT", "/v1/session", proof, nil, 200)
		return proof
	}
	memberLease, siblingLease := open(member), open(sibling)
	roster := func() AdminRoster {
		t.Helper()
		var v AdminRoster
		request(admin, "GET", "/v1/admin/members", nil, &v, 200)
		return v
	}
	findDevice := func(v AdminRoster, id string) (AdminDevice, bool) {
		for _, d := range v.Devices {
			if d.ID == id {
				return d, true
			}
		}
		return AdminDevice{}, false
	}
	for _, nonAdmin := range []*device{unverified, member} {
		request(nonAdmin, "GET", "/v1/admin/members", nil, nil, 403)
	}
	first := roster()
	if len(first.Members) != 3 || first.Members[0] != (AdminMember{"manager", false, true}) ||
		first.Members[1] != (AdminMember{"member", false, false}) || first.Members[2] != (AdminMember{"", false, false}) {
		t.Fatalf("roster members: %+v", first.Members)
	}
	if len(first.Devices) != 4 {
		t.Fatalf("roster devices: %+v", first.Devices)
	}
	if d, ok := findDevice(first, member.Device); !ok || d.Owner != "member" || !d.Online || d.LastSeen != nil || d.Name != "" {
		t.Fatalf("online member device: %+v", d)
	}
	if d, ok := findDevice(first, admin.Device); !ok || d.Owner != "manager" || d.Online || d.LastSeen != nil {
		t.Fatalf("admin device without a session: %+v", d)
	}
	request(admin, "POST", "/v1/friends/member", nil, nil, 200)
	request(member, "PUT", "/v1/friends/manager", nil, nil, 200)
	request(member, "PUT", "/v1/resources/worker", map[string]any{"kind": "agent", "name": "Worker", "actions": []string{"ask"}}, nil, 200)
	expires := time.Now().Add(time.Hour)
	request(member, "PUT", "/v1/grants/worker/manager", map[string]any{"actions": []string{"ask"}, "expires_at": expires, "max_uses": 10}, nil, 200)
	submit := func(id string) {
		t.Helper()
		request(admin, "POST", "/v1/submissions", map[string]any{"id": id, "children": []map[string]any{{"id": id, "resource": "worker", "device": member.Device, "action": "ask", "expires_at": expires, "envelope": "a..b.c.d"}}}, nil, 200)
	}
	status := func(id, want string) {
		t.Helper()
		var v control.Submission
		request(admin, "GET", "/v1/submissions/"+id, nil, &v, 200)
		if len(v.Children) != 1 || v.Children[0].Status != want {
			t.Fatalf("submission %s: want %s, got %+v", id, want, v.Children)
		}
	}
	submit("pending")
	submit("running")
	request(member, "POST", "/v1/children/running/claim", memberLease, nil, 200)

	exec := func(query string) {
		t.Helper()
		if _, err := pool.Exec(ctx, query); err != nil {
			t.Fatal(err)
		}
	}
	// An event-store failure must roll back credentials, work and lease retirement together.
	exec("ALTER TABLE mp_events ADD CONSTRAINT fail_moderation CHECK(kind NOT IN ('member.suspended','device.revoked'))")
	request(admin, "POST", suspend, nil, nil, 503)
	request(admin, "DELETE", revoke, nil, nil, 503)
	request(member, "PUT", "/v1/session", memberLease, nil, 200)
	request(sibling, "PUT", "/v1/session", siblingLease, nil, 200)
	status("pending", "pending")
	status("running", "processing")
	exec("ALTER TABLE mp_events DROP CONSTRAINT fail_moderation")

	deniedCredentials := func(d *device) {
		t.Helper()
		request(d, "GET", "/v1/me", nil, nil, 401)
		_, err := d.Refresh(ctx, d.RefreshToken)
		check("refresh", err, 401)
	}
	request(admin, "POST", suspend, nil, nil, 200)
	request(admin, "POST", suspend, nil, nil, 200)
	deniedCredentials(member)
	deniedCredentials(sibling)
	enroll(newDevice(), "dev", "member@example.test", true, 403)
	status("pending", "revoked")
	status("running", "uncertain")
	suspended := roster()
	if suspended.Members[1] != (AdminMember{"member", true, false}) {
		t.Fatalf("suspended roster: %+v", suspended.Members)
	}
	if d, ok := findDevice(suspended, sibling.Device); !ok || d.Online || d.LastSeen == nil {
		t.Fatalf("fenced sibling device: %+v", d)
	}
	request(admin, "POST", unsuspend, nil, nil, 200)
	deniedCredentials(member)
	deniedCredentials(sibling)
	enroll(member, "dev", "member@example.test", true, 200)
	enroll(sibling, "dev", "member@example.test", true, 200)
	request(member, "PUT", "/v1/session", memberLease, nil, 409)
	request(sibling, "PUT", "/v1/session", siblingLease, nil, 409)

	open(member)
	siblingLease = open(sibling)
	submit("pending-again")
	request(admin, "DELETE", revoke, nil, nil, 200)
	request(admin, "DELETE", revoke, nil, nil, 200)
	deniedCredentials(member)
	enroll(member, "dev", "member@example.test", true, 403)
	request(sibling, "PUT", "/v1/session", siblingLease, nil, 200)
	status("pending-again", "revoked")
	if _, listed := findDevice(roster(), member.Device); listed {
		t.Fatal("revoked device is still listed")
	}
	var live bool
	if err := pool.QueryRow(ctx, "SELECT ready OR expires_at>now() FROM mp_leases WHERE device=$1", member.Device).Scan(&live); err != nil || live {
		t.Fatalf("revoked device lease is live=%t, err=%v", live, err)
	}
	var feed struct{ Events []control.Event }
	request(sibling, "GET", "/v1/events", nil, &feed, 200)
	var kinds []string
	for _, event := range feed.Events {
		switch event.Kind {
		case "device.revoked":
			if event.Resource != member.Device {
				t.Fatalf("wrong revoked device: %+v", event)
			}
		case "member.suspended", "member.unsuspended":
		default:
			continue
		}
		if event.Actor != "manager" {
			t.Fatalf("wrong moderator: %+v", event)
		}
		kinds = append(kinds, event.Kind)
	}
	if !slices.Equal(kinds, []string{"member.suspended", "member.unsuspended", "device.revoked"}) {
		t.Fatalf("moderation feed: %v", kinds)
	}
}

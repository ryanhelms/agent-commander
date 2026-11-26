package device

import (
	"encoding/json"
	"testing"
	"time"
)

func TestInviteLinkRoundTrip(t *testing.T) {
	link := InviteLink("https://ryan-mac.tail.internal:8443", "sha256/abc+/=", "CODE1", "ryan")
	inv, err := ParseInvite(link)
	if err != nil {
		t.Fatal(err)
	}
	if inv.Server != "https://ryan-mac.tail.internal:8443" || inv.Pin != "sha256/abc+/=" || inv.Code != "CODE1" || inv.From != "ryan" {
		t.Fatalf("round trip: %+v from %s", inv, link)
	}
	for _, bad := range []string{"https://join?server=x", "agentcommander://other?server=relay", "agentcommander://join?server=http://relay", "agentcommander://join?server=relay&pin=md5/x"} {
		if _, err := ParseInvite(bad); err == nil {
			t.Errorf("accepted %q", bad)
		}
	}
}

func TestAutoPresence(t *testing.T) {
	if AutoPresence(true, time.Hour) != "busy" || AutoPresence(false, 11*time.Minute) != "away" || AutoPresence(false, time.Minute) != "online" {
		t.Fatal("unexpected automatic presence")
	}
}

func TestActivityMergesAndMarksSeen(t *testing.T) {
	m := testManager(t)
	h := m.Handler()
	for _, url := range []string{"a.example.test", "b.example.test"} {
		if _, e := call(t, h, "server-add", map[string]any{"url": url}); e != "" {
			t.Fatal(e)
		}
	}
	now := time.Now()
	i := 0
	m.mu.Lock()
	for _, a := range m.agents {
		i++
		a.mu.Lock()
		a.social.Events = []Event{{Seq: 1, At: now.Add(time.Duration(i) * time.Minute), Kind: "friend.request", Actor: "sam"}}
		a.social.After = 1
		a.mu.Unlock()
	}
	m.mu.Unlock()
	data, e := call(t, h, "activity", map[string]any{})
	if e != "" {
		t.Fatal(e)
	}
	var res struct {
		Events []Event
		Cursor string
		Unseen int
	}
	if err := jsonUnmarshal(data, &res); err != nil || len(res.Events) != 2 || res.Unseen != 2 || !res.Events[0].At.After(res.Events[1].At) || res.Events[0].Server == "" {
		t.Fatalf("activity: %+v %v", res, err)
	}
	if _, e = call(t, h, "activity-seen", map[string]any{"cursor": res.Cursor}); e != "" {
		t.Fatal(e)
	}
	data, _ = call(t, h, "activity", map[string]any{})
	jsonUnmarshal(data, &res)
	if res.Unseen != 0 {
		t.Fatalf("unseen after marking: %d", res.Unseen)
	}
}

func jsonUnmarshal(b []byte, v any) error { return json.Unmarshal(b, v) }

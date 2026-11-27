package device

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

func TestMembershipRequestVerbs(t *testing.T) {
	var mu sync.Mutex
	post, mine := http.StatusOK, http.StatusOK
	status := "pending"
	var note string
	relay := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch r.Method + " " + r.URL.Path {
		case "POST /v1/membership-requests":
			var in struct{ Note string }
			json.NewDecoder(r.Body).Decode(&in)
			note = in.Note
			w.WriteHeader(post)
			json.NewEncoder(w).Encode(map[string]any{"id": "req1", "status": "pending", "note": in.Note, "createdAt": "2026-11-27T12:00:00Z"})
		case "GET /v1/membership-requests/mine":
			w.WriteHeader(mine)
			json.NewEncoder(w).Encode(map[string]any{"id": "req1", "status": status, "createdAt": "2026-11-27T12:00:00Z"})
		default:
			http.NotFound(w, r)
		}
	}))
	defer relay.Close()
	m := testManager(t)
	h := m.Handler()
	data, e := call(t, h, "server-add", map[string]any{"url": relay.URL, "pin": SPKIPin(relay.Certificate())})
	if e != "" {
		t.Fatal(e)
	}
	var s ServerSummary
	json.Unmarshal(data, &s)
	accessState := func() string {
		t.Helper()
		data, e := call(t, h, "status", map[string]any{"server": s.ID})
		if e != "" {
			t.Fatal(e)
		}
		var st struct{ AccessRequest string }
		json.Unmarshal(data, &st)
		return st.AccessRequest
	}
	if got := accessState(); got != "" {
		t.Fatalf("initial access state %q", got)
	}

	data, e = call(t, h, "membership-request", map[string]any{"server": s.ID, "note": "build team"})
	if e != "" || !strings.Contains(string(data), `"status":"pending"`) || note != "build team" {
		t.Fatalf("request: %s %q note=%q", data, e, note)
	}
	if got := accessState(); got != "pending" {
		t.Fatalf("after request %q", got)
	}

	mu.Lock()
	status = "approved"
	mu.Unlock()
	if _, e = call(t, h, "membership-request-status", map[string]any{"server": s.ID}); e != "" {
		t.Fatal(e)
	}
	if got := accessState(); got != "approved" {
		t.Fatalf("after approval %q", got)
	}
	mu.Lock()
	status = "admitted"
	mu.Unlock()
	call(t, h, "membership-request-status", map[string]any{"server": s.ID})
	if got := accessState(); got != "" {
		t.Fatalf("after admission %q", got)
	}

	// No recent refusal: the person must sign in first.
	mu.Lock()
	post = http.StatusNotFound
	mu.Unlock()
	if _, e = call(t, h, "membership-request", map[string]any{"server": s.ID}); !strings.Contains(e, "sign in first") {
		t.Fatalf("without refusal: %q", e)
	}
	// A recent denial is reported as such; a full queue otherwise.
	mu.Lock()
	post, status = http.StatusTooManyRequests, "denied"
	mu.Unlock()
	if _, e = call(t, h, "membership-request", map[string]any{"server": s.ID}); !strings.Contains(e, "declined") {
		t.Fatalf("denied: %q", e)
	}
	if got := accessState(); got != "denied" {
		t.Fatalf("after denial %q", got)
	}
	mu.Lock()
	status = "pending"
	mu.Unlock()
	if _, e = call(t, h, "membership-request", map[string]any{"server": s.ID}); !strings.Contains(e, "too many pending") {
		t.Fatalf("full: %q", e)
	}
	mu.Lock()
	mine = http.StatusNotFound
	mu.Unlock()
	data, e = call(t, h, "membership-request-status", map[string]any{"server": s.ID})
	if e != "" || !strings.Contains(string(data), `"status":""`) {
		t.Fatalf("no request: %s %q", data, e)
	}
}

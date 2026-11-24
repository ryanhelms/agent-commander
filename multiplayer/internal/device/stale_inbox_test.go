package device

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/identity"
)

func TestStaleInboxKeyDoesNotInterruptTheLease(t *testing.T) {
	for _, status := range []int{http.StatusNotFound, http.StatusServiceUnavailable} {
		sender := strings.Repeat("a", 64)
		server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != "GET" || r.URL.Path != "/v1/identity/devices/"+sender {
				t.Errorf("stale inbox child tried to execute or claim: %s %s", r.Method, r.URL.Path)
			}
			w.WriteHeader(status)
		}))
		defer server.Close()
		agent := &Agent{identity: identity.Client{BaseURL: server.URL, HTTP: server.Client()}}
		session := identity.Session{User: "owner", Device: "local-device"}
		child := control.Child{Addressed: control.Addressed{ID: "old-child", Device: session.Device},
			Owner: session.User, Sender: "former-friend", SenderDevice: sender}
		err := agent.deliver(t.Context(), session, control.Lease{}, child)
		if status == http.StatusNotFound && err != nil {
			t.Fatalf("disappeared peer interrupted the recipient lease: %v", err)
		}
		var failure identity.HTTPError
		if status == http.StatusServiceUnavailable && (!errors.As(err, &failure) || failure.Status != status) {
			t.Fatalf("directory outage was silently discarded: %v", err)
		}
	}
}

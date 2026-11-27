package device

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestProbeSignInUsesRelayClient(t *testing.T) {
	for _, provided := range []bool{false, true} {
		relay := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/v1/info" {
				json.NewEncoder(w).Encode(map[string]any{"version": "1", "mode": "host", "issuer": "https://accounts.google.com",
					"clientId": "desktop.apps.googleusercontent.com", "clientSecretProvided": provided})
				return
			}
			http.NotFound(w, r)
		}))
		m := testManager(t)
		p, err := m.ProbeServer(context.Background(), relay.URL)
		relay.Close()
		if err != nil {
			t.Fatal(err)
		}
		signin := p.Steps[len(p.Steps)-1]
		if signin.Step != "signin" || signin.OK != provided || signin.ClientConfigured != provided {
			t.Fatalf("provided=%v: %+v", provided, signin)
		}
		if provided && !strings.Contains(signin.Detail, "relay provides") {
			t.Fatalf("detail: %q", signin.Detail)
		}
		if !provided && !strings.Contains(signin.Detail, "google-desktop-client.json") {
			t.Fatalf("detail: %q", signin.Detail)
		}
	}
}

package hosted

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestIntrospectionClientSecretBasic(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, password, ok := r.BasicAuth()
		if !ok || user != "commander%3Aclient+id" || password != "secret%2B%2F%3A%25%26" {
			http.Error(w, "invalid client", http.StatusUnauthorized)
			return
		}
		if r.Method != http.MethodPost || r.PostFormValue("token") != "fixture+token" ||
			r.PostFormValue("token_type_hint") != "access_token" {
			http.Error(w, "invalid token request", http.StatusBadRequest)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"active": true, "client_id": "app", "sub": "developer", "iss": "issuer",
			"aud": "commander", "exp": time.Now().Add(time.Minute).Unix(),
		})
	}))
	defer server.Close()
	gateway, err := New(Config{Introspection: server.URL, ClientID: "commander:client id",
		Issuer: "issuer", Audience: "commander"}, "secret+/:%&", "")
	if err != nil {
		t.Fatal(err)
	}
	gateway.client.Transport = server.Client().Transport
	if _, err := gateway.introspect(t.Context(), "fixture+token"); err != nil {
		t.Fatal(err)
	}
}

// Package testpilot starts disposable identity, database schema and relay processes for acceptance tests.
package testpilot

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync"
	"testing"
	"time"

	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

func randomID() string {
	var b [20]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b[:])
}
func startIssuer(t *testing.T, cert tls.Certificate) string {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.ES256, Key: k}, (&jose.SignerOptions{}).WithHeader("kid", "test"))
	if err != nil {
		t.Fatal(err)
	}
	type code struct{ sub, nonce, redirect, challenge string }
	codes := map[string]code{}
	var mu sync.Mutex
	var origin string
	jsonOut := func(w http.ResponseWriter, v any) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(v)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /.well-known/openid-configuration", func(w http.ResponseWriter, _ *http.Request) {
		jsonOut(w, map[string]any{"issuer": origin, "authorization_endpoint": origin + "/authorize", "token_endpoint": origin + "/token", "jwks_uri": origin + "/keys", "id_token_signing_alg_values_supported": []string{"ES256"}})
	})
	mux.HandleFunc("GET /keys", func(w http.ResponseWriter, _ *http.Request) {
		jsonOut(w, jose.JSONWebKeySet{Keys: []jose.JSONWebKey{{Key: &k.PublicKey, KeyID: "test", Use: "sig", Algorithm: "ES256"}}})
	})
	mux.HandleFunc("GET /authorize", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		u, err := url.Parse(q.Get("redirect_uri"))
		if err != nil || u.Scheme != "http" || u.Hostname() != "127.0.0.1" || u.Path != "" || q.Get("client_id") != "pilot-fixture" || q.Get("code_challenge_method") != "S256" || q.Get("test_account") == "" || q.Get("nonce") == "" || q.Get("state") == "" || q.Get("response_type") != "code" {
			http.Error(w, "invalid native flow", 400)
			return
		}
		id := randomID()
		mu.Lock()
		codes[id] = code{q.Get("test_account"), q.Get("nonce"), u.String(), q.Get("code_challenge")}
		mu.Unlock()
		u.RawQuery = url.Values{"state": {q.Get("state")}, "code": {id}, "iss": {origin}}.Encode()
		http.Redirect(w, r, u.String(), 302)
	})
	mux.HandleFunc("POST /token", func(w http.ResponseWriter, r *http.Request) {
		id := r.FormValue("code")
		mu.Lock()
		record, ok := codes[id]
		delete(codes, id)
		mu.Unlock()
		hash := sha256.Sum256([]byte(r.FormValue("code_verifier")))
		if !ok || r.FormValue("client_id") != "pilot-fixture" || record.challenge != base64.RawURLEncoding.EncodeToString(hash[:]) || r.FormValue("redirect_uri") != record.redirect || r.FormValue("grant_type") != "authorization_code" {
			http.Error(w, "invalid exchange", 400)
			return
		}
		token, err := jwt.Signed(signer).Claims(map[string]any{"iss": origin, "sub": record.sub, "aud": "pilot-fixture", "nonce": record.nonce, "iat": time.Now().Unix(), "exp": time.Now().Add(time.Hour).Unix()}).Serialize()
		if err != nil {
			http.Error(w, "issuance failed", 500)
			return
		}
		jsonOut(w, map[string]any{"token_type": "Bearer", "access_token": "test", "id_token": token, "expires_in": 3600})
	})
	srv := httptest.NewUnstartedServer(mux)
	srv.TLS = &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS13}
	origin = "https://" + srv.Listener.Addr().String()
	srv.StartTLS()
	t.Cleanup(srv.Close)
	return origin
}

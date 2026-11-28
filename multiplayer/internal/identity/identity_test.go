package identity

import (
	"bytes"
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/devicekeys"
	"github.com/coreos/go-oidc/v3/oidc"
	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type codeRecord struct{ challenge, nonce, redirect string }

const googleDesktopFixtureSecret = "test-only"

type testIssuer struct {
	*httptest.Server
	mu     sync.Mutex
	codes  map[string]codeRecord
	signer jose.Signer
	name   string
}

func issuer(t *testing.T, name string) *testIssuer {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	f := &testIssuer{codes: map[string]codeRecord{}, name: name}
	f.signer, err = jose.NewSigner(jose.SigningKey{Algorithm: jose.ES256, Key: k}, (&jose.SignerOptions{}).WithHeader("kid", "fixture"))
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /.well-known/openid-configuration", func(w http.ResponseWriter, r *http.Request) {
		reply(w, 200, map[string]any{"issuer": f.name, "authorization_endpoint": f.URL + "/authorize", "token_endpoint": f.URL + "/token", "jwks_uri": f.URL + "/keys", "id_token_signing_alg_values_supported": []string{"ES256"}, "code_challenge_methods_supported": []string{"S256"}})
	})
	mux.HandleFunc("GET /keys", func(w http.ResponseWriter, r *http.Request) {
		reply(w, 200, jose.JSONWebKeySet{Keys: []jose.JSONWebKey{{Key: &k.PublicKey, KeyID: "fixture", Use: "sig", Algorithm: "ES256"}}})
	})
	mux.HandleFunc("GET /authorize", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		u, err := url.Parse(q.Get("redirect_uri"))
		if err != nil || u.Scheme != "http" || u.Hostname() != "127.0.0.1" || u.Path != "" || q.Get("client_id") != "native" || q.Get("response_type") != "code" || q.Get("code_challenge_method") != "S256" || q.Get("state") == "" || q.Get("nonce") == "" {
			failure(w, 400)
			return
		}
		code, err := token()
		if err != nil {
			failure(w, 500)
			return
		}
		f.mu.Lock()
		f.codes[code] = codeRecord{q.Get("code_challenge"), q.Get("nonce"), u.String()}
		f.mu.Unlock()
		params := u.Query()
		params.Set("state", q.Get("state"))
		params.Set("code", code)
		params.Set("iss", f.name)
		u.RawQuery = params.Encode()
		http.Redirect(w, r, u.String(), 302)
	})
	mux.HandleFunc("POST /token", func(w http.ResponseWriter, r *http.Request) {
		want := ""
		if f.name == googleIssuer {
			want = googleDesktopFixtureSecret
		}
		if r.FormValue("client_secret") != want {
			failure(w, 400)
			return
		}
		code := r.FormValue("code")
		f.mu.Lock()
		saved, ok := f.codes[code]
		delete(f.codes, code)
		f.mu.Unlock()
		sum := sha256.Sum256([]byte(r.FormValue("code_verifier")))
		if !ok || r.FormValue("grant_type") != "authorization_code" || base64.RawURLEncoding.EncodeToString(sum[:]) != saved.challenge || r.FormValue("redirect_uri") != saved.redirect || r.FormValue("client_id") != "native" {
			failure(w, 400)
			return
		}
		proof, err := f.issue("tester", saved.nonce, "native", time.Now().Add(time.Hour))
		if err != nil {
			failure(w, 500)
			return
		}
		reply(w, 200, map[string]any{"access_token": "fixture-access", "token_type": "Bearer", "id_token": proof, "expires_in": 3600})
	})
	f.Server = httptest.NewServer(mux)
	if f.name == "" {
		f.name = f.URL
	}
	t.Cleanup(f.Close)
	return f
}
func (f *testIssuer) issue(subject, nonce, audience string, expires time.Time) (string, error) {
	return jwt.Signed(f.signer).Claims(map[string]any{"iss": f.name, "sub": subject, "aud": audience, "exp": expires.Unix(), "iat": time.Now().Unix(), "nonce": nonce, "email": subject + "@example.test", "email_verified": true}).Serialize()
}
func simulatedBrowser(raw string) error {
	res, err := http.Get(raw)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return HTTPError{Status: res.StatusCode}
	}
	return nil
}
func TestBrowserLoginUsesLoopbackNonceAndS256(t *testing.T) {
	t.Run("Generic OIDC", func(t *testing.T) { testBrowserLogin(t, "") })
	t.Run("Google", func(t *testing.T) { testBrowserLogin(t, googleIssuer) })
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func testBrowserLogin(t *testing.T, issuerName string) {
	f := issuer(t, issuerName)
	k, err := devicekeys.Generate()
	if err != nil {
		t.Fatal(err)
	}
	pub, err := k.Public()
	if err != nil {
		t.Fatal(err)
	}
	nonce, err := token()
	if err != nil {
		t.Fatal(err)
	}
	local, err := url.Parse(f.URL)
	if err != nil {
		t.Fatal(err)
	}
	httpClient := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.String() == googleIssuer+"/.well-known/openid-configuration" {
			r = r.Clone(r.Context())
			r.URL.Scheme, r.URL.Host, r.Host = local.Scheme, local.Host, local.Host
		}
		if r.URL.Scheme != local.Scheme || r.URL.Host != local.Host {
			return nil, errors.New("fixture OIDC request left loopback")
		}
		return http.DefaultTransport.RoundTrip(r)
	})}
	p, err := discover(t.Context(), Config{Issuer: f.name, ClientID: "native", HTTPClient: httpClient, AllowLoopbackHTTP: true})
	if err != nil {
		t.Fatal(err)
	}
	v := p.Verifier(&oidc.Config{ClientID: "native"})
	mux := http.NewServeMux()
	var denyEnrollment atomic.Bool
	mux.HandleFunc("POST /v1/auth/challenge", func(w http.ResponseWriter, r *http.Request) {
		reply(w, 200, challenge{Nonce: nonce, Issuer: f.name, ClientID: "native"})
	})
	mux.HandleFunc("POST /v1/auth/finish", func(w http.ResponseWriter, r *http.Request) {
		var b struct {
			Token string `json:"id_token"`
		}
		if err := json.NewDecoder(r.Body).Decode(&b); err != nil {
			failure(w, 400)
			return
		}
		tok, err := v.Verify(r.Context(), b.Token)
		if err != nil || tok.Nonce != nonce || tok.Subject != "tester" {
			failure(w, 401)
			return
		}
		if denyEnrollment.Load() {
			failure(w, 403)
			return
		}
		sess, err := credentials("native-user", pub.Device)
		if err != nil {
			failure(w, 500)
			return
		}
		reply(w, 200, sess)
	})
	edge := httptest.NewTLSServer(mux)
	defer edge.Close()
	client := Client{BaseURL: edge.URL, HTTP: edge.Client(), OIDCHTTP: httpClient, AllowLoopbackHTTP: true}
	if issuerName == googleIssuer {
		client.GoogleDesktopConfig = filepath.Join(t.TempDir(), "google-desktop-client.json")
		unexpectedBrowser := func(string) error {
			t.Error("browser opened before the Google Desktop credentials were validated")
			return errors.New("unexpected browser")
		}
		_, err := client.Login(t.Context(), k, unexpectedBrowser)
		if err == nil || !strings.Contains(err.Error(), "provision this Mac") {
			t.Fatalf("expected a provisioning error, got %v", err)
		}
		writeConfig := func(id string, mode os.FileMode) {
			t.Helper()
			file := []byte(`{"installed":{"client_id":"` + id + `","client_secret":"` + googleDesktopFixtureSecret + `"}}`)
			if err := os.WriteFile(client.GoogleDesktopConfig, file, mode); err != nil {
				t.Fatal(err)
			}
			if err := os.Chmod(client.GoogleDesktopConfig, mode); err != nil {
				t.Fatal(err)
			}
		}
		writeConfig("different-client", 0600)
		_, err = client.Login(t.Context(), k, unexpectedBrowser)
		if err == nil || !strings.Contains(err.Error(), "does not match") {
			t.Fatalf("expected a client ID mismatch, got %v", err)
		}
		writeConfig("native", 0644)
		_, err = client.Login(t.Context(), k, unexpectedBrowser)
		if err == nil || !strings.Contains(err.Error(), "private regular file") {
			t.Fatalf("expected a private file error, got %v", err)
		}
		writeConfig("native", 0600)
	}
	browser := func(raw string) error {
		u, err := url.Parse(raw)
		if err != nil || u.Host != local.Host {
			return errors.New("unexpected browser target")
		}
		want := ""
		if issuerName == googleIssuer {
			want = "select_account"
		}
		if u.Query().Get("prompt") != want {
			return errors.New("unexpected account selection prompt")
		}
		return simulatedBrowser(raw)
	}
	if _, err = client.Login(t.Context(), k, browser); err != nil {
		t.Fatal(err)
	}
	if issuerName == googleIssuer {
		denyEnrollment.Store(true)
		refused, err := client.Login(t.Context(), k, browser)
		if refused != (Session{}) || err == nil || !strings.Contains(err.Error(), "choose the invited account") {
			t.Fatal("refused Google enrollment did not explain how to switch accounts")
		}
		denyEnrollment.Store(false)
		if _, err := client.Login(t.Context(), k, browser); err != nil {
			t.Fatal("the invited account could not retry enrollment", err)
		}
	}
	if _, err = discover(t.Context(), Config{Issuer: f.URL, ClientID: "native"}); err == nil {
		t.Fatal("accepted insecure production issuer")
	}
}
func identityTestPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("PILOT_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set PILOT_TEST_DATABASE_URL to a disposable PostgreSQL database")
	}
	ctx := t.Context()
	admin, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(admin.Close)
	id, err := token()
	if err != nil {
		t.Fatal(err)
	}
	schema := pgx.Identifier{"identity_test_" + id}.Sanitize()
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := admin.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE"); err != nil {
			t.Error(err)
		}
	})
	cfg := admin.Config()
	cfg.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func identityEdge(t *testing.T, handler http.Handler) *httptest.Server {
	t.Helper()
	edge := httptest.NewUnstartedServer(handler)
	edge.TLS = &tls.Config{MinVersion: tls.VersionTLS13, ClientAuth: tls.RequireAnyClientCert}
	edge.StartTLS()
	t.Cleanup(edge.Close)
	return edge
}

func identityClient(t *testing.T, edge *httptest.Server) (Client, *devicekeys.Keys) {
	t.Helper()
	k, err := devicekeys.Generate()
	if err != nil {
		t.Fatal(err)
	}
	cert, err := k.TLSCertificate()
	if err != nil {
		t.Fatal(err)
	}
	transport := edge.Client().Transport.(*http.Transport).Clone()
	transport.TLSClientConfig.Certificates = []tls.Certificate{cert}
	t.Cleanup(transport.CloseIdleConnections)
	return Client{BaseURL: edge.URL, HTTP: &http.Client{Transport: transport}, AllowLoopbackHTTP: true}, k
}

func TestDurableEnrollmentRefreshAndRevoke(t *testing.T) {
	ctx := t.Context()
	pool := identityTestPool(t)
	f := issuer(t, "")
	s, err := New(ctx, pool, Config{Issuer: f.URL, ClientID: "native", AllowLoopbackHTTP: true, AllowedEmails: []string{"tester@example.test", "different-owner@example.test"}})
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	s.Register(mux)
	edge := identityEdge(t, mux)
	c, keys := identityClient(t, edge)
	other, otherkeys := identityClient(t, edge)
	session, err := c.Login(ctx, keys, simulatedBrowser)
	if err != nil {
		t.Fatal(err)
	}
	otherSession, err := other.Login(ctx, otherkeys, simulatedBrowser)
	if err != nil {
		t.Fatal(err)
	}
	if session.User != otherSession.User || session.Device == otherSession.Device {
		t.Fatal("claim identity mismatch")
	}
	if _, err = other.Lookup(ctx, session.AccessToken, session.Device); err == nil {
		t.Fatal("access token worked with another TLS key")
	}
	if _, err = other.Refresh(ctx, session.RefreshToken); err == nil {
		t.Fatal("refresh token worked with another TLS key")
	}
	old := session
	session, err = c.Refresh(ctx, old.RefreshToken)
	if err != nil {
		t.Fatal(err)
	}
	// The successor has not been used yet, so the previous token still
	// recovers a session whose response was lost. Its result replaces the
	// lost one; using it retires the previous token.
	lost := session
	session, err = c.Refresh(ctx, old.RefreshToken)
	if err != nil {
		t.Fatalf("previous refresh token before successor use: %v", err)
	}
	if _, err = c.Lookup(ctx, lost.AccessToken, session.Device); err == nil {
		t.Fatal("lost access remained valid after recovery")
	}
	if _, err = c.Refresh(ctx, lost.RefreshToken); err == nil {
		t.Fatal("lost successor was accepted after recovery")
	}
	session, err = c.Refresh(ctx, session.RefreshToken)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = c.Refresh(ctx, old.RefreshToken); err == nil {
		t.Fatal("refresh reused after its successor was used")
	}
	if _, err = c.Lookup(ctx, old.AccessToken, session.Device); err == nil {
		t.Fatal("superseded access remained valid")
	}
	if p, err := c.Lookup(ctx, session.AccessToken, session.Device); err != nil || p.User != session.User {
		t.Fatalf("lookup failed %v", err)
	}
	if err = other.Revoke(ctx, otherSession.AccessToken, session.Device); err != nil {
		t.Fatal(err)
	}
	if _, err = c.Refresh(ctx, session.RefreshToken); err == nil {
		t.Fatal("revoked device refreshed")
	}
	if _, err = c.Login(ctx, keys, simulatedBrowser); err == nil {
		t.Fatal("revoked device re-enrolled")
	}
	// The other device's ordinary sign-out invalidates both credentials. Its keys
	// can enroll again after a new browser login.
	if err = other.SignOut(ctx, otherSession.AccessToken); err != nil {
		t.Fatal(err)
	}
	if _, err = other.Refresh(ctx, otherSession.RefreshToken); err == nil {
		t.Fatal("signed-out refresh was accepted")
	}
	if _, err = other.Login(ctx, otherkeys, simulatedBrowser); err != nil {
		t.Fatal(err)
	}
	// Auth metadata stored in the challenge fixes the device key and OIDC nonce.
	fresh, k := identityClient(t, edge)
	pub, _ := k.Public()
	var ch challenge
	if err = fresh.request(ctx, "POST", "/v1/auth/challenge", "", map[string]any{"public": pub}, &ch); err != nil {
		t.Fatal(err)
	}
	finish := func(nonce, sub, aud string, exp time.Time) error {
		proof, err := f.issue(sub, nonce, aud, exp)
		if err != nil {
			return err
		}
		return fresh.request(ctx, "POST", "/v1/auth/finish", "", map[string]string{"id_token": proof}, new(Session))
	}
	for _, cs := range []struct {
		n, a string
		e    time.Time
	}{{"wrong", "native", time.Now().Add(time.Hour)}, {ch.Nonce, "other", time.Now().Add(time.Hour)}, {ch.Nonce, "native", time.Now().Add(-time.Hour)}} {
		if err = finish(cs.n, "tester", cs.a, cs.e); err == nil {
			t.Fatal("accepted invalid OIDC proof")
		}
	}
	if err = finish(ch.Nonce, "uninvited", "native", time.Now().Add(time.Hour)); err == nil {
		t.Fatal("uninvited account enrolled")
	}
	if err = finish(ch.Nonce, "tester", "native", time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err = finish(ch.Nonce, "tester", "native", time.Now().Add(time.Hour)); err == nil {
		t.Fatal("challenge replayed")
	}
	if err = fresh.request(ctx, "POST", "/v1/auth/challenge", "", map[string]any{"public": pub}, &ch); err != nil {
		t.Fatal(err)
	}
	if err = finish(ch.Nonce, "different-owner", "native", time.Now().Add(time.Hour)); err == nil {
		t.Fatal("device rebound to a different owner")
	}
}

func TestPilotRequiresVerifiedEmail(t *testing.T) {
	if verifiedHash("Allowed@example.test", true) != emailHash("allowed@example.test") ||
		verifiedHash("allowed@example.test", false) != "" || verifiedHash("", true) != "" {
		t.Fatal("unexpected verified email hash")
	}
	quoted := enrollmentClaims{EmailVerified: json.RawMessage(`"true"`)}
	if _, err := quoted.emailVerified("https://issuer.example.test"); err == nil {
		t.Fatal("a generic issuer accepted a non-boolean email verification claim")
	}
}

func TestGoogleEnrollmentKeepsOneAccountAcrossIssuerSpellings(t *testing.T) {
	ctx := t.Context()
	pool := identityTestPool(t)
	local := issuer(t, "")
	s, err := New(ctx, pool, Config{Issuer: local.URL, ClientID: "native", AllowLoopbackHTTP: true, AllowedEmails: []string{"tester@example.test"}})
	if err != nil {
		t.Fatal(err)
	}
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: key}, nil)
	if err != nil {
		t.Fatal(err)
	}
	s.config.Issuer = googleIssuer
	s.verifier = oidc.NewVerifier(googleIssuer, &oidc.StaticKeySet{PublicKeys: []crypto.PublicKey{&key.PublicKey}}, &oidc.Config{ClientID: "native"})
	subject, err := token()
	if err != nil {
		t.Fatal(err)
	}
	legacyIssuer := "accounts.google.com"
	canonical, legacy := userID(googleIssuer, subject), userID(legacyIssuer, subject)

	device := func() *devicekeys.Keys {
		t.Helper()
		keys, err := devicekeys.Generate()
		if err != nil {
			t.Fatal(err)
		}
		return keys
	}
	enroll := func(keys *devicekeys.Keys, issuer string, verified any, status int) Session {
		t.Helper()
		pub, err := keys.Public()
		if err != nil {
			t.Fatal(err)
		}
		cert, err := x509.ParseCertificate(keys.Certificate)
		if err != nil {
			t.Fatal(err)
		}
		call := func(path string, payload any, handler http.HandlerFunc) *httptest.ResponseRecorder {
			t.Helper()
			data, err := json.Marshal(payload)
			if err != nil {
				t.Fatal(err)
			}
			req := httptest.NewRequestWithContext(ctx, http.MethodPost, path, bytes.NewReader(data))
			req.TLS = &tls.ConnectionState{Version: tls.VersionTLS13, PeerCertificates: []*x509.Certificate{cert}}
			out := httptest.NewRecorder()
			handler.ServeHTTP(out, req)
			return out
		}
		begin := call("/v1/auth/challenge", map[string]any{"public": pub}, s.begin)
		var ch challenge
		if begin.Code != http.StatusOK || json.Unmarshal(begin.Body.Bytes(), &ch) != nil {
			t.Fatalf("enrollment challenge failed: %d", begin.Code)
		}
		now := time.Now()
		proof, err := jwt.Signed(signer).Claims(map[string]any{
			"iss": issuer, "sub": subject, "aud": "native", "azp": "native",
			"iat": now.Unix(), "exp": now.Add(time.Minute).Unix(), "nonce": ch.Nonce,
			"email": "tester@example.test", "email_verified": verified,
		}).Serialize()
		if err != nil {
			t.Fatal(err)
		}
		out := call("/v1/auth/finish", map[string]string{"id_token": proof}, s.finish)
		if out.Code != status {
			t.Fatalf("enrollment status = %d, want %d", out.Code, status)
		}
		var session Session
		if status == http.StatusOK && json.Unmarshal(out.Body.Bytes(), &session) != nil {
			t.Fatal("invalid session")
		}
		return session
	}
	first, second := device(), device()
	firstSession := enroll(first, legacyIssuer, "true", http.StatusOK)
	if firstSession.User != canonical || enroll(second, googleIssuer, true, http.StatusOK).User != canonical {
		t.Fatal("Google issuer spellings did not select the same account")
	}
	enroll(device(), googleIssuer, "false", http.StatusForbidden)
	enroll(device(), googleIssuer, "TRUE", http.StatusUnauthorized)
	enroll(device(), "https://other.example.test", true, http.StatusUnauthorized)

	// Recreate the old ID for both devices, then a previously split account.
	replace := func(from, to, device string) {
		t.Helper()
		if _, err := pool.Exec(ctx, `UPDATE mp_auth_devices
			SET user_id=$2,descriptor=jsonb_set(descriptor,'{user}',to_jsonb($2::text))
			WHERE user_id=$1 AND ($3='' OR device=$3)`, from, to, device); err != nil {
			t.Fatal(err)
		}
	}
	replace(canonical, legacy, "")
	if enroll(first, googleIssuer, true, http.StatusOK).User != legacy {
		t.Fatal("existing legacy account was changed")
	}
	newDevice := enroll(device(), googleIssuer, "true", http.StatusOK)
	if newDevice.User != legacy {
		t.Fatal("new device did not join existing legacy account")
	}
	replace(legacy, canonical, newDevice.Device)
	if enroll(first, googleIssuer, true, http.StatusOK).User != legacy {
		t.Fatal("already-enrolled device lost access to its account")
	}
	enroll(device(), googleIssuer, true, http.StatusConflict)
}

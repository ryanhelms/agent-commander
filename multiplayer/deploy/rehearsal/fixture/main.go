//go:build pilotfixture

// The rehearsal-only OIDC provider and GitHub emulator have no published ports.
package main

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/cgi"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

const issuer = "https://issuer.rehearsal.test:8443"
const clientID = "commander-rehearsal"
const statePath = "/state/github.json"

type loginCode struct {
	Handle, Nonce, Redirect, Challenge string
	Expiry                             time.Time
}
type issue struct {
	Number   int    `json:"number"`
	Title    string `json:"title"`
	Body     string `json:"body"`
	State    string `json:"state"`
	Comments int    `json:"comments"`
}
type comment struct {
	ID   int    `json:"id"`
	Body string `json:"body"`
}
type repository struct {
	Issue    issue     `json:"issue"`
	Comments []comment `json:"comments"`
}
type fixture struct {
	mu              sync.Mutex
	browser, github map[string]string
	codes           map[string]loginCode
	public          jose.JSONWebKeySet
	signer          jose.Signer
	repos           map[string]repository
}

func random() string {
	var bytes [32]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(bytes[:])
}
func reply(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}
func viewer(r *http.Request, tokens map[string]string) string {
	value, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok {
		return ""
	}
	for user, want := range tokens {
		if subtle.ConstantTimeCompare([]byte(value), []byte(want)) == 1 {
			return user
		}
	}
	return ""
}
func (s *fixture) authorize(w http.ResponseWriter, r *http.Request) {
	user := viewer(r, s.browser)
	if user == "" {
		http.Error(w, "fixture browser login required", 401)
		return
	}
	q := r.URL.Query()
	u, err := url.Parse(q.Get("redirect_uri"))
	if err != nil || u.Scheme != "http" || u.User != nil || u.Hostname() != "127.0.0.1" || u.Port() == "" || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" ||
		q.Get("client_id") != clientID || q.Get("response_type") != "code" || q.Get("code_challenge_method") != "S256" || len(q.Get("code_challenge")) != 43 ||
		q.Get("state") == "" || q.Get("nonce") == "" {
		http.Error(w, "invalid native authorization", 400)
		return
	}
	code := random()
	s.mu.Lock()
	for id, entry := range s.codes {
		if !entry.Expiry.After(time.Now()) {
			delete(s.codes, id)
		}
	}
	s.codes[code] = loginCode{user, q.Get("nonce"), u.String(), q.Get("code_challenge"), time.Now().Add(time.Minute)}
	s.mu.Unlock()
	u.RawQuery = url.Values{"code": {code}, "state": {q.Get("state")}, "iss": {issuer}}.Encode()
	http.Redirect(w, r, u.String(), http.StatusFound)
}
func (s *fixture) token(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 16384)
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid token exchange", 400)
		return
	}
	f := r.PostForm
	s.mu.Lock()
	c, ok := s.codes[f.Get("code")]
	delete(s.codes, f.Get("code"))
	s.mu.Unlock()
	digest := sha256.Sum256([]byte(f.Get("code_verifier")))
	if !ok || !c.Expiry.After(time.Now()) || f.Get("client_id") != clientID || f.Get("grant_type") != "authorization_code" || f.Get("redirect_uri") != c.Redirect || c.Challenge != base64.RawURLEncoding.EncodeToString(digest[:]) {
		http.Error(w, "invalid code or verifier", 400)
		return
	}
	now := time.Now()
	token, err := jwt.Signed(s.signer).Claims(map[string]any{"iss": issuer, "aud": clientID, "sub": c.Handle, "email": c.Handle + "@rehearsal.test", "email_verified": true, "nonce": c.Nonce, "iat": now.Unix(), "exp": now.Add(5 * time.Minute).Unix()}).Serialize()
	if err != nil {
		http.Error(w, "issuance failed", 500)
		return
	}
	reply(w, 200, map[string]any{"token_type": "Bearer", "access_token": random(), "id_token": token, "expires_in": 300})
}
func (s *fixture) issues(w http.ResponseWriter, r *http.Request) {
	handle := viewer(r, s.github)
	if handle == "" {
		http.Error(w, "fixture GitHub credential required", 401)
		return
	}
	if handle != r.PathValue("owner") {
		http.NotFound(w, r)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	repo := s.repos[handle]
	id := r.PathValue("id")
	if id != "" && id != "1" {
		http.NotFound(w, r)
		return
	}
	if r.Method == "GET" {
		if id == "" {
			issues := []issue{}
			if r.URL.Query().Get("state") != "open" || repo.Issue.State == "open" {
				issues = append(issues, repo.Issue)
			}
			reply(w, 200, issues)
		} else {
			reply(w, 200, repo.Issue)
		}
		return
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32768))
	dec.DisallowUnknownFields()
	var answer any
	status := 200
	switch r.Method {
	case "POST":
		var in struct {
			Body string `json:"body"`
		}
		if dec.Decode(&in) != nil || dec.Decode(new(any)) != io.EOF || strings.TrimSpace(in.Body) == "" || len(in.Body) > 16384 {
			http.Error(w, "invalid comment", 422)
			return
		}
		v := comment{len(repo.Comments) + 1, in.Body}
		repo.Comments = append(repo.Comments, v)
		repo.Issue.Comments = len(repo.Comments)
		answer = v
		status = 201
		if in.Body == "Saved before the fixture returned an error." {
			// Exercise a write that succeeded before the provider lost its reply.
			answer = map[string]string{"error": "fixture-only private provider error"}
			status = http.StatusBadGateway
		}
	case "PATCH":
		var in struct {
			State string `json:"state"`
		}
		if dec.Decode(&in) != nil || dec.Decode(new(any)) != io.EOF || in.State != "closed" {
			http.Error(w, "invalid state", 422)
			return
		}
		repo.Issue.State = in.State
		answer = repo.Issue
	}
	previous := s.repos[handle]
	s.repos[handle] = repo
	if err := s.save(); err != nil {
		s.repos[handle] = previous
		http.Error(w, "fixture storage failed", 503)
		return
	}
	reply(w, status, answer)
}
func (s *fixture) save() error {
	data, err := json.Marshal(s.repos)
	if err != nil {
		return err
	}
	if err = os.WriteFile(statePath+".tmp", data, 0600); err != nil {
		return err
	}
	return os.Rename(statePath+".tmp", statePath)
}
func configured() (*fixture, error) {
	raw, err := os.ReadFile("/fixture/signing.key")
	if err != nil {
		return nil, err
	}
	var key *ecdsa.PrivateKey
	for block, rest := pem.Decode(raw); block != nil; block, rest = pem.Decode(rest) {
		if block.Type == "EC PRIVATE KEY" {
			key, err = x509.ParseECPrivateKey(block.Bytes)
			break
		}
	}
	if err != nil || key == nil {
		return nil, errors.New("invalid fixture signing key")
	}
	signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.ES256, Key: key}, (&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", "rehearsal"))
	if err != nil {
		return nil, err
	}
	s := &fixture{browser: map[string]string{}, github: map[string]string{}, codes: map[string]loginCode{}, signer: signer, public: jose.JSONWebKeySet{Keys: []jose.JSONWebKey{{Key: &key.PublicKey, KeyID: "rehearsal", Algorithm: "ES256", Use: "sig"}}}, repos: map[string]repository{}}
	for _, h := range []string{"alice", "bob", "carol"} {
		for label, dest := range map[string]map[string]string{"browser": s.browser, "github": s.github} {
			token, err := os.ReadFile("/fixture/" + h + "-" + label)
			if err != nil {
				return nil, err
			}
			dest[h] = strings.TrimSpace(string(token))
			if len(dest[h]) < 32 {
				return nil, errors.New("invalid fixture token")
			}
		}
		s.repos[h] = repository{Issue: issue{Number: 1, Title: "Review pilot change", Body: "Exercise the local relay rehearsal.", State: "open"}, Comments: []comment{}}
	}
	raw, err = os.ReadFile(statePath)
	if os.IsNotExist(err) {
		return s, s.save()
	}
	if err != nil {
		return nil, err
	}
	return s, json.Unmarshal(raw, &s.repos)
}

var resourceID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$`)

func gitDir(owner string) string { return filepath.Join("/state/repos", owner, "pilot.git") }
func (s *fixture) seedGit() error {
	for owner := range s.github {
		path := gitDir(owner)
		if err := os.MkdirAll(path, 0700); err != nil {
			return err
		}
		for _, args := range [][]string{{"init", "--bare", "--quiet", path}, {"--git-dir", path, "config", "http.receivepack", "true"}} {
			if err := exec.Command("/usr/bin/git", args...).Run(); err != nil {
				return err
			}
		}
	}
	return nil
}
func (s *fixture) ref(w http.ResponseWriter, r *http.Request) {
	owner := viewer(r, s.github)
	id := r.PathValue("resource")
	if owner == "" || owner != r.PathValue("owner") || !resourceID.MatchString(id) {
		http.NotFound(w, r)
		return
	}
	data, err := exec.CommandContext(r.Context(), "/usr/bin/git", "--git-dir", gitDir(owner), "rev-parse", "--verify", "refs/heads/commander-share/"+id).Output()
	if err != nil {
		http.NotFound(w, r)
		return
	}
	reply(w, 200, map[string]any{"object": map[string]string{"sha": strings.TrimSpace(string(data))}})
}
func (s *fixture) git(w http.ResponseWriter, r *http.Request) {
	name, token, ok := r.BasicAuth()
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/"), "/")
	if !ok || name != "x-access-token" || len(parts) < 3 || parts[1] != "pilot.git" {
		w.Header().Set("WWW-Authenticate", `Basic realm="rehearsal"`)
		http.Error(w, "Git credentials required", 401)
		return
	}
	expected, found := s.github[parts[0]]
	if !found || subtle.ConstantTimeCompare([]byte(expected), []byte(token)) != 1 {
		http.NotFound(w, r)
		return
	}
	suffix := strings.Join(parts[2:], "/")
	if !(r.Method == "GET" && suffix == "info/refs" || r.Method == "POST" && (suffix == "git-receive-pack" || suffix == "git-upload-pack")) {
		http.NotFound(w, r)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 16<<20)
	// The server authorizes each transport operation before opening the shared
	// remote repository. Other clients never mount the checkout or its refs.
	(&cgi.Handler{Path: "/usr/lib/git-core/git-http-backend", Dir: "/state", Env: []string{"GIT_PROJECT_ROOT=/state/repos", "GIT_HTTP_EXPORT_ALL=1", "REMOTE_USER=" + parts[0]}}).ServeHTTP(w, r)
}
func main() {
	if len(os.Args) == 2 && os.Args[1] == "stream" {
		if err := streamProbe(); err != nil {
			log.Fatal(err)
		}
		return
	}
	if len(os.Args) == 2 && os.Args[1] == "state" {
		data, err := os.ReadFile(statePath)
		if err != nil {
			log.Fatal(err)
		}
		_, _ = os.Stdout.Write(append(data, '\n'))
		return
	}
	s, err := configured()
	if err != nil {
		log.Fatal(err)
	}
	if err := s.seedGit(); err != nil {
		log.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /repos/{owner}/pilot/git/ref/heads/commander-share/{resource}", s.ref)
	for _, p := range []string{"GET /repos/{owner}/pilot/issues", "GET /repos/{owner}/pilot/issues/{id}", "PATCH /repos/{owner}/pilot/issues/{id}", "POST /repos/{owner}/pilot/issues/{id}/comments"} {
		mux.HandleFunc(p, s.issues)
	}
	mux.HandleFunc("GET /.well-known/openid-configuration", func(w http.ResponseWriter, _ *http.Request) {
		reply(w, 200, map[string]any{"issuer": issuer, "authorization_endpoint": issuer + "/authorize", "token_endpoint": issuer + "/token", "jwks_uri": issuer + "/keys", "id_token_signing_alg_values_supported": []string{"ES256"}})
	})
	mux.HandleFunc("GET /keys", func(w http.ResponseWriter, _ *http.Request) { reply(w, 200, s.public) })
	mux.HandleFunc("GET /authorize", s.authorize)
	mux.HandleFunc("POST /token", s.token)
	// Distinct hostnames keep the provider's authorization and the GitHub
	// emulator separate even though the test fixture shares one TLS listener.
	checkHost := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host := r.Host
		if h, _, err := net.SplitHostPort(r.Host); err == nil {
			host = h
		}
		switch host {
		case "github.com":
			s.git(w, r)
			return
		case "github.rehearsal.test", "api.github.com":
			if strings.HasPrefix(r.URL.Path, "/repos/") {
				mux.ServeHTTP(w, r)
				return
			}
		case "issuer.rehearsal.test":
			if !strings.HasPrefix(r.URL.Path, "/repos/") {
				mux.ServeHTTP(w, r)
				return
			}
		}
		http.NotFound(w, r)
	})
	serve := func(address string) error {
		httpd := http.Server{Addr: address, Handler: checkHost, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 20 * time.Second, WriteTimeout: 30 * time.Second, TLSConfig: &tls.Config{MinVersion: tls.VersionTLS13}}
		return httpd.ListenAndServeTLS("/fixture/server.pem", "/fixture/server.key")
	}
	go func() { log.Fatal(serve(":443")) }()
	log.Fatal(serve(":8443"))
}

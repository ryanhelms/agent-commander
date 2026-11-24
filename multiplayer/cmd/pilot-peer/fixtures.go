//go:build pilotfixture

package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

func privateIPs(ctx context.Context, host string) ([]netip.Addr, error) {
	ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil || len(ips) == 0 {
		return nil, errors.New("fixture DNS unavailable")
	}
	for _, ip := range ips {
		if !ip.Unmap().IsPrivate() {
			return nil, errors.New("fixture DNS must resolve exclusively to private addresses")
		}
	}
	return ips, nil
}
func checkPrivateOrigins(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	for _, host := range []string{"srv01.agentmux.bytedesk.ai", "issuer.rehearsal.test", "github.rehearsal.test", "github.com", "api.github.com"} {
		if _, err := privateIPs(ctx, host); err != nil {
			return fmt.Errorf("%s: %w", host, err)
		}
	}
	return nil
}
func fixtureRoots() (*x509.CertPool, error) {
	ca, err := os.ReadFile(trustFile)
	if err != nil {
		return nil, err
	}
	system, e := os.ReadFile("/etc/ssl/certs/ca-certificates.crt")
	if e != nil || !bytes.Equal(ca, system) {
		return nil, errors.New("expected isolated rehearsal trust roots for Git and HTTPS")
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(ca) {
		return nil, errors.New("invalid rehearsal roots")
	}
	return roots, nil
}
func fixtureHTTP(roots *x509.CertPool) *http.Client {
	dial := func(ctx context.Context, network, addr string) (net.Conn, error) {
		host, port, e := net.SplitHostPort(addr)
		if e != nil || port != "8443" || (host != "issuer.rehearsal.test" && host != "github.rehearsal.test") {
			return nil, errors.New("unexpected rehearsal host")
		}
		ips, e := privateIPs(ctx, host)
		if e != nil {
			return nil, e
		}
		var conn net.Conn
		for _, ip := range ips {
			conn, e = (&net.Dialer{Timeout: 4 * time.Second}).DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
			if e == nil {
				return conn, nil
			}
		}
		return nil, e
	}
	return &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS13, RootCAs: roots}, DialContext: dial}, Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}
func rehearsalBrowser(ctx context.Context, client *http.Client) func(string) error {
	return func(authURL string) error {
		u, err := url.Parse(authURL)
		if err != nil || u.Scheme+"://"+u.Host != issuerOrigin || u.Path != "/authorize" || u.User != nil || u.Fragment != "" {
			return errors.New("unexpected authorization page")
		}
		q := u.Query()
		callback, err := url.Parse(q.Get("redirect_uri"))
		if err != nil || callback.Scheme != "http" || callback.Hostname() != "127.0.0.1" || callback.Path != "" || callback.RawQuery != "" || callback.User != nil || callback.Fragment != "" {
			return errors.New("unexpected callback origin")
		}
		port, err := strconv.Atoi(callback.Port())
		if err != nil || port < 1024 || port > 65535 {
			return errors.New("invalid callback port")
		}
		if q.Get("client_id") != "commander-rehearsal" || q.Get("code_challenge_method") != "S256" || q.Get("code_challenge") == "" || q.Get("state") == "" || q.Get("nonce") == "" || q.Get("response_type") != "code" {
			return errors.New("missing native authorization binding")
		}
		t, err := readSecret(browserToken)
		if err != nil {
			return err
		}
		req, err := http.NewRequestWithContext(ctx, "GET", u.String(), nil)
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "Bearer "+t)
		res, err := client.Do(req)
		if err != nil {
			return errors.New("fixture browser unavailable")
		}
		res.Body.Close()
		dest, err := res.Location()
		if res.StatusCode != http.StatusFound || err != nil || dest.Scheme != "http" || dest.Host != callback.Host || dest.User != nil || dest.Fragment != "" || (dest.Path != "" && dest.Path != "/") || dest.Query().Get("state") != q.Get("state") || dest.Query().Get("code") == "" {
			return errors.New("fixture issuer did not return a bound callback")
		}
		plain := &http.Client{Transport: &http.Transport{DisableKeepAlives: true}, Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
		r, err := http.NewRequestWithContext(ctx, "GET", dest.String(), nil)
		if err != nil {
			return errors.New("invalid callback")
		}
		res, err = plain.Do(r)
		if err != nil {
			return errors.New("device callback unavailable")
		}
		res.Body.Close()
		if res.StatusCode != 200 {
			return errors.New("device rejected sign-in callback")
		}
		return nil
	}
}
func equal(a, b string) bool { return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1 }

type agentTurn struct{ RunID, Text string }

func commanderFixture(handle string, ids actors) http.Handler {
	worker := handle + "-worker"
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/network/coordinator", func(w http.ResponseWriter, r *http.Request) {
		for _, a := range []actor{ids.Main, ids.Other} {
			if equal(r.Header.Get("Authorization"), "Bearer "+a.Token) && r.Header.Get("X-Commander-Worker") == a.Worker && r.Header.Get("X-Commander-Run") == a.Run {
				_ = json.NewEncoder(w).Encode(map[string]string{"run": a.Run, "worker": a.Worker})
				return
			}
		}
		http.Error(w, "denied", 403)
	})
	mux.HandleFunc("GET /v1/ag-ui/workers/{id}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		for _, a := range []actor{ids.Main, ids.Other} {
			if id == a.Worker {
				_ = json.NewEncoder(w).Encode(map[string]any{"workerId": id, "role": "coordinator", "runId": a.Run, "runStatus": "running", "generation": 1})
				return
			}
		}
		if id != worker {
			http.NotFound(w, r)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"workerId": id, "role": "worker", "runId": ids.Main.Run, "runStatus": "running", "generation": 1})
	})
	base := "/v1/ag-ui/workers/" + worker
	dir := stateDir + "/turns"
	var mu sync.Mutex
	stream := func(w http.ResponseWriter, turn agentTurn) {
		w.Header().Set("Content-Type", "text/event-stream")
		event := func(v any) { b, _ := json.Marshal(v); fmt.Fprintf(w, "data: %s\n\n", b) }
		event(map[string]any{"type": "STATE_SNAPSHOT", "snapshot": map[string]any{"workerId": worker, "operationId": "turn-" + turn.RunID, "operationStatus": "completed"}})
		event(map[string]any{"type": "MESSAGES_SNAPSHOT", "messages": []map[string]string{{"role": "user", "content": turn.Text}, {"role": "assistant", "content": "answer from " + handle}}})
		event(map[string]any{"type": "RUN_FINISHED", "runId": turn.RunID})
	}
	mux.HandleFunc("POST "+base+"/run", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			ThreadID, RunID string
			ForwardedProps  struct{ Generation int }
			Messages        []struct{ Role, Content string }
		}
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 40<<10)).Decode(&in) != nil || !resourceID.MatchString(in.RunID) || in.ThreadID != worker || in.ForwardedProps.Generation != 1 || len(in.Messages) != 1 || in.Messages[0].Role != "user" || !strings.HasPrefix(in.Messages[0].Content, "[Shared operation "+in.RunID+"]\n") {
			http.Error(w, "invalid local worker turn", 400)
			return
		}
		turn := agentTurn{in.RunID, in.Messages[0].Content}
		mu.Lock()
		defer mu.Unlock()
		if os.MkdirAll(dir, 0700) != nil {
			http.Error(w, "unavailable", 503)
			return
		}
		path := filepath.Join(dir, turn.RunID+".json")
		b, _ := json.Marshal(turn)
		if old, e := os.ReadFile(path); e == nil && !bytes.Equal(old, b) {
			http.Error(w, "turn already bound", 409)
			return
		} else if e != nil && !errors.Is(e, os.ErrNotExist) {
			http.Error(w, "unavailable", 503)
			return
		}
		if os.WriteFile(path, b, 0600) != nil {
			http.Error(w, "unavailable", 503)
			return
		}
		stream(w, turn)
	})
	lookup := func(w http.ResponseWriter, r *http.Request) (agentTurn, bool) {
		var t agentTurn
		id := r.URL.Query().Get("runId")
		if !resourceID.MatchString(id) {
			http.Error(w, "invalid turn", 400)
			return t, false
		}
		mu.Lock()
		defer mu.Unlock()
		b, e := os.ReadFile(filepath.Join(dir, id+".json"))
		if e != nil || json.Unmarshal(b, &t) != nil || t.RunID != id {
			http.NotFound(w, r)
			return t, false
		}
		return t, true
	}
	mux.HandleFunc("GET "+base+"/operations", func(w http.ResponseWriter, r *http.Request) {
		if t, ok := lookup(w, r); ok {
			_ = json.NewEncoder(w).Encode(map[string]string{"runId": t.RunID, "operationId": "turn-" + t.RunID})
		}
	})
	mux.HandleFunc("GET "+base+"/operations/{id}", func(w http.ResponseWriter, r *http.Request) {
		if t, ok := lookup(w, r); ok {
			if r.PathValue("id") != "turn-"+t.RunID {
				http.NotFound(w, r)
				return
			}
			stream(w, t)
		}
	})
	return mux
}

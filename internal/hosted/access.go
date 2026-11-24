// Package hosted authenticates independently hosted clients for the HTTPS API.
package hosted

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"slices"
	"strings"
	"time"
)

type Config struct {
	Listen          string `json:"listen"`
	Certificate     string `json:"certificate"`
	PrivateKey      string `json:"private_key"`
	Introspection   string `json:"introspection_url"`
	IntrospectionCA string `json:"introspection_ca,omitempty"`
	ClientID        string `json:"introspection_client_id"`
	Issuer          string `json:"issuer"`
	Audience        string `json:"audience"`
}

type Grant struct {
	Subject  string              `json:"subject"`
	ClientID string              `json:"client_id"`
	Workers  map[string][]string `json:"workers"`
}

type Gateway struct {
	config Config
	secret string
	grants string
	client *http.Client
}

func New(config Config, secret, grants string) (*Gateway, error) {
	endpoint, err := url.Parse(config.Introspection)
	if err != nil || endpoint.Scheme != "https" || endpoint.Hostname() == "" || endpoint.User != nil || endpoint.Fragment != "" ||
		config.ClientID == "" || secret == "" || config.Issuer == "" || config.Audience == "" {
		return nil, errors.New("configure HTTPS OAuth introspection, issuer, audience and client credentials")
	}
	client := &http.Client{
		Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	if config.IntrospectionCA != "" {
		pem, err := os.ReadFile(config.IntrospectionCA)
		if err != nil {
			return nil, fmt.Errorf("read OAuth introspection CA: %w", err)
		}
		roots, err := x509.SystemCertPool()
		if err != nil {
			return nil, fmt.Errorf("load system root certificates: %w", err)
		}
		if !roots.AppendCertsFromPEM(pem) {
			return nil, errors.New("OAuth introspection CA contains no PEM certificates")
		}
		transport := http.DefaultTransport.(*http.Transport).Clone()
		transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: roots}
		client.Transport = transport
	}
	return &Gateway{config: config, secret: secret, grants: grants, client: client}, nil
}

type claims struct {
	Active   bool            `json:"active"`
	Subject  string          `json:"sub"`
	ClientID string          `json:"client_id"`
	Issuer   string          `json:"iss"`
	Audience json.RawMessage `json:"aud"`
	Expires  int64           `json:"exp"`
	Scope    string          `json:"scope"`
}

func (g *Gateway) introspect(ctx context.Context, token string) (claims, error) {
	form := url.Values{"token": {token}, "token_type_hint": {"access_token"}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.config.Introspection, strings.NewReader(form.Encode()))
	if err != nil {
		return claims{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	// OAuth client_secret_basic uses form-encoded credentials (RFC 6749 §2.3.1).
	req.SetBasicAuth(url.QueryEscape(g.config.ClientID), url.QueryEscape(g.secret))
	response, err := g.client.Do(req)
	if err != nil {
		return claims{}, err
	}
	defer response.Body.Close()
	var claim claims
	if response.StatusCode != http.StatusOK || json.NewDecoder(io.LimitReader(response.Body, 64<<10)).Decode(&claim) != nil ||
		!claim.Active || claim.Subject == "" || claim.ClientID == "" || claim.Issuer != g.config.Issuer ||
		claim.Expires <= time.Now().Unix() || !hasAudience(claim.Audience, g.config.Audience) {
		return claims{}, errors.New("inactive or mismatched access token")
	}
	return claim, nil
}

func hasAudience(raw json.RawMessage, expected string) bool {
	var one string
	if json.Unmarshal(raw, &one) == nil && one == expected {
		return true
	}
	var many []string
	return json.Unmarshal(raw, &many) == nil && slices.Contains(many, expected)
}

type accessKey struct{}

type Access struct {
	gateway *Gateway
	claim   claims
	worker  string
	scopes  []string
}

func From(ctx context.Context) *Access {
	access, _ := ctx.Value(accessKey{}).(*Access)
	return access
}

func (a *Access) ReceiptActor() string {
	identity, _ := json.Marshal([3]string{a.claim.Issuer, a.claim.Subject, a.claim.ClientID})
	return fmt.Sprintf("hosted:%x", sha256.Sum256(identity))
}

func (a *Access) WithScope(scope string) *Access {
	scoped := *a
	scoped.scopes = append(slices.Clone(a.scopes), scope)
	return &scoped
}

func (a *Access) Allowed() bool {
	return time.Now().Unix() < a.claim.Expires && a.GrantAllowed()
}

// Renew returns authorization for the original scopes using a fresh credential
// for the identical principal and worker.
func (a *Access) Renew(fresh *Access) *Access {
	if fresh == nil || fresh.gateway != a.gateway || fresh.worker != a.worker ||
		fresh.claim.Issuer != a.claim.Issuer || fresh.claim.Subject != a.claim.Subject ||
		fresh.claim.ClientID != a.claim.ClientID || fresh.claim.Expires < a.claim.Expires {
		return nil
	}
	renewed := *a
	renewed.claim = fresh.claim
	if !renewed.Allowed() {
		return nil
	}
	return &renewed
}

// GrantAllowed checks the saved scopes and current developer grant independent
// of token expiry. It can keep an already-issued operation waiting for renewal.
func (a *Access) GrantAllowed() bool {
	info, err := os.Lstat(a.gateway.grants)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 256<<10 {
		return false
	}
	raw, err := os.ReadFile(a.gateway.grants)
	var grants []Grant
	if err != nil || json.Unmarshal(raw, &grants) != nil {
		return false
	}
	tokenScopes := strings.Fields(a.claim.Scope)
	for _, grant := range grants {
		if grant.Subject != a.claim.Subject || grant.ClientID != a.claim.ClientID {
			continue
		}
		workerScopes := grant.Workers[a.worker]
		if len(workerScopes) == 0 {
			continue
		}
		if !slices.ContainsFunc(a.scopes, func(scope string) bool {
			return !slices.Contains(tokenScopes, scope) || !slices.Contains(workerScopes, scope)
		}) {
			return true
		}
	}
	return false
}

// Handler exposes only hosted worker endpoints. The bearer never reaches
// Commander worker-token parsing or the local owner socket.
func (g *Gateway) Handler(next http.Handler) http.Handler {
	mux := http.NewServeMux()
	bind := func(pattern string, scopes ...string) {
		mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Cache-Control", "no-store")
			headers := r.Header.Values("Authorization")
			if r.TLS == nil || len(headers) != 1 {
				w.Header().Set("WWW-Authenticate", `Bearer realm="commander"`)
				http.Error(w, "OAuth access token required", http.StatusUnauthorized)
				return
			}
			parts := strings.Fields(headers[0])
			if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") || len(parts[1]) > 8192 {
				http.Error(w, "Invalid bearer credential", http.StatusUnauthorized)
				return
			}
			claim, err := g.introspect(r.Context(), parts[1])
			if err != nil {
				w.Header().Set("WWW-Authenticate", `Bearer error="invalid_token"`)
				http.Error(w, "OAuth access token unavailable", http.StatusUnauthorized)
				return
			}
			access := &Access{gateway: g, claim: claim, worker: r.PathValue("worker"), scopes: scopes}
			if !access.Allowed() {
				http.Error(w, "Worker access is outside the application grant", http.StatusForbidden)
				return
			}
			request := r.Clone(context.WithValue(r.Context(), accessKey{}, access))
			request.Header.Del("Authorization")
			next.ServeHTTP(w, request)
		})
	}
	bind("POST /v1/ag-ui/workers/{worker}/run", "commander:observe", "commander:prompt")
	bind("GET /v1/ag-ui/workers/{worker}", "commander:observe")
	bind("GET /v1/ag-ui/workers/{worker}/operations/{operation}", "commander:observe")
	bind("GET /v1/ag-ui/workers/{worker}/operations", "commander:observe")
	bind("POST /v1/ag-ui/workers/{worker}/requests/{qid}/reply", "commander:reply")
	bind("POST /v1/ag-ui/workers/{worker}/operations/{operation}/tools/{call}/result", "commander:frontend-tools")
	bind("GET /v1/workers/{worker}/history", "commander:history")
	return mux
}

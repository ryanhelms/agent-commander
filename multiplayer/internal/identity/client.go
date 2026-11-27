package identity

import (
	"agentcommander.network/pilot/internal/devicekeys"
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/coreos/go-oidc/v3/oidc"
	"golang.org/x/oauth2"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// HTTP presents the device certificate only to the configured edge. OIDCHTTP
// is a separate trust context for the provider and never inherits device keys.
type Client struct {
	BaseURL             string
	HTTP                *http.Client
	OIDCHTTP            *http.Client
	GoogleDesktopConfig string
	AllowLoopbackHTTP   bool
	// Invite is an optional relay invite code sent with the enrollment challenge.
	Invite string
}
type HTTPError struct {
	Status int
	// Requestable is set on a sign-in refusal the person may turn into a
	// membership request from this device.
	Requestable bool
}

// NotAdmittedError is a sign-in the relay refused. Requestable means the
// device can ask to join with RequestMembership.
type NotAdmittedError struct {
	Message     string
	Requestable bool
}

func (e NotAdmittedError) Error() string { return e.Message }

func (e HTTPError) Error() string { return fmt.Sprintf("device authorization HTTP %d", e.Status) }
func (c Client) request(ctx context.Context, method, path, access string, in, out any) error {
	base, err := url.Parse(c.BaseURL)
	if err != nil || !safeURL(c.BaseURL, false) || base.RawQuery != "" || base.Fragment != "" {
		return errors.New("relay requires a trusted HTTPS origin")
	}
	if c.HTTP == nil {
		return errors.New("device TLS transport is required")
	}
	var payload []byte
	if in != nil {
		payload, err = json.Marshal(in)
		if err != nil {
			return err
		}
	}
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(c.BaseURL, "/")+path, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if access != "" {
		req.Header.Set("Authorization", "Bearer "+access)
	}
	h := *c.HTTP
	h.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	res, err := h.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode/100 != 2 {
		herr := HTTPError{Status: res.StatusCode}
		if res.StatusCode == http.StatusForbidden {
			var refusal struct {
				Requestable bool `json:"requestable"`
			}
			if json.NewDecoder(io.LimitReader(res.Body, 4096)).Decode(&refusal) == nil {
				herr.Requestable = refusal.Requestable
			}
		}
		return herr
	}
	if out == nil {
		return nil
	}
	data, err := io.ReadAll(io.LimitReader(res.Body, 32769))
	if err != nil {
		return err
	}
	if len(data) > 32768 {
		return errors.New("oversized identity response")
	}
	return json.Unmarshal(data, out)
}
func (c Client) Login(ctx context.Context, keys *devicekeys.Keys, openBrowser func(string) error) (Session, error) {
	if openBrowser == nil {
		return Session{}, errors.New("system browser opener is required")
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	pub, err := keys.Public()
	if err != nil {
		return Session{}, err
	}
	var ch challenge
	chReq := map[string]any{"public": pub}
	if c.Invite != "" {
		chReq["invite"] = c.Invite
	}
	if err = c.request(ctx, "POST", "/v1/auth/challenge", "", chReq, &ch); err != nil {
		return Session{}, err
	}
	if len(ch.Nonce) != 43 {
		return Session{}, errors.New("invalid enrollment challenge")
	}
	cfg := Config{Issuer: ch.Issuer, ClientID: ch.ClientID, HTTPClient: c.OIDCHTTP, AllowLoopbackHTTP: c.AllowLoopbackHTTP}
	provider, err := discover(ctx, cfg)
	if err != nil {
		return Session{}, err
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return Session{}, err
	}
	defer listener.Close()
	addr := listener.Addr().String()
	redirect := "http://" + addr
	endpoint := provider.Endpoint()
	endpoint.AuthStyle = oauth2.AuthStyleInParams
	oauth := oauth2.Config{ClientID: ch.ClientID, Endpoint: endpoint, RedirectURL: redirect, Scopes: []string{oidc.ScopeOpenID}}
	issuerHTTP := c.OIDCHTTP
	if ch.Issuer == googleIssuer {
		oauth.ClientSecret, err = c.googleDesktopSecret(ch.ClientID, endpoint.TokenURL)
		if err != nil {
			return Session{}, err
		}
		if issuerHTTP == nil {
			issuerHTTP = http.DefaultClient
		}
		direct := *issuerHTTP
		direct.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
		issuerHTTP = &direct
	}
	if ch.Email {
		oauth.Scopes = append(oauth.Scopes, "email")
	}
	state, err := token()
	if err != nil {
		return Session{}, err
	}
	verifier := oauth2.GenerateVerifier()
	type callback struct {
		code string
		err  error
	}
	done := make(chan callback, 1)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		q := r.URL.Query()
		if r.Host != addr || len(q["state"]) != 1 || subtle.ConstantTimeCompare([]byte(q.Get("state")), []byte(state)) != 1 || (q.Has("iss") && (len(q["iss"]) != 1 || q.Get("iss") != ch.Issuer)) {
			http.Error(w, "Unexpected sign-in callback", 400)
			return
		}
		result := callback{code: q.Get("code")}
		if q.Has("error") || len(q["code"]) != 1 || result.code == "" || len(result.code) > 8192 {
			result.err = errors.New("browser sign-in declined or incomplete")
		}
		select {
		case done <- result:
		default:
			http.Error(w, "Callback already received", 409)
			return
		}
		_, _ = io.WriteString(w, "Return to Agent Commander to complete sign-in.")
	})
	srv := http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second, MaxHeaderBytes: 16384}
	stop := make(chan error, 1)
	go func() { stop <- srv.Serve(listener) }()
	defer srv.Close()
	options := []oauth2.AuthCodeOption{oidc.Nonce(ch.Nonce), oauth2.S256ChallengeOption(verifier)}
	if ch.Issuer == googleIssuer {
		options = append(options, oauth2.SetAuthURLParam("prompt", "select_account"))
	}
	authURL := oauth.AuthCodeURL(state, options...)
	if err = openBrowser(authURL); err != nil {
		return Session{}, err
	}
	var received callback
	select {
	case <-ctx.Done():
		return Session{}, ctx.Err()
	case err = <-stop:
		return Session{}, err
	case received = <-done:
	}
	if received.err != nil {
		return Session{}, received.err
	}
	if issuerHTTP != nil {
		ctx = oidc.ClientContext(ctx, issuerHTTP)
	}
	tok, err := oauth.Exchange(ctx, received.code, oauth2.VerifierOption(verifier))
	if err != nil {
		return Session{}, errors.New("OIDC authorization-code exchange failed")
	}
	idToken, ok := tok.Extra("id_token").(string)
	if !ok || idToken == "" {
		return Session{}, errors.New("identity provider did not issue an ID token")
	}
	var sess Session
	err = c.request(ctx, "POST", "/v1/auth/finish", "", map[string]string{"id_token": idToken}, &sess)
	var refusal HTTPError
	if errors.As(err, &refusal) && refusal.Status == http.StatusForbidden {
		msg := "This account or device needs access to the relay."
		if ch.Issuer == googleIssuer {
			msg = "This Google account or device needs access to the relay. To switch accounts, sign in again and choose the invited account."
		}
		if refusal.Requestable {
			msg += " You can ask the relay's admins to let you in."
		}
		return Session{}, NotAdmittedError{Message: msg, Requestable: refusal.Requestable}
	}
	if err == nil && (sess.Device != pub.Device || sess.User == "" || len(sess.AccessToken) != 43 || len(sess.RefreshToken) != 43) {
		return Session{}, errors.New("invalid device session returned by relay")
	}
	return sess, err
}
func (c Client) Refresh(ctx context.Context, refresh string) (Session, error) {
	var s Session
	err := c.request(ctx, "POST", "/v1/auth/refresh", "", map[string]string{"refresh_token": refresh}, &s)
	return s, err
}
func (c Client) SignOut(ctx context.Context, access string) error {
	return c.request(ctx, "POST", "/v1/auth/signout", access, struct{}{}, nil)
}
func keyPath(device string) (string, error) {
	b, err := hex.DecodeString(device)
	if err != nil || len(b) != 32 || device != strings.ToLower(device) {
		return "", errors.New("invalid device fingerprint")
	}
	return "/v1/identity/devices/" + device, nil
}
func (c Client) Lookup(ctx context.Context, access, device string) (devicekeys.Public, error) {
	path, err := keyPath(device)
	if err != nil {
		return devicekeys.Public{}, err
	}
	var p devicekeys.Public
	if err = c.request(ctx, "GET", path, access, nil, &p); err != nil {
		return p, err
	}
	if p.Device != device || p.User == "" {
		return p, errors.New("returned key identity mismatch")
	}
	return p, p.Validate()
}
func (c Client) Revoke(ctx context.Context, access, device string) error {
	path, err := keyPath(device)
	if err != nil {
		return err
	}
	return c.request(ctx, "DELETE", path, access, nil, nil)
}

// RequestMembership asks the relay's admins to let this device's refused
// account in. It needs a refusal from this device in the last 15 minutes.
func (c Client) RequestMembership(ctx context.Context, note string) (MembershipRequest, error) {
	var out MembershipRequest
	err := c.request(ctx, "POST", "/v1/membership-requests", "", map[string]string{"note": note}, &out)
	return out, err
}

// MyMembershipRequest reports the latest membership request made from this device.
func (c Client) MyMembershipRequest(ctx context.Context) (MembershipRequest, error) {
	var out MembershipRequest
	err := c.request(ctx, "GET", "/v1/membership-requests/mine", "", nil, &out)
	return out, err
}

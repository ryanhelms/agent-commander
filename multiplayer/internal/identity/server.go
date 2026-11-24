// Package identity authenticates a browser sign-in and its independently held device key.
package identity

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/mail"
	"net/url"
	"slices"
	"strings"
	"time"

	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/devicekeys"
	"github.com/coreos/go-oidc/v3/oidc"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Config struct {
	Issuer, ClientID  string
	AllowedEmails     []string
	HTTPClient        *http.Client
	AllowLoopbackHTTP bool
}
type Server struct {
	pool          *pgxpool.Pool
	config        Config
	allowedHashes []string
	verifier      *oidc.IDTokenVerifier
	CanLookup     func(context.Context, string, string) (bool, error)
	revokeWork    func(context.Context, pgx.Tx, string) error
}
type Session struct {
	User         string    `json:"user"`
	Device       string    `json:"device"`
	AccessToken  string    `json:"access_token"`
	RefreshToken string    `json:"refresh_token"`
	ExpiresAt    time.Time `json:"expires_at"`
}
type challenge struct {
	Nonce    string `json:"nonce"`
	Issuer   string `json:"issuer"`
	ClientID string `json:"client_id"`
	Email    bool   `json:"request_verified_email,omitempty"`
}

var denied = errors.New("invalid or expired device authorization")

const googleIssuer = "https://accounts.google.com"

func userID(issuer, subject string) string {
	return hex.EncodeToString(digest(issuer + "\x00" + subject))
}

type enrollmentClaims struct {
	AZP           string          `json:"azp"`
	Email         string          `json:"email"`
	EmailVerified json.RawMessage `json:"email_verified"`
}

func (c enrollmentClaims) emailVerified(issuer string) (bool, error) {
	if len(c.EmailVerified) == 0 {
		return false, nil
	}
	// Google's OIDC documentation includes a quoted value in an ID-token example.
	if issuer == googleIssuer && string(c.EmailVerified) == `"true"` {
		return true, nil
	}
	if issuer == googleIssuer && string(c.EmailVerified) == `"false"` {
		return false, nil
	}
	var verified bool
	err := json.Unmarshal(c.EmailVerified, &verified)
	return verified, err
}

func (s *Server) enrollmentUser(ctx context.Context, tx pgx.Tx, sub, device string) (string, error) {
	current := userID(s.config.Issuer, sub)
	if s.config.Issuer != googleIssuer {
		return current, nil
	}
	legacy := userID("accounts.google.com", sub)
	// The verifier accepts Google's legacy issuer spelling. Serialize enrollment
	// for both forms, and keep earlier device ownership and shares addressable.
	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", current); err != nil {
		return "", err
	}
	var hasCurrent, hasLegacy bool
	var owner string
	err := tx.QueryRow(ctx, `SELECT COALESCE(bool_or(user_id=$1),false), COALESCE(bool_or(user_id=$2),false),
		COALESCE(max(user_id) FILTER (WHERE device=$3),'') FROM mp_auth_devices WHERE user_id IN ($1,$2)`,
		current, legacy, device).Scan(&hasCurrent, &hasLegacy, &owner)
	if err != nil {
		return "", err
	}
	switch {
	case owner != "":
		return owner, nil
	case hasLegacy && hasCurrent:
		// Existing devices retain their accounts. A new device cannot choose
		// between two previously split accounts on the user's behalf.
		return "", denied
	case hasLegacy:
		return legacy, nil
	default:
		return current, nil
	}
}

func safeURL(text string, loopback bool) bool {
	u, err := url.Parse(text)
	if err != nil || u.Host == "" || u.User != nil || u.Fragment != "" {
		return false
	}
	if u.Scheme == "https" {
		return true
	}
	ip := net.ParseIP(u.Hostname())
	return loopback && u.Scheme == "http" && ip != nil && ip.IsLoopback()
}
func discover(ctx context.Context, cfg Config) (*oidc.Provider, error) {
	if cfg.ClientID == "" || !safeURL(cfg.Issuer, cfg.AllowLoopbackHTTP) {
		return nil, errors.New("OIDC requires a client ID and trusted HTTPS issuer")
	}
	if cfg.HTTPClient != nil {
		ctx = oidc.ClientContext(ctx, cfg.HTTPClient)
	}
	p, err := oidc.NewProvider(ctx, cfg.Issuer)
	if err != nil {
		return nil, err
	}
	var meta struct {
		JWKS string `json:"jwks_uri"`
	}
	if err = p.Claims(&meta); err != nil {
		return nil, err
	}
	for _, endpoint := range []string{p.Endpoint().AuthURL, p.Endpoint().TokenURL, meta.JWKS} {
		if !safeURL(endpoint, cfg.AllowLoopbackHTTP) {
			return nil, errors.New("OIDC discovery supplied an insecure endpoint")
		}
	}
	return p, nil
}
func New(ctx context.Context, pool *pgxpool.Pool, cfg Config) (*Server, error) {
	var hashes []string
	for _, email := range cfg.AllowedEmails {
		m, err := mail.ParseAddress(email)
		if err != nil || m.Address != email {
			return nil, errors.New("invalid allowed OIDC email address")
		}
		hashes = append(hashes, emailHash(email))
	}
	p, err := discover(ctx, cfg)
	if err != nil {
		return nil, err
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, "select pg_advisory_xact_lock(5843996107201)"); err != nil {
		return nil, err
	}
	_, err = tx.Exec(ctx, `
 CREATE TABLE IF NOT EXISTS mp_auth_challenges(device text PRIMARY KEY, nonce text NOT NULL, descriptor jsonb NOT NULL, expires_at timestamptz NOT NULL);
 CREATE INDEX IF NOT EXISTS mp_auth_challenges_expiry ON mp_auth_challenges(expires_at);
 CREATE TABLE IF NOT EXISTS mp_auth_devices(device text PRIMARY KEY, user_id text NOT NULL, encryption_key text NOT NULL, descriptor jsonb NOT NULL, access_hash bytea, access_expires timestamptz, refresh_hash bytea, refresh_expires timestamptz, revoked boolean NOT NULL DEFAULT false);
 ALTER TABLE mp_auth_devices ADD COLUMN IF NOT EXISTS email_hash text;
 CREATE INDEX IF NOT EXISTS mp_auth_device_owner ON mp_auth_devices(user_id);
 `)
	if err != nil {
		return nil, err
	}
	if err = tx.Commit(ctx); err != nil {
		return nil, err
	}
	return &Server{pool: pool, config: cfg, allowedHashes: hashes, verifier: p.Verifier(&oidc.Config{ClientID: cfg.ClientID})}, nil
}
func emailHash(email string) string { return hex.EncodeToString(digest(strings.ToLower(email))) }
func (s *Server) permitsEmail(email string, verified bool) bool {
	return len(s.allowedHashes) == 0 || (verified && email != "" && slices.Contains(s.allowedHashes, emailHash(email)))
}
func DeviceID(state *tls.ConnectionState) (string, error) {
	if state == nil || state.Version < tls.VersionTLS13 || len(state.PeerCertificates) != 1 {
		return "", denied
	}
	c := state.PeerCertificates[0]
	k, ok := c.PublicKey.(*ecdsa.PublicKey)
	now := time.Now()
	if !ok || k.Curve != elliptic.P256() || c.IsCA || now.Before(c.NotBefore) || !now.Before(c.NotAfter) || c.KeyUsage&x509.KeyUsageDigitalSignature == 0 || !bytes.Equal(c.RawSubject, c.RawIssuer) {
		return "", denied
	}
	allowed := false
	for _, u := range c.ExtKeyUsage {
		if u == x509.ExtKeyUsageClientAuth {
			allowed = true
		}
	}
	if !allowed || c.CheckSignature(c.SignatureAlgorithm, c.RawTBSCertificate, c.Signature) != nil {
		return "", denied
	}
	return devicekeys.Fingerprint(k)
}
func token() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}
func digest(v string) []byte { h := sha256.Sum256([]byte(v)); return h[:] }
func credentials(user, id string) (Session, error) {
	a, err := token()
	if err != nil {
		return Session{}, err
	}
	r, err := token()
	if err != nil {
		return Session{}, err
	}
	return Session{user, id, a, r, time.Now().UTC().Add(15 * time.Minute).Truncate(time.Microsecond)}, nil
}
func bearer(r *http.Request) string {
	values := r.Header.Values("Authorization")
	if len(values) != 1 {
		return ""
	}
	kind, token, ok := strings.Cut(values[0], " ")
	if !ok || !strings.EqualFold(kind, "Bearer") || len(token) != 43 {
		return ""
	}
	return token
}
func (s *Server) Authenticate(r *http.Request) (control.Principal, error) {
	id, err := DeviceID(r.TLS)
	t := bearer(r)
	if err != nil || t == "" {
		return control.Principal{}, denied
	}
	var user string
	err = s.pool.QueryRow(r.Context(), `SELECT user_id FROM mp_auth_devices WHERE device=$1 AND access_hash=$2 AND access_expires>now() AND NOT revoked AND ($3::text[] IS NULL OR email_hash=ANY($3))`, id, digest(t), s.allowedHashes).Scan(&user)
	if err != nil {
		return control.Principal{}, denied
	}
	return control.Principal{User: user, Device: id}, nil
}
func (s *Server) Register(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/auth/challenge", s.begin)
	mux.HandleFunc("POST /v1/auth/finish", s.finish)
	mux.HandleFunc("POST /v1/auth/refresh", s.refresh)
	mux.HandleFunc("POST /v1/auth/signout", s.signout)
	mux.HandleFunc("GET /v1/identity/devices/{device}", s.lookup)
	mux.HandleFunc("DELETE /v1/identity/devices/{device}", s.revoke)
}
func reply(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
func failure(w http.ResponseWriter, status int) {
	reply(w, status, map[string]string{"error": http.StatusText(status)})
}
func body(w http.ResponseWriter, r *http.Request, out any) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32768))
	dec.DisallowUnknownFields()
	if dec.Decode(out) != nil || dec.Decode(new(any)) != io.EOF {
		failure(w, 400)
		return false
	}
	return true
}
func (s *Server) begin(w http.ResponseWriter, r *http.Request) {
	id, err := DeviceID(r.TLS)
	if err != nil {
		failure(w, 401)
		return
	}
	var in struct {
		Public devicekeys.Public `json:"public"`
	}
	if !body(w, r, &in) {
		return
	}
	if in.Public.Device != id || in.Public.Validate() != nil || in.Public.User != "" {
		failure(w, 400)
		return
	}
	n, err := token()
	if err != nil {
		failure(w, 500)
		return
	}
	descriptor, _ := json.Marshal(in.Public)
	ctx := r.Context()
	if _, err = s.pool.Exec(ctx, "DELETE FROM mp_auth_challenges WHERE expires_at <= now()"); err != nil {
		failure(w, 503)
		return
	}
	_, err = s.pool.Exec(ctx, `INSERT INTO mp_auth_challenges(device,nonce,descriptor,expires_at) VALUES($1,$2,$3,now()+interval '5 minutes')
 ON CONFLICT(device) DO UPDATE SET nonce=excluded.nonce,descriptor=excluded.descriptor,expires_at=excluded.expires_at`, id, n, string(descriptor))
	if err != nil {
		failure(w, 503)
		return
	}
	reply(w, 200, challenge{Nonce: n, Issuer: s.config.Issuer, ClientID: s.config.ClientID, Email: len(s.allowedHashes) > 0})
}
func (s *Server) finish(w http.ResponseWriter, r *http.Request) {
	id, err := DeviceID(r.TLS)
	if err != nil {
		failure(w, 401)
		return
	}
	var in struct {
		IDToken string `json:"id_token"`
	}
	if !body(w, r, &in) {
		return
	}
	if in.IDToken == "" {
		failure(w, 401)
		return
	}
	ctx := r.Context()
	var nonce string
	err = s.pool.QueryRow(ctx, "SELECT nonce FROM mp_auth_challenges WHERE device=$1 AND expires_at>now()", id).Scan(&nonce)
	if err != nil {
		failure(w, 401)
		return
	}
	verified, err := s.verifier.Verify(ctx, in.IDToken)
	if err != nil || verified.Subject == "" || verified.Nonce != nonce {
		failure(w, 401)
		return
	}
	var claims enrollmentClaims
	if verified.Claims(&claims) != nil || (len(verified.Audience) > 1 || claims.AZP != "") && claims.AZP != s.config.ClientID {
		failure(w, 401)
		return
	}
	verifiedEmail, err := claims.emailVerified(s.config.Issuer)
	if err != nil {
		failure(w, 401)
		return
	}
	if !s.permitsEmail(claims.Email, verifiedEmail) {
		failure(w, 403)
		return
	}
	var enrollmentEmail string
	if verifiedEmail && claims.Email != "" {
		enrollmentEmail = emailHash(claims.Email)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		failure(w, 503)
		return
	}
	defer tx.Rollback(ctx)
	var stored []byte
	err = tx.QueryRow(ctx, "DELETE FROM mp_auth_challenges WHERE device=$1 AND nonce=$2 AND expires_at>now() RETURNING descriptor", id, nonce).Scan(&stored)
	if err != nil {
		failure(w, 401)
		return
	}
	var pub devicekeys.Public
	if json.Unmarshal(stored, &pub) != nil {
		failure(w, 500)
		return
	}
	user, err := s.enrollmentUser(ctx, tx, verified.Subject, id)
	if err != nil {
		if errors.Is(err, denied) {
			failure(w, 409)
		} else {
			failure(w, 503)
		}
		return
	}
	sess, err := credentials(user, id)
	if err != nil {
		failure(w, 500)
		return
	}
	pub.User = user
	descriptor, _ := json.Marshal(pub)
	tag, err := tx.Exec(ctx, `INSERT INTO mp_auth_devices(device,user_id,encryption_key,descriptor,access_hash,access_expires,refresh_hash,refresh_expires,email_hash)
 VALUES ($1,$2,$3,$4,$5,$6,$7,now()+interval '30 days',$8) ON CONFLICT(device) DO UPDATE
 SET descriptor=excluded.descriptor,access_hash=excluded.access_hash,access_expires=excluded.access_expires,refresh_hash=excluded.refresh_hash,refresh_expires=excluded.refresh_expires,email_hash=excluded.email_hash
 WHERE mp_auth_devices.user_id=excluded.user_id AND mp_auth_devices.encryption_key=excluded.encryption_key AND NOT mp_auth_devices.revoked`,
		id, user, pub.EncryptionKey, string(descriptor), digest(sess.AccessToken), sess.ExpiresAt, digest(sess.RefreshToken), enrollmentEmail)
	if err != nil {
		failure(w, 503)
		return
	}
	if tag.RowsAffected() != 1 {
		failure(w, 403)
		return
	}
	if tx.Commit(ctx) != nil {
		failure(w, 503)
		return
	}
	reply(w, 200, sess)
}
func (s *Server) refresh(w http.ResponseWriter, r *http.Request) {
	id, err := DeviceID(r.TLS)
	if err != nil {
		failure(w, 401)
		return
	}
	var in struct {
		Refresh string `json:"refresh_token"`
	}
	if !body(w, r, &in) {
		return
	}
	if len(in.Refresh) != 43 {
		failure(w, 401)
		return
	}
	sess, err := credentials("", id)
	if err != nil {
		failure(w, 500)
		return
	}
	err = s.pool.QueryRow(r.Context(), `UPDATE mp_auth_devices SET access_hash=$3,access_expires=$4,refresh_hash=$5 WHERE device=$1 AND refresh_hash=$2 AND refresh_expires>now() AND NOT revoked AND ($6::text[] IS NULL OR email_hash=ANY($6)) RETURNING user_id`, id, digest(in.Refresh), digest(sess.AccessToken), sess.ExpiresAt, digest(sess.RefreshToken), s.allowedHashes).Scan(&sess.User)
	if errors.Is(err, pgx.ErrNoRows) {
		failure(w, 401)
		return
	}
	if err != nil {
		failure(w, 503)
		return
	}
	reply(w, 200, sess)
}
func (s *Server) signout(w http.ResponseWriter, r *http.Request) {
	id, err := DeviceID(r.TLS)
	t := bearer(r)
	if err != nil || t == "" {
		failure(w, 401)
		return
	}
	tag, err := s.pool.Exec(r.Context(), `UPDATE mp_auth_devices SET access_hash=NULL,refresh_hash=NULL WHERE device=$1 AND access_hash=$2 AND access_expires>now() AND NOT revoked`, id, digest(t))
	if err != nil {
		failure(w, 503)
		return
	}
	if tag.RowsAffected() != 1 {
		failure(w, 401)
		return
	}
	reply(w, 200, struct{}{})
}
func (s *Server) lookup(w http.ResponseWriter, r *http.Request) {
	p, err := s.Authenticate(r)
	if err != nil {
		failure(w, 401)
		return
	}
	var raw []byte
	var owner string
	err = s.pool.QueryRow(r.Context(), "SELECT user_id,descriptor FROM mp_auth_devices WHERE device=$1 AND NOT revoked", r.PathValue("device")).Scan(&owner, &raw)
	if errors.Is(err, pgx.ErrNoRows) {
		failure(w, 404)
		return
	}
	if err != nil {
		failure(w, 503)
		return
	}
	if owner != p.User {
		if s.CanLookup == nil {
			failure(w, 404)
			return
		}
		ok, err := s.CanLookup(r.Context(), p.User, owner)
		if err != nil {
			failure(w, 503)
			return
		}
		if !ok {
			failure(w, 404)
			return
		}
	}
	reply(w, 200, json.RawMessage(raw))
}

// DeviceActive locks the enrollment against concurrent revocation until the
// caller's admission or lease transaction completes.
func (s *Server) DeviceActive(ctx context.Context, tx pgx.Tx, p control.Principal) (bool, error) {
	var active bool
	err := tx.QueryRow(ctx, `SELECT true FROM mp_auth_devices WHERE device=$1 AND user_id=$2
		AND NOT revoked AND ($3::text[] IS NULL OR email_hash=ANY($3)) FOR SHARE`, p.Device, p.User, s.allowedHashes).Scan(&active)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return active, err
}

// SetRevocationHandler also repairs pending work for devices revoked by an older edge.
func (s *Server) SetRevocationHandler(ctx context.Context, apply func(context.Context, pgx.Tx, string) error) error {
	err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT device FROM mp_auth_devices WHERE revoked ORDER BY device`)
		if err != nil {
			return err
		}
		devices, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			return err
		}
		for _, device := range devices {
			if err := apply(ctx, tx, device); err != nil {
				return err
			}
		}
		return nil
	})
	if err == nil {
		s.revokeWork = apply
	}
	return err
}

func (s *Server) revoke(w http.ResponseWriter, r *http.Request) {
	p, err := s.Authenticate(r)
	if err != nil {
		failure(w, 401)
		return
	}
	ctx := r.Context()
	device := r.PathValue("device")
	err = pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE mp_auth_devices SET revoked=true,access_hash=NULL,refresh_hash=NULL WHERE device=$1 AND user_id=$2`, device, p.User)
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return pgx.ErrNoRows
		}
		if s.revokeWork != nil {
			return s.revokeWork(ctx, tx, device)
		}
		return nil
	})
	if errors.Is(err, pgx.ErrNoRows) {
		failure(w, 404)
		return
	}
	if err != nil {
		failure(w, 503)
		return
	}
	reply(w, 200, struct{}{})
}

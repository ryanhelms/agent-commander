// Package control owns social authorization, device leases and durable addressed delivery.
package control

import (
	"context"
	"crypto/rand"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
	"sync"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed schema.sql
var schema string

//go:embed social.sql
var socialSchema string

type Principal struct {
	User, Device string
	AccessHash   []byte // Set for authenticated requests. Offline recipient checks leave it nil.
	EmailHash    string // SHA-256 of the verified email for this device enrollment.
}
type Authenticate func(*http.Request) (Principal, error)
type CheckDevice func(context.Context, pgx.Tx, Principal) (bool, error)

type Service struct {
	pool        *pgxpool.Pool
	edge        string
	auth        Authenticate
	checkDevice CheckDevice
	mu          sync.Mutex
	waiters     map[string]map[chan struct{}]struct{}
}

func New(ctx context.Context, pool *pgxpool.Pool, edge string, auth Authenticate, checkDevice CheckDevice) (*Service, error) {
	if pool == nil || auth == nil || !identifier.MatchString(edge) {
		return nil, errors.New("control requires a pool, an edge ID and device authentication")
	}
	err := pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, socialSchema+schema+groupsSchema+workspacesSchema+sharingSchema)
		return err
	})
	if err != nil {
		return nil, err
	}
	return &Service{pool: pool, edge: edge, auth: auth, checkDevice: checkDevice, waiters: make(map[string]map[chan struct{}]struct{})}, nil
}

func (s *Service) requireDevice(ctx context.Context, tx pgx.Tx, p Principal) error {
	if s.checkDevice == nil {
		return nil
	}
	active, err := s.checkDevice(ctx, tx, p)
	if err == nil && !active {
		return forbidden()
	}
	return err
}

// RevokeDevice participates in the credential revocation transaction. Pending
// work in either direction is canceled and a revoked executor loses its lease.
func RevokeDevice(ctx context.Context, tx pgx.Tx, device string) error {
	if _, err := tx.Exec(ctx, retireLease+` WHERE device=$1`, device); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE mp_resources SET actions='{}' WHERE device=$1`, device); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `UPDATE mp_children SET status=CASE WHEN status='pending' THEN 'revoked' ELSE 'uncertain' END
		WHERE (status='pending' AND (sender_device=$1 OR device=$1)) OR (status='processing' AND device=$1)`, device)
	return err
}

// CloseDeviceSession retires a signed-out device's lease in the same transaction
// as its credentials. Pending deliveries can wait for a later enrollment.
func CloseDeviceSession(ctx context.Context, tx pgx.Tx, device string) error {
	if _, err := tx.Exec(ctx, retireLease+` WHERE device=$1`, device); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `UPDATE mp_children SET status='uncertain' WHERE device=$1 AND status='processing'`, device)
	return err
}

type fault struct {
	code int
	msg  string
}

func (e *fault) Error() string  { return e.msg }
func bad(msg string) error      { return &fault{400, msg} }
func forbidden() error          { return &fault{403, "access denied"} }
func missing() error            { return &fault{404, "not found"} }
func conflict(msg string) error { return &fault{409, msg} }
func problem(w http.ResponseWriter, err error) {
	var c *claimConflict
	if errors.As(err, &c) {
		w.WriteHeader(http.StatusConflict)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": c.Error(), "holder": c.Holder})
		return
	}
	var f *fault
	var pg *pgconn.PgError
	switch {
	case errors.As(err, &f):
	case errors.Is(err, pgx.ErrNoRows):
		f = &fault{404, "not found"}
	case errors.As(err, &pg) && (pg.Code == "23505" || pg.Code == "23503"):
		f = &fault{409, "operation conflicts with existing state"}
	default:
		f = &fault{503, "control store unavailable"}
	}
	w.WriteHeader(f.code)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": f.msg})
}

type endpoint func(context.Context, Principal, *http.Request) (any, error)

func (s *Service) Handler() http.Handler {
	mux := http.NewServeMux()
	routes := map[string]endpoint{
		"GET /v1/events":  s.events,
		"PUT /v1/profile": s.setProfile, "GET /v1/profile": s.profile, "GET /v1/users/{handle}": s.profile, "GET /v1/users/{handle}/avatar": s.avatar,
		"GET /v1/friends": s.friends, "POST /v1/friends/{handle}": s.friendChange, "PUT /v1/friends/{handle}": s.friendChange, "DELETE /v1/friends/{handle}": s.friendChange,
		"PUT /v1/resources/{id}": s.putResource, "GET /v1/resources": s.resources, "GET /v1/grants": s.grants, "PUT /v1/grants/{resource}/{handle}": s.changeGrant, "DELETE /v1/grants/{resource}/{handle}": s.changeGrant,
		"POST /v1/access-requests": s.requestAccess, "GET /v1/access-requests": s.accessRequests, "DELETE /v1/access-requests/{id}": s.deleteAccessRequest,
		"POST /v1/session": s.openLease, "PUT /v1/session": s.updateLease, "DELETE /v1/session": s.updateLease,
		"GET /v1/me": s.me, "GET /v1/admin/membership": s.membership, "PUT /v1/admin/membership": s.setMembership, "PUT /v1/admin/policy": s.setPolicy,
		"POST /v1/invites":     s.createInvite,
		"POST /v1/submissions": s.submit, "GET /v1/submissions/{id}": s.submission, "GET /v1/inbox": s.inbox, "POST /v1/children/{id}/claim": s.claim, "PUT /v1/children/{id}/receipt": s.receipt,
	}
	s.groupRoutes(routes)
	s.workspaceRoutes(routes)
	s.sharingRoutes(routes)
	for pattern, op := range routes {
		mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Cache-Control", "no-store")
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("X-Content-Type-Options", "nosniff")
			p, err := s.auth(r)
			if err != nil || p.User == "" || p.Device == "" {
				problem(w, &fault{401, "device authentication required"})
				return
			}
			r.Body = http.MaxBytesReader(w, r.Body, 2<<20)
			v, err := op(r.Context(), p, r)
			if err != nil {
				problem(w, err)
				return
			}
			if image, ok := v.(profileAvatar); ok {
				w.Header().Set("Content-Type", image.contentType)
				_, _ = w.Write(image.data)
				return
			}
			if v == nil {
				v = struct{}{}
			}
			_ = json.NewEncoder(w).Encode(v)
		})
	}
	return mux
}
func body(r *http.Request, v any) error {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return bad("invalid request body")
	}
	if err := dec.Decode(new(any)); err != io.EOF {
		return bad("expected one JSON value")
	}
	return nil
}

var identifier = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`)
var handlePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{1,31}$`)

func validActions(a []string) bool {
	if len(a) == 0 || len(a) > 32 {
		return false
	}
	seen := map[string]bool{}
	for _, v := range a {
		if !identifier.MatchString(v) || seen[v] {
			return false
		}
		seen[v] = true
	}
	return true
}
func ownerPair(a, b string) (string, string) {
	if a > b {
		return b, a
	}
	return a, b
}
func secret() string {
	var b [24]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}
func (s *Service) write(ctx context.Context, f func(pgx.Tx) error) error {
	// Serializable transactions order racing policy edits, admissions and claims.
	for i := 0; i < 5; i++ {
		err := pgx.BeginTxFunc(ctx, s.pool, pgx.TxOptions{IsoLevel: pgx.Serializable}, f)
		var pg *pgconn.PgError
		if !errors.As(err, &pg) || (pg.Code != "40001" && pg.Code != "40P01") {
			return err
		}
	}
	return &fault{503, "concurrent change; retry the same operation"}
}
func (s *Service) CanLookup(ctx context.Context, viewer, owner string) (bool, error) {
	if viewer == "" || owner == "" {
		return false, nil
	}
	if viewer == owner {
		return true, nil
	}
	a, b := ownerPair(viewer, owner)
	var ok bool
	// Either party needs the other's public key to use a grant. A final
	// debit may exhaust it before the requester reads the sealed receipt.
	err := s.pool.QueryRow(ctx, `SELECT EXISTS(SELECT FROM mp_friends WHERE a=$1 AND b=$2 AND accepted)
		OR EXISTS(SELECT FROM mp_available_actions g JOIN mp_resources r ON r.id=g.resource
			WHERE ((g.grantee=$1 AND r.owner_id=$2) OR (g.grantee=$2 AND r.owner_id=$1))
			AND g.source<>'' AND g.action=ANY(r.actions))
		OR EXISTS(SELECT FROM mp_children c
			JOIN mp_group_members sender ON sender.group_id=c.grant_source AND sender.user_id=c.sender
			JOIN mp_group_members owner ON owner.group_id=c.grant_source AND owner.user_id=c.owner_id
			WHERE ((c.sender=$1 AND c.owner_id=$2) OR (c.sender=$2 AND c.owner_id=$1))
			AND c.grant_source<>'' AND c.expires_at>now()
			AND c.status IN ('processing','completed','declined','uncertain'))`, a, b).Scan(&ok)
	return ok, err
}
func (s *Service) WakeDevice(device string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for c := range s.waiters[device] {
		close(c)
	}
	delete(s.waiters, device)
}
func (s *Service) watch(device string) (chan struct{}, func()) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := make(chan struct{})
	if s.waiters[device] == nil {
		s.waiters[device] = make(map[chan struct{}]struct{})
	}
	s.waiters[device][c] = struct{}{}
	return c, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		delete(s.waiters[device], c)
		if len(s.waiters[device]) == 0 {
			delete(s.waiters, device)
		}
	}
}
func (s *Service) PumpOne(ctx context.Context, publish func(context.Context, string) error) (bool, error) {
	done := false
	err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		var id string
		err := tx.QueryRow(ctx, "SELECT id FROM mp_outbox WHERE NOT published ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED").Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		if err = publish(ctx, id); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, "UPDATE mp_outbox SET published=true WHERE id=$1", id)
		done = err == nil
		return err
	})
	return done && err == nil, err
}
func (s *Service) Route(ctx context.Context, id string) (edge, device string, err error) {
	err = s.pool.QueryRow(ctx, `SELECT l.edge,l.device FROM mp_children c JOIN mp_leases l ON l.device=c.device AND l.owner_id=c.owner_id
	WHERE c.id=$1 AND c.status='pending' AND c.expires_at>now() AND l.ready AND l.expires_at>now()`, id).Scan(&edge, &device)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", nil
	}
	return
}

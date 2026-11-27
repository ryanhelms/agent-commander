package identity

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"
	"unicode"

	"agentcommander.network/pilot/internal/control"
	"github.com/jackc/pgx/v5"
)

// Membership requests let a person whom the relay refused at sign-in ask to
// join without a second browser sign-in. A refused enrollment with a verified
// email leaves a short-lived record for that device. The device, proving
// possession of the same key with its certificate, turns the record into a
// request. Admins approve or deny it; an approved request admits the person on
// their next sign-in in allowlist and invite modes, once.
// See design/COMMANDER-NETWORK-DISCOVERY.md, "Membership requests".

const (
	refusalLifetime    = 15 * time.Minute
	denialCoolDown     = 24 * time.Hour
	maxPendingRequests = 200
	maxRequestNote     = 280
)

// errSuspended refuses a suspended member; such a refusal is not requestable.
var errSuspended = errors.New("suspended member")

const membershipRequestSchema = `
 CREATE TABLE IF NOT EXISTS mp_enrollment_refusals(device text PRIMARY KEY, email text NOT NULL, email_hash text NOT NULL, expires_at timestamptz NOT NULL);
 CREATE TABLE IF NOT EXISTS mp_membership_requests(
   id text PRIMARY KEY,
   email text NOT NULL,
   email_hash text NOT NULL UNIQUE,
   device text NOT NULL,
   note text NOT NULL DEFAULT '',
   status text NOT NULL CHECK (status IN ('pending','approved','denied','admitted')),
   created_at timestamptz NOT NULL DEFAULT now(),
   decided_at timestamptz,
   decided_by text NOT NULL DEFAULT ''
 );
 CREATE INDEX IF NOT EXISTS mp_membership_requests_device ON mp_membership_requests(device);
 CREATE INDEX IF NOT EXISTS mp_membership_requests_status ON mp_membership_requests(status, created_at);
`

// recordRefusal remembers a refused, verified enrollment for this device so it
// can ask to join. It runs outside the refused transaction.
func (s *Server) recordRefusal(ctx context.Context, device, email, hash string) bool {
	if hash == "" || email == "" {
		return false
	}
	_, err := s.pool.Exec(ctx, `
		WITH expired AS (DELETE FROM mp_enrollment_refusals WHERE expires_at <= now())
		INSERT INTO mp_enrollment_refusals(device,email,email_hash,expires_at) VALUES ($1,$2,$3,now()+$4::interval)
		ON CONFLICT (device) DO UPDATE SET email=excluded.email, email_hash=excluded.email_hash, expires_at=excluded.expires_at`,
		device, strings.ToLower(email), hash, refusalLifetime.String())
	return err == nil
}

// MembershipRequest is one request as the requester or an admin sees it.
type MembershipRequest struct {
	ID        string     `json:"id"`
	Email     string     `json:"email,omitempty"`
	Note      string     `json:"note,omitempty"`
	Status    string     `json:"status"`
	CreatedAt time.Time  `json:"createdAt"`
	DecidedAt *time.Time `json:"decidedAt,omitempty"`
}

func cleanNote(note string) string {
	note = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) && r != '\n' {
			return -1
		}
		return r
	}, strings.TrimSpace(note))
	if r := []rune(note); len(r) > maxRequestNote {
		note = string(r[:maxRequestNote])
	}
	return note
}

// requestMembership turns this device's recent refusal into a request.
func (s *Server) requestMembership(w http.ResponseWriter, r *http.Request) {
	device, err := DeviceID(r.TLS)
	if err != nil {
		failure(w, http.StatusUnauthorized)
		return
	}
	var in struct {
		Note string `json:"note"`
	}
	if !body(w, r, &in) {
		return
	}
	note := cleanNote(in.Note)
	ctx := r.Context()
	var out MembershipRequest
	status := http.StatusOK
	err = pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		var email, hash string
		err := tx.QueryRow(ctx, `DELETE FROM mp_enrollment_refusals WHERE device=$1 AND expires_at>now()
			RETURNING email, email_hash`, device).Scan(&email, &hash)
		if err != nil {
			return err
		}
		var existing MembershipRequest
		err = tx.QueryRow(ctx, `SELECT id,status,created_at,decided_at FROM mp_membership_requests
			WHERE email_hash=$1 FOR UPDATE`, hash).Scan(&existing.ID, &existing.Status, &existing.CreatedAt, &existing.DecidedAt)
		switch {
		case err == nil && existing.Status == "denied" && existing.DecidedAt != nil && time.Since(*existing.DecidedAt) < denialCoolDown:
			out, status = MembershipRequest{ID: existing.ID, Status: "denied", CreatedAt: existing.CreatedAt, DecidedAt: existing.DecidedAt}, http.StatusTooManyRequests
			return nil
		case err == nil && (existing.Status == "approved" || existing.Status == "pending"):
			// Keep one request per person: refresh the note and device.
			return tx.QueryRow(ctx, `UPDATE mp_membership_requests SET device=$2, note=CASE WHEN $3='' THEN note ELSE $3 END
				WHERE id=$1 RETURNING id,note,status,created_at,decided_at`, existing.ID, device, note).
				Scan(&out.ID, &out.Note, &out.Status, &out.CreatedAt, &out.DecidedAt)
		case err != nil && !errors.Is(err, pgx.ErrNoRows):
			return err
		}
		var pending int
		if err = tx.QueryRow(ctx, "SELECT count(*) FROM mp_membership_requests WHERE status='pending'").Scan(&pending); err != nil {
			return err
		}
		if pending >= maxPendingRequests {
			status = http.StatusTooManyRequests
			out = MembershipRequest{Status: "full"}
			return nil
		}
		id, err := token()
		if err != nil {
			return err
		}
		// A new request, or a fresh one after an admitted or expired denial.
		return tx.QueryRow(ctx, `INSERT INTO mp_membership_requests(id,email,email_hash,device,note,status) VALUES ($1,$2,$3,$4,$5,'pending')
			ON CONFLICT (email_hash) DO UPDATE SET id=excluded.id, device=excluded.device, note=excluded.note, status='pending',
				created_at=now(), decided_at=NULL, decided_by=''
			RETURNING id,note,status,created_at,decided_at`, id, email, hash, device, note).
			Scan(&out.ID, &out.Note, &out.Status, &out.CreatedAt, &out.DecidedAt)
	})
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		// No recent refusal for this device: sign in first.
		failure(w, http.StatusNotFound)
	case err != nil:
		failure(w, http.StatusServiceUnavailable)
	default:
		reply(w, status, out)
	}
}

// myMembershipRequest reports the latest request made from this device.
func (s *Server) myMembershipRequest(w http.ResponseWriter, r *http.Request) {
	device, err := DeviceID(r.TLS)
	if err != nil {
		failure(w, http.StatusUnauthorized)
		return
	}
	var out MembershipRequest
	err = s.pool.QueryRow(r.Context(), `SELECT id,note,status,created_at,decided_at FROM mp_membership_requests
		WHERE device=$1 ORDER BY created_at DESC LIMIT 1`, device).Scan(&out.ID, &out.Note, &out.Status, &out.CreatedAt, &out.DecidedAt)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		failure(w, http.StatusNotFound)
	case err != nil:
		failure(w, http.StatusServiceUnavailable)
	default:
		reply(w, http.StatusOK, out)
	}
}

// adminMembershipRequests lists pending requests for an admin.
func (s *Server) adminMembershipRequests(w http.ResponseWriter, r *http.Request) {
	p, err := s.Authenticate(r)
	if err != nil {
		failure(w, http.StatusUnauthorized)
		return
	}
	ctx := r.Context()
	out := struct {
		Requests []MembershipRequest `json:"requests"`
	}{Requests: []MembershipRequest{}}
	err = pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		active, err := s.DeviceActive(ctx, tx, p)
		if err != nil {
			return err
		}
		ok, err := control.IsAdmin(ctx, tx, p)
		if err != nil {
			return err
		}
		if !active || !ok {
			return denied
		}
		rows, err := tx.Query(ctx, `SELECT id,email,note,status,created_at,decided_at FROM mp_membership_requests
			WHERE status='pending' ORDER BY created_at LIMIT $1`, maxPendingRequests)
		if err != nil {
			return err
		}
		for rows.Next() {
			var m MembershipRequest
			if err := rows.Scan(&m.ID, &m.Email, &m.Note, &m.Status, &m.CreatedAt, &m.DecidedAt); err != nil {
				return err
			}
			out.Requests = append(out.Requests, m)
		}
		return rows.Err()
	})
	switch {
	case errors.Is(err, denied):
		failure(w, http.StatusForbidden)
	case err != nil:
		failure(w, http.StatusServiceUnavailable)
	default:
		reply(w, http.StatusOK, out)
	}
}

// decideMembershipRequest approves or denies a pending request. Approval also
// adds the email to the allowlist so later sign-ins keep working.
func (s *Server) decideMembershipRequest(approve bool) adminOperation {
	return func(ctx context.Context, tx pgx.Tx, p control.Principal, r *http.Request) error {
		status := "denied"
		if approve {
			status = "approved"
		}
		var email string
		err := tx.QueryRow(ctx, `UPDATE mp_membership_requests SET status=$2, decided_at=now(), decided_by=$3
			WHERE id=$1 AND status='pending' RETURNING email`, r.PathValue("id"), status, p.User).Scan(&email)
		if err != nil || !approve {
			return err
		}
		_, err = tx.Exec(ctx, "UPDATE mp_membership SET allowed_emails=array_append(allowed_emails,$1) WHERE NOT ($1=ANY(allowed_emails))", email)
		return err
	}
}

package control

import (
	"context"
	"net/http"
	"net/mail"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type membershipSettings struct {
	Mode          string   `json:"mode"`
	AllowedEmails []string `json:"allowedEmails"`
	Admins        []string `json:"admins"`
}

type membershipInfo struct {
	membershipSettings
	MemberCount int64 `json:"memberCount"`
}

func normalizedEmails(list []string) ([]string, error) {
	result := make([]string, 0, len(list))
	seen := make(map[string]bool, len(list))
	for _, raw := range list {
		email := strings.ToLower(raw)
		addr, err := mail.ParseAddress(email)
		if err != nil || addr.Address != email {
			return nil, bad("invalid email address")
		}
		if !seen[email] {
			result = append(result, email)
			seen[email] = true
		}
	}
	return result, nil
}

func (m *membershipSettings) normalize() error {
	switch m.Mode {
	case "open", "allowlist", "invite":
	default:
		return bad("invalid membership mode")
	}
	var err error
	if m.AllowedEmails, err = normalizedEmails(m.AllowedEmails); err != nil {
		return err
	}
	m.Admins, err = normalizedEmails(m.Admins)
	return err
}

// InitMembership seeds policy once. Edge and host restarts retain any edits
// made through the admin API, including addresses admitted with an invite.
func InitMembership(ctx context.Context, tx pgx.Tx, allowedEmails, admins []string) error {
	settings := membershipSettings{Mode: "open", AllowedEmails: allowedEmails, Admins: admins}
	if len(allowedEmails) > 0 {
		settings.Mode = "allowlist"
	}
	if err := settings.normalize(); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, socialSchema); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `INSERT INTO mp_membership(mode, allowed_emails, admins)
		VALUES ($1,$2,$3) ON CONFLICT (singleton) DO NOTHING`, settings.Mode, settings.AllowedEmails, settings.Admins)
	return err
}

func MembershipMode(ctx context.Context, pool *pgxpool.Pool) (string, error) {
	var mode string
	err := pool.QueryRow(ctx, "SELECT mode FROM mp_membership").Scan(&mode)
	return mode, err
}

type memberAccess struct {
	Admin bool   `json:"admin"`
	Mode  string `json:"mode"`
}

type membershipReader interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}

func readAccess(ctx context.Context, db membershipReader, p Principal) (memberAccess, error) {
	var access memberAccess
	err := db.QueryRow(ctx, `SELECT $1 = ANY(admin_hashes), mode FROM mp_membership_policy`, p.EmailHash).Scan(&access.Admin, &access.Mode)
	return access, err
}

func (s *Service) me(ctx context.Context, p Principal, _ *http.Request) (any, error) {
	return readAccess(ctx, s.pool, p)
}

func (s *Service) membership(ctx context.Context, p Principal, _ *http.Request) (any, error) {
	var m membershipInfo
	var admin bool
	err := s.pool.QueryRow(ctx, `SELECT mode, allowed_emails, admins, (SELECT count(*) FROM mp_members),
		$1 = ANY(admin_hashes) FROM mp_membership_policy`, p.EmailHash).
		Scan(&m.Mode, &m.AllowedEmails, &m.Admins, &m.MemberCount, &admin)
	if err == nil && !admin {
		return nil, forbidden()
	}
	return m, err
}

func (s *Service) setMembership(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in membershipSettings
	if err := body(r, &in); err != nil {
		return nil, err
	}
	var updated membershipInfo
	err := s.write(ctx, func(tx pgx.Tx) error {
		if err := s.requireDevice(ctx, tx, p); err != nil {
			return err
		}
		access, err := readAccess(ctx, tx, p)
		if err != nil {
			return err
		}
		if !access.Admin {
			return forbidden()
		}
		if len(in.Admins) == 0 {
			return bad("membership requires at least one admin")
		}
		if in.AllowedEmails == nil {
			return bad("provide allowedEmails")
		}
		if err := in.normalize(); err != nil {
			return err
		}
		updated.membershipSettings = in
		return tx.QueryRow(ctx, `UPDATE mp_membership SET mode=$1, allowed_emails=$2, admins=$3
			RETURNING (SELECT count(*) FROM mp_members)`, in.Mode, in.AllowedEmails, in.Admins).Scan(&updated.MemberCount)
	})
	return updated, err
}

type invite struct {
	Code      string    `json:"code"`
	ExpiresAt time.Time `json:"expiresAt"`
	MaxUses   int64     `json:"maxUses"`
	Uses      int64     `json:"uses"`
}

func (s *Service) createInvite(ctx context.Context, p Principal, r *http.Request) (any, error) {
	in := struct {
		MaxUses  int64 `json:"maxUses"`
		TTLHours int64 `json:"ttlHours"`
	}{MaxUses: 5, TTLHours: 168}
	if err := body(r, &in); err != nil {
		return nil, err
	}
	if in.MaxUses < 1 || in.TTLHours < 1 {
		return nil, bad("maxUses and ttlHours must be positive")
	}
	lastRFC3339 := time.Date(9999, 12, 31, 23, 59, 59, 0, time.UTC)
	if in.TTLHours > (lastRFC3339.Unix()-time.Now().Unix())/3600 {
		return nil, bad("invite expiration exceeds the RFC 3339 date range")
	}
	v := invite{Code: secret(), MaxUses: in.MaxUses}
	err := s.write(ctx, func(tx pgx.Tx) error {
		if err := s.requireDevice(ctx, tx, p); err != nil {
			return err
		}
		access, err := readAccess(ctx, tx, p)
		if err != nil {
			return err
		}
		if !access.Admin && access.Mode != "open" {
			return forbidden()
		}
		return tx.QueryRow(ctx, `INSERT INTO mp_invites(code, expires_at, max_uses)
			VALUES ($1,clock_timestamp()+$2::bigint * interval '1 hour',$3) RETURNING expires_at`,
			v.Code, in.TTLHours, in.MaxUses).Scan(&v.ExpiresAt)
	})
	return v, err
}

// IsAdmin holds the policy revision while identity applies a moderation action.
func IsAdmin(ctx context.Context, tx pgx.Tx, p Principal) (bool, error) {
	var admin bool
	err := tx.QueryRow(ctx, "SELECT $1=ANY(admin_hashes) FROM mp_membership_policy FOR SHARE", p.EmailHash).Scan(&admin)
	return admin, err
}

// SuspendMemberWork fences every current device and settles pending deliveries
// in both directions. Published capabilities can be used again after sign-in.
func SuspendMemberWork(ctx context.Context, tx pgx.Tx, user string) error {
	if _, err := tx.Exec(ctx, retireLease+" WHERE owner_id=$1", user); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `UPDATE mp_children SET status=CASE WHEN status='processing' THEN 'uncertain' ELSE 'revoked' END
		WHERE (status='pending' AND (sender=$1 OR owner_id=$1)) OR (status='processing' AND owner_id=$1)`, user)
	return err
}

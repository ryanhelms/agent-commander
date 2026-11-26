package identity

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"agentcommander.network/pilot/internal/control"
	"github.com/jackc/pgx/v5"
)

type adminOperation func(context.Context, pgx.Tx, control.Principal, *http.Request) error

// Recheck the current enrollment and verified admin hash inside the transaction
// that changes another member's credentials and fences their work.
func (s *Server) admin(op adminOperation) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		p, err := s.Authenticate(r)
		if err != nil {
			failure(w, http.StatusUnauthorized)
			return
		}
		ctx := r.Context()
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
			return op(ctx, tx, p, r)
		})
		switch {
		case errors.Is(err, denied):
			failure(w, http.StatusForbidden)
		case errors.Is(err, pgx.ErrNoRows):
			failure(w, http.StatusNotFound)
		case err != nil:
			failure(w, http.StatusServiceUnavailable)
		default:
			reply(w, http.StatusOK, struct{}{})
		}
	}
}

func (s *Server) revokeEnrollment(ctx context.Context, tx pgx.Tx, device, requiredOwner string) (string, bool, error) {
	var owner string
	var revoked bool
	err := tx.QueryRow(ctx, `SELECT user_id,revoked FROM mp_auth_devices
		WHERE device=$1 AND ($2='' OR user_id=$2) FOR UPDATE`, device, requiredOwner).Scan(&owner, &revoked)
	if err != nil || revoked {
		return owner, false, err
	}
	_, err = tx.Exec(ctx, "UPDATE mp_auth_devices SET revoked=true,access_hash=NULL,refresh_hash=NULL WHERE device=$1", device)
	if err == nil && s.revokeWork != nil {
		err = s.revokeWork(ctx, tx, device)
	}
	return owner, true, err
}

func (s *Server) adminRevoke(ctx context.Context, tx pgx.Tx, p control.Principal, r *http.Request) error {
	device := r.PathValue("device")
	owner, changed, err := s.revokeEnrollment(ctx, tx, device, "")
	if err != nil || !changed {
		return err
	}
	return control.RecordModeration(ctx, tx, owner, "device.revoked", p.User, device)
}

func (s *Server) setSuspended(suspend bool) adminOperation {
	return func(ctx context.Context, tx pgx.Tx, p control.Principal, r *http.Request) error {
		var user string
		var current bool
		err := tx.QueryRow(ctx, `SELECT m.user_id,m.suspended FROM mp_members m JOIN mp_profiles u USING(user_id)
			WHERE u.handle=$1 FOR UPDATE OF m`, strings.ToLower(r.PathValue("handle"))).Scan(&user, &current)
		if err != nil || current == suspend {
			return err
		}
		if _, err := tx.Exec(ctx, "UPDATE mp_members SET suspended=$2 WHERE user_id=$1", user, suspend); err != nil {
			return err
		}
		kind := "member.unsuspended"
		if suspend {
			kind = "member.suspended"
			if _, err := tx.Exec(ctx, "UPDATE mp_auth_devices SET access_hash=NULL,refresh_hash=NULL WHERE user_id=$1", user); err != nil {
				return err
			}
			if err := control.SuspendMemberWork(ctx, tx, user); err != nil {
				return err
			}
		}
		return control.RecordModeration(ctx, tx, user, kind, p.User, "")
	}
}

// AdminMember is one relay member as its admin sees it.
type AdminMember struct {
	Handle    string `json:"handle"`
	Suspended bool   `json:"suspended"`
	Admin     bool   `json:"admin"`
}

// AdminDevice is one enrolled, unrevoked device. Enrollment carries no device
// name, so Name is empty. LastSeen is nil while the device is online.
type AdminDevice struct {
	ID       string     `json:"id"`
	Name     string     `json:"name"`
	Owner    string     `json:"owner"`
	Online   bool       `json:"online"`
	LastSeen *time.Time `json:"lastSeen"`
}

// AdminRoster lists members and devices for the moderation page.
type AdminRoster struct {
	Members []AdminMember `json:"members"`
	Devices []AdminDevice `json:"devices"`
}

func (s *Server) adminMembers(w http.ResponseWriter, r *http.Request) {
	p, err := s.Authenticate(r)
	if err != nil {
		failure(w, http.StatusUnauthorized)
		return
	}
	ctx := r.Context()
	roster := AdminRoster{Members: []AdminMember{}, Devices: []AdminDevice{}}
	err = pgx.BeginTxFunc(ctx, s.pool, pgx.TxOptions{IsoLevel: pgx.RepeatableRead}, func(tx pgx.Tx) error {
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
		rows, err := tx.Query(ctx, `SELECT coalesce(u.handle,''),m.suspended,m.contact_key<>'' AND m.contact_key=ANY(pol.admin_hashes)
			FROM mp_members m LEFT JOIN mp_profiles u USING(user_id) CROSS JOIN mp_membership_policy pol
			ORDER BY u.handle NULLS LAST,m.user_id`)
		if err != nil {
			return err
		}
		if roster.Members, err = pgx.CollectRows(rows, pgx.RowToStructByPos[AdminMember]); err != nil {
			return err
		}
		rows, err = tx.Query(ctx, `SELECT d.device,'',coalesce(u.handle,''),coalesce(live.online,false),
			CASE WHEN NOT coalesce(live.online,false) THEN live.last_seen END
			FROM mp_auth_devices d LEFT JOIN mp_profiles u ON u.user_id=d.user_id
			LEFT JOIN LATERAL (SELECT ready AND expires_at>now() AS online,
				greatest(last_seen, CASE WHEN expires_at<=now() THEN expires_at END) AS last_seen
				FROM mp_leases l WHERE l.device=d.device AND l.owner_id=d.user_id) live ON true
			WHERE NOT d.revoked ORDER BY u.handle NULLS LAST,d.device`)
		if err != nil {
			return err
		}
		roster.Devices, err = pgx.CollectRows(rows, pgx.RowToStructByPos[AdminDevice])
		return err
	})
	switch {
	case errors.Is(err, denied):
		reply(w, http.StatusForbidden, map[string]string{"error": "only a relay admin can list members and devices"})
	case err != nil:
		failure(w, http.StatusServiceUnavailable)
	default:
		reply(w, http.StatusOK, roster)
	}
}

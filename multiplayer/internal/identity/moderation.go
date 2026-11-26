package identity

import (
	"context"
	"errors"
	"net/http"
	"strings"

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

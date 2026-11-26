package control

import (
	"context"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
)

type Lease struct {
	Session    string    `json:"session"`
	Generation int64     `json:"generation"`
	ExpiresAt  time.Time `json:"expires_at"`
}
type leaseProof struct {
	Session    string `json:"session"`
	Generation int64  `json:"generation"`
}

// A takeover overwrites expires_at. Preserve the old lease's actual end,
// including when it already expired before this request arrived.
const endedLease = `least(mp_leases.expires_at, statement_timestamp())`
const retireLease = `UPDATE mp_leases SET ready=false,expires_at=` + endedLease

func (s *Service) openLease(ctx context.Context, p Principal, _ *http.Request) (any, error) {
	sess := secret()
	var v Lease
	err := s.write(ctx, func(tx pgx.Tx) error {
		if err := s.requireDevice(ctx, tx, p); err != nil {
			return err
		}
		err := tx.QueryRow(ctx, `INSERT INTO mp_leases(device,owner_id,edge,session,generation,expires_at,ready) VALUES($1,$2,$3,$4,1,now()+interval '65 seconds',false)
		ON CONFLICT(device) DO UPDATE SET last_seen=`+endedLease+`,edge=EXCLUDED.edge,session=EXCLUDED.session,generation=mp_leases.generation+1,expires_at=EXCLUDED.expires_at,ready=false
		WHERE mp_leases.owner_id=EXCLUDED.owner_id RETURNING session,generation,expires_at`, p.Device, p.User, s.edge, sess).Scan(&v.Session, &v.Generation, &v.ExpiresAt)
		if err != nil {
			return err
		}
		// The device can open many later sessions. Freeze the old generation's
		// end on its remaining claims while last_seen still identifies it.
		if v.Generation > 1 {
			_, err := tx.Exec(ctx, `UPDATE mp_workspace_claims c SET lease_ended_at=l.last_seen
				FROM mp_leases l WHERE l.device=$1 AND c.device=l.device AND c.generation=l.generation-1`, p.Device)
			if err != nil {
				return err
			}
		}
		// An irreversible operation may already have run on the displaced connection.
		_, err = tx.Exec(ctx, `UPDATE mp_children SET status='uncertain' WHERE device=$1 AND owner_id=$2 AND status='processing'`, p.Device, p.User)
		return err
	})
	return v, err
}

// guardLease serializes a claimed action with session takeover on any other edge.
func (s *Service) guardLease(ctx context.Context, tx pgx.Tx, p Principal, in leaseProof) error {
	if err := s.requireDevice(ctx, tx, p); err != nil {
		return err
	}
	var ok bool
	err := tx.QueryRow(ctx, `SELECT ready AND expires_at>clock_timestamp() FROM mp_leases WHERE device=$1 AND owner_id=$2 AND generation=$3 AND session=$4 FOR UPDATE`, p.Device, p.User, in.Generation, in.Session).Scan(&ok)
	if err != nil && err != pgx.ErrNoRows {
		return err
	}
	if !ok {
		return conflict("lease is no longer current")
	}
	return nil
}
func (s *Service) updateLease(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in leaseProof
	if err := body(r, &in); err != nil {
		return nil, err
	}
	if r.Method == "DELETE" {
		var ok bool
		err := s.write(ctx, func(tx pgx.Tx) error {
			if err := tx.QueryRow(ctx, retireLease+` WHERE device=$1 AND owner_id=$2 AND generation=$3 AND session=$4 RETURNING true`, p.Device, p.User, in.Generation, in.Session).Scan(&ok); err != nil {
				if err == pgx.ErrNoRows {
					return conflict("lease is no longer current")
				}
				return err
			}
			_, err := tx.Exec(ctx, `UPDATE mp_children SET status='uncertain' WHERE device=$1 AND status='processing'`, p.Device)
			return err
		})
		return nil, err
	}
	var v Lease
	err := s.pool.QueryRow(ctx, `UPDATE mp_leases SET ready=true,expires_at=clock_timestamp()+interval '65 seconds' WHERE device=$1 AND owner_id=$2 AND generation=$3 AND session=$4 AND expires_at>clock_timestamp()
	RETURNING session,generation,expires_at`, p.Device, p.User, in.Generation, in.Session).Scan(&v.Session, &v.Generation, &v.ExpiresAt)
	if err == pgx.ErrNoRows {
		return nil, conflict("lease is no longer current")
	}
	return v, err
}
func (s *Service) inbox(ctx context.Context, p Principal, r *http.Request) (any, error) {
	q := r.URL.Query()
	generation, err := strconv.ParseInt(q.Get("generation"), 10, 64)
	if err != nil {
		return nil, bad("generation required")
	}
	wait := 0
	if q.Get("wait") != "" {
		wait, err = strconv.Atoi(q.Get("wait"))
		if err != nil || wait < 0 || wait > 20 {
			return nil, bad("wait must be 0–20 seconds")
		}
	}
	wake, finish := s.watch(p.Device)
	defer finish()
	fetch := func() ([]Child, error) {
		var out []Child
		err := s.write(ctx, func(tx pgx.Tx) error {
			// Acknowledging the issued generation by polling also announces readiness.
			tag, err := tx.Exec(ctx, `UPDATE mp_leases SET ready=true WHERE device=$1 AND owner_id=$2 AND generation=$3 AND session=$4 AND expires_at>clock_timestamp()`, p.Device, p.User, generation, q.Get("session"))
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 0 {
				return conflict("lease is no longer current")
			}
			rows, err := tx.Query(ctx, `SELECT `+childFields+` FROM mp_children c
			WHERE device=$1 AND owner_id=$2 AND status='pending' AND expires_at>statement_timestamp()
			AND `+activeChildGrant+` ORDER BY expires_at,id LIMIT 32`, p.Device, p.User)
			if err != nil {
				return err
			}
			out, err = scanChildren(rows)
			return err
		})
		return out, err
	}
	out, err := fetch()
	if err != nil {
		return nil, err
	}
	if len(out) == 0 && wait > 0 {
		// Ingress may send this request to a different edge than the session’s
		// wake subscriber. Poll authoritative storage on a short bounded interval.
		timer := time.NewTimer(min(time.Duration(wait)*time.Second, 2*time.Second))
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-wake:
		case <-timer.C:
		}
		out, err = fetch()
	}
	return map[string]any{"children": out}, err
}

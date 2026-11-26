package control

import (
	"context"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

type Limit struct {
	Action    string    `json:"action"`
	ExpiresAt time.Time `json:"expires_at"`
	MaxUses   int64     `json:"max_uses"`
}

type LimitUsage struct {
	Limit
	Used int64 `json:"used"`
}

type grantPolicy struct {
	Actions   []string  `json:"actions"`
	ExpiresAt time.Time `json:"expires_at"`
	MaxUses   int64     `json:"max_uses"`
	Limits    []Limit   `json:"limits"`
}

func (g *grantPolicy) validate(now time.Time) error {
	valid := func(exp time.Time, count int64) bool { return exp.After(now) && count >= 1 && count <= 1_000_000 }
	if g.Limits == nil {
		if !valid(g.ExpiresAt, g.MaxUses) || !validActions(g.Actions) {
			return bad("grant needs actions, future expiry and 1–1000000 uses")
		}
		slices.Sort(g.Actions)
		return nil
	}
	declared := slices.Clone(g.Actions)
	g.Actions = nil
	g.MaxUses = 0
	g.ExpiresAt = time.Time{}
	for _, l := range g.Limits {
		if !valid(l.ExpiresAt, l.MaxUses) {
			return bad("each limit needs a future expiry and 1–1000000 uses")
		}
		g.Actions = append(g.Actions, l.Action)
		if l.ExpiresAt.After(g.ExpiresAt) {
			g.ExpiresAt = l.ExpiresAt
		}
		g.MaxUses += l.MaxUses
	}
	if !validActions(g.Actions) {
		return bad("provide 1–32 distinct action limits")
	}
	slices.Sort(g.Actions)
	slices.Sort(declared)
	if declared != nil && !slices.Equal(g.Actions, declared) {
		return bad("actions must match limits")
	}
	return nil
}

type Grant struct {
	Resource  string       `json:"resource"`
	Owner     string       `json:"owner"`
	Device    string       `json:"device"`
	Grantee   string       `json:"grantee"`
	Handle    string       `json:"handle"`
	Actions   []string     `json:"actions"`
	ExpiresAt time.Time    `json:"expires_at"`
	MaxUses   int64        `json:"max_uses"`
	Used      int64        `json:"used"`
	Limits    []LimitUsage `json:"limits,omitempty"`
}

func (s *Service) grants(ctx context.Context, p Principal, _ *http.Request) (any, error) {
	rows, err := s.pool.Query(ctx, `SELECT g.resource,r.owner_id,r.device,g.grantee,coalesce(p.handle,''),g.actions,g.expires_at,g.max_uses,
        CASE WHEN g.per_action THEN COALESCE(l.used,0) ELSE g.used END,l.limits FROM mp_grants g
        JOIN mp_resources r ON r.id=g.resource JOIN mp_profiles p ON p.user_id=g.grantee
        LEFT JOIN LATERAL (SELECT sum(used)::bigint AS used,
          jsonb_agg(jsonb_build_object('action',action,'expires_at',expires_at,'max_uses',max_uses,'used',used) ORDER BY action) AS limits
          FROM mp_grant_limits WHERE resource=g.resource AND grantee=g.grantee AND action=ANY(g.actions)) l ON g.per_action
        WHERE g.grantee=$1 OR r.owner_id=$1 ORDER BY g.resource,g.grantee`, p.User)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	results := []Grant{}
	for rows.Next() {
		var g Grant
		if err := rows.Scan(&g.Resource, &g.Owner, &g.Device, &g.Grantee, &g.Handle, &g.Actions, &g.ExpiresAt, &g.MaxUses, &g.Used, &g.Limits); err != nil {
			return nil, err
		}
		results = append(results, g)
	}
	return map[string]any{"grants": results}, rows.Err()
}

func (s *Service) changeGrant(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in grantPolicy
	if r.Method == "PUT" {
		if err := body(r, &in); err != nil {
			return nil, err
		}
		if err := in.validate(time.Now()); err != nil {
			return nil, err
		}
	}
	res := r.PathValue("resource")
	err := s.write(ctx, func(tx pgx.Tx) error {
		var caps []string
		if err := tx.QueryRow(ctx, `SELECT actions FROM mp_resources WHERE id=$1 AND owner_id=$2 AND device=$3 FOR UPDATE`, res, p.User, p.Device).Scan(&caps); err != nil {
			return err
		}
		var peer string
		if err := tx.QueryRow(ctx, "SELECT user_id FROM mp_profiles WHERE handle=$1", strings.ToLower(r.PathValue("handle"))).Scan(&peer); err != nil {
			return err
		}
		if peer == p.User {
			return bad("choose a friend")
		}
		if r.Method == "DELETE" {
			tag, err := tx.Exec(ctx, `DELETE FROM mp_grants WHERE resource=$1 AND grantee=$2`, res, peer)
			if err != nil {
				return err
			}
			_, err = tx.Exec(ctx, `UPDATE mp_children SET status='revoked' WHERE resource=$1 AND sender=$2 AND status='pending'`, res, peer)
			if err != nil || tag.RowsAffected() == 0 {
				return err
			}
			return recordEvent(ctx, tx, peer, "grant.revoked", p.User, res)
		}
		a, b := ownerPair(p.User, peer)
		var ok bool
		err := tx.QueryRow(ctx, "SELECT accepted FROM mp_friends WHERE a=$1 AND b=$2 FOR SHARE", a, b).Scan(&ok)
		if errors.Is(err, pgx.ErrNoRows) || err == nil && !ok {
			return forbidden()
		}
		if err != nil {
			return err
		}
		for _, v := range in.Actions {
			if !slices.Contains(caps, v) {
				return bad("grant contains unsupported action")
			}
		}
		if err := in.replace(ctx, tx, res, peer); err != nil {
			return err
		}
		return recordEvent(ctx, tx, peer, "grant.received", p.User, res)
	})
	return nil, err
}

func (g grantPolicy) replace(ctx context.Context, tx pgx.Tx, res, peer string) error {
	// A renewed grant is new consent. Settle work that already lost its old grant
	// before writing the replacement, even if neither device has polled recently.
	if err := denyUnavailableForGrant(ctx, tx, res, peer); err != nil {
		return err
	}
	if g.Limits != nil {
		// Old aggregate grants predate the per-action usage ledger. If the full
		// execution history belongs to this grant, reconstruct its exact debits.
		var unknown bool
		err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT FROM mp_grants g WHERE resource=$1 AND grantee=$2 AND NOT per_action AND used>
            (SELECT COALESCE(sum(l.used),0) FROM mp_grant_limits l WHERE l.resource=$1 AND l.grantee=$2))`, res, peer).Scan(&unknown)
		if err != nil {
			return err
		}
		if unknown {
			var consistent bool
			err = tx.QueryRow(ctx, `SELECT g.used=count(c.id) FROM mp_grants g
                LEFT JOIN mp_children c ON c.resource=g.resource AND c.sender=g.grantee AND c.status IN ('processing','completed','declined','uncertain')
                WHERE g.resource=$1 AND g.grantee=$2 GROUP BY g.used`, res, peer).Scan(&consistent)
			if err != nil {
				return err
			}
			if !consistent {
				return conflict("legacy use spans multiple grants; revoke and issue a fresh grant to choose new action budgets")
			}
			_, err = tx.Exec(ctx, `INSERT INTO mp_grant_limits(resource,grantee,action,used)
                SELECT resource,sender,action,count(*) FROM mp_children WHERE resource=$1 AND sender=$2 AND status IN ('processing','completed','declined','uncertain')
                GROUP BY resource,sender,action ON CONFLICT(resource,grantee,action) DO UPDATE SET used=EXCLUDED.used`, res, peer)
			if err != nil {
				return err
			}
		}
	}
	_, err := tx.Exec(ctx, `INSERT INTO mp_grants(resource,grantee,actions,expires_at,max_uses,per_action) VALUES($1,$2,$3,$4,$5,$6)
        ON CONFLICT(resource,grantee) DO UPDATE SET actions=EXCLUDED.actions,expires_at=EXCLUDED.expires_at,
        max_uses=EXCLUDED.max_uses,per_action=EXCLUDED.per_action`, res, peer, g.Actions, g.ExpiresAt, g.MaxUses, g.Limits != nil)
	if err != nil {
		return err
	}
	if g.Limits != nil {
		if _, err = tx.Exec(ctx, `DELETE FROM mp_grant_limits WHERE resource=$1 AND grantee=$2 AND NOT(action=ANY($3))`, res, peer, g.Actions); err != nil {
			return err
		}
		for _, l := range g.Limits {
			if _, err = tx.Exec(ctx, `INSERT INTO mp_grant_limits(resource,grantee,action,expires_at,max_uses) VALUES($1,$2,$3,$4,$5)
                ON CONFLICT(resource,grantee,action) DO UPDATE SET expires_at=EXCLUDED.expires_at,max_uses=EXCLUDED.max_uses`, res, peer, l.Action, l.ExpiresAt, l.MaxUses); err != nil {
				return err
			}
		}
		if _, err = tx.Exec(ctx, `UPDATE mp_grants SET used=(SELECT COALESCE(sum(used),0) FROM mp_grant_limits WHERE resource=$1 AND grantee=$2)
            WHERE resource=$1 AND grantee=$2`, res, peer); err != nil {
			return err
		}
	}
	_, err = tx.Exec(ctx, `UPDATE mp_children SET status='revoked' WHERE resource=$1 AND sender=$2 AND status='pending' AND NOT(action=ANY($3))`, res, peer, g.Actions)
	if err != nil {
		return err
	}
	return denyUnavailableForGrant(ctx, tx, res, peer)
}

func denyUnavailableForGrant(ctx context.Context, tx pgx.Tx, resource, sender string) error {
	_, err := tx.Exec(ctx, denyUnavailableChildren+` AND c.resource=$1 AND c.sender=$2`, resource, sender)
	return err
}

// Consume under the same serializable transaction as the child execution claim.
// A refused claim leaves both usage ledgers unchanged.
func consume(ctx context.Context, tx pgx.Tx, c Child) (bool, error) {
	var perAction bool
	err := tx.QueryRow(ctx, `SELECT g.per_action FROM mp_resources r JOIN mp_grants g ON g.resource=r.id
        JOIN mp_friends f ON f.a=least(g.grantee,r.owner_id) AND f.b=greatest(g.grantee,r.owner_id)
        WHERE g.grantee=$1 AND r.id=$2 AND r.device=$3 AND r.owner_id=$4 AND $5=ANY(r.actions) AND $5=ANY(g.actions)
        AND f.accepted AND $6::timestamptz>clock_timestamp() FOR UPDATE OF g`, c.Sender, c.Resource, c.Device, c.Owner, c.Action, c.ExpiresAt).Scan(&perAction)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if perAction {
		tag, err := tx.Exec(ctx, `UPDATE mp_grant_limits SET used=used+1 WHERE resource=$1 AND grantee=$2 AND action=$3 AND used<max_uses AND expires_at>clock_timestamp() AND $4::timestamptz>clock_timestamp()`, c.Resource, c.Sender, c.Action, c.ExpiresAt)
		if err != nil || tag.RowsAffected() == 0 {
			return false, err
		}
		_, err = tx.Exec(ctx, `UPDATE mp_grants SET used=used+1 WHERE resource=$1 AND grantee=$2`, c.Resource, c.Sender)
		return err == nil, err
	}
	tag, err := tx.Exec(ctx, `UPDATE mp_grants SET used=used+1 WHERE resource=$1 AND grantee=$2 AND used<max_uses AND expires_at>clock_timestamp() AND $3::timestamptz>clock_timestamp()`, c.Resource, c.Sender, c.ExpiresAt)
	if err != nil || tag.RowsAffected() == 0 {
		return false, err
	}
	_, err = tx.Exec(ctx, `INSERT INTO mp_grant_limits(resource,grantee,action,used) VALUES($1,$2,$3,1)
		ON CONFLICT(resource,grantee,action) DO UPDATE SET used=mp_grant_limits.used+1`, c.Resource, c.Sender, c.Action)
	return err == nil, err
}

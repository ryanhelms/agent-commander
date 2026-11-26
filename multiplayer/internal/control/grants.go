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
	Action       string    `json:"action"`
	ExpiresAt    time.Time `json:"expires_at"`
	MaxUses      int64     `json:"max_uses"`
	Approval     string    `json:"approval"`
	BudgetTokens int64     `json:"budgetTokens"`
	Attribution  string    `json:"attribution"`
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
	for i := range g.Limits {
		l := &g.Limits[i]
		if !valid(l.ExpiresAt, l.MaxUses) {
			return bad("each limit needs a future expiry and 1–1000000 uses")
		}
		if l.Approval == "" {
			l.Approval = "ask"
		}
		if l.Attribution == "" {
			l.Attribution = "owner"
		}
		if l.Approval != "ask" && l.Approval != "auto" {
			return bad("approval must be ask or auto")
		}
		if l.Attribution != "owner" && l.Attribution != "requester" {
			return bad("attribution must be owner or requester")
		}
		if l.BudgetTokens < 0 {
			return bad("budgetTokens must be nonnegative")
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
	// Sources lets the owner mirror each group independently of direct grants.
	// The empty key names the direct grant.
	Sources map[string][]string `json:"sources,omitempty"`
}

func (s *Service) grants(ctx context.Context, p Principal, _ *http.Request) (any, error) {
	rows, err := s.pool.Query(ctx, `SELECT pair.resource,r.owner_id,r.device,pair.grantee,coalesce(p.handle,''),
		coalesce(a.actions,'{}'),pair.expires_at,pair.max_uses,pair.used,
		CASE WHEN pair.needs_limits THEN a.limits END, CASE WHEN r.owner_id=$1 THEN pair.sources END
		FROM (
			SELECT g.resource,g.grantee,max(g.expires_at) AS expires_at,sum(g.max_uses)::bigint AS max_uses,
				sum(g.used)::bigint AS used,count(*)>1 OR bool_or(g.per_action) AS needs_limits,
				jsonb_object_agg(g.source,g.actions) AS sources
			FROM mp_grants g JOIN mp_resources r ON r.id=g.resource
			WHERE r.owner_id=$1 OR g.grantee=$1 GROUP BY g.resource,g.grantee
		) pair JOIN mp_resources r ON r.id=pair.resource JOIN mp_profiles p ON p.user_id=pair.grantee
		LEFT JOIN LATERAL (
			SELECT array_agg(action ORDER BY action) AS actions,
				jsonb_agg(jsonb_build_object('action',action,'expires_at',expires_at,'max_uses',max_uses,'used',used,
					'approval',approval,'budgetTokens',budget_tokens,'attribution',attribution) ORDER BY action) AS limits
			FROM mp_selected_grant_actions WHERE resource=pair.resource AND grantee=pair.grantee
		) a ON true ORDER BY pair.resource,pair.grantee`, p.User)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	results := []Grant{}
	for rows.Next() {
		var g Grant
		if err := rows.Scan(&g.Resource, &g.Owner, &g.Device, &g.Grantee, &g.Handle, &g.Actions, &g.ExpiresAt, &g.MaxUses, &g.Used, &g.Limits, &g.Sources); err != nil {
			return nil, err
		}
		results = append(results, g)
	}
	return map[string]any{"grants": results}, rows.Err()
}

func (s *Service) changeGrant(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var policy *grantPolicy
	if r.Method == "PUT" {
		policy = &grantPolicy{}
		if err := body(r, policy); err != nil {
			return nil, err
		}
		if err := policy.validate(time.Now()); err != nil {
			return nil, err
		}
	}
	res, target := r.PathValue("resource"), r.PathValue("handle")
	err := s.write(ctx, func(tx pgx.Tx) error {
		if err := s.requireDevice(ctx, tx, p); err != nil {
			return err
		}
		var caps []string
		if err := tx.QueryRow(ctx, `SELECT actions FROM mp_resources WHERE id=$1 AND owner_id=$2 AND device=$3 FOR UPDATE`, res, p.User, p.Device).Scan(&caps); err != nil {
			return missingRow(err, "no resource "+res)
		}
		if policy != nil {
			for _, action := range policy.Actions {
				if !slices.Contains(caps, action) {
					return bad("resource " + res + " does not support " + action)
				}
			}
			if err := checkGrantPolicy(ctx, tx, *policy); err != nil {
				return err
			}
		}
		if group, ok := strings.CutPrefix(target, "group:"); ok {
			return changeGroupGrant(ctx, tx, res, p.User, group, policy)
		}
		var peer string
		if err := tx.QueryRow(ctx, "SELECT user_id FROM mp_profiles WHERE handle=$1", strings.ToLower(target)).Scan(&peer); err != nil {
			return missingRow(err, "no user "+target)
		}
		if peer == p.User {
			return bad("choose a friend")
		}
		if policy == nil {
			return revokeGrant(ctx, tx, res, peer, p.User, "")
		}
		if err := requireFriend(ctx, tx, p.User, peer, target); err != nil {
			return err
		}
		return policy.apply(ctx, tx, res, peer, p.User, "")
	})
	return nil, err
}

func requireFriend(ctx context.Context, tx pgx.Tx, owner, peer, handle string) error {
	a, b := ownerPair(owner, peer)
	var accepted bool
	err := tx.QueryRow(ctx, "SELECT accepted FROM mp_friends WHERE a=$1 AND b=$2 FOR SHARE", a, b).Scan(&accepted)
	if errors.Is(err, pgx.ErrNoRows) || err == nil && !accepted {
		return &fault{http.StatusForbidden, handle + " is not your friend"}
	}
	return err
}

func revokeGrant(ctx context.Context, tx pgx.Tx, res, peer, actor, source string) error {
	tag, err := tx.Exec(ctx, `DELETE FROM mp_grants WHERE resource=$1 AND grantee=$2 AND source=$3`, res, peer, source)
	if err != nil || tag.RowsAffected() == 0 {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE mp_children c SET status='revoked' WHERE resource=$1 AND sender=$2 AND status='pending' AND NOT `+activeChildGrant, res, peer); err != nil {
		return err
	}
	return recordEvent(ctx, tx, peer, "grant.revoked", actor, res)
}

func (g grantPolicy) apply(ctx context.Context, tx pgx.Tx, res, peer, actor, source string) error {
	if err := g.replace(ctx, tx, res, peer, source); err != nil {
		return err
	}
	// A replacement retains previous debits. Only actions with remaining uses fulfill a request.
	if _, err := tx.Exec(ctx, `UPDATE mp_access_requests SET status='granted'
		WHERE resource=$1 AND requester=$2 AND status='pending' AND actions <@ ARRAY(
		    SELECT action FROM mp_available_actions WHERE resource=$1 AND grantee=$2)`, res, peer); err != nil {
		return err
	}
	return recordEvent(ctx, tx, peer, "grant.received", actor, res)
}

func (g grantPolicy) replace(ctx context.Context, tx pgx.Tx, res, peer, source string) error {
	// A renewed grant is new consent. Settle work that already lost its old grant
	// before writing the replacement, even if neither device has polled recently.
	if err := denyUnavailableForGrant(ctx, tx, res, peer); err != nil {
		return err
	}
	if g.Limits != nil && source == "" {
		// Old aggregate grants predate the per-action usage ledger. If the full
		// execution history belongs to this grant, reconstruct its exact debits.
		var unknown bool
		err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT FROM mp_grants g WHERE resource=$1 AND grantee=$2 AND source='' AND NOT per_action AND used>
            (SELECT COALESCE(sum(l.used),0) FROM mp_grant_limits l WHERE l.resource=$1 AND l.grantee=$2 AND l.source=''))`, res, peer).Scan(&unknown)
		if err != nil {
			return err
		}
		if unknown {
			var consistent bool
			err = tx.QueryRow(ctx, `SELECT g.used=count(c.id) FROM mp_grants g
                LEFT JOIN mp_children c ON c.resource=g.resource AND c.sender=g.grantee AND c.grant_source='' AND c.status IN ('processing','completed','declined','uncertain')
                WHERE g.resource=$1 AND g.grantee=$2 AND g.source='' GROUP BY g.used`, res, peer).Scan(&consistent)
			if err != nil {
				return err
			}
			if !consistent {
				return conflict("legacy use spans multiple grants; revoke and issue a fresh grant to choose new action budgets")
			}
			_, err = tx.Exec(ctx, `INSERT INTO mp_grant_limits(resource,grantee,action,used)
                SELECT resource,sender,action,count(*) FROM mp_children WHERE resource=$1 AND sender=$2 AND grant_source='' AND status IN ('processing','completed','declined','uncertain')
                GROUP BY resource,sender,action ON CONFLICT(resource,grantee,source,action) DO UPDATE SET used=EXCLUDED.used`, res, peer)
			if err != nil {
				return err
			}
		}
	}
	_, err := tx.Exec(ctx, `INSERT INTO mp_grants(resource,grantee,actions,expires_at,max_uses,per_action,source) VALUES($1,$2,$3,$4,$5,$6,$7)
        ON CONFLICT(resource,grantee,source) DO UPDATE SET actions=EXCLUDED.actions,expires_at=EXCLUDED.expires_at,
        max_uses=EXCLUDED.max_uses,per_action=EXCLUDED.per_action`, res, peer, g.Actions, g.ExpiresAt, g.MaxUses, g.Limits != nil, source)
	if err != nil {
		return err
	}
	if g.Limits != nil {
		if _, err = tx.Exec(ctx, `DELETE FROM mp_grant_limits WHERE resource=$1 AND grantee=$2 AND NOT(action=ANY($3)) AND source=$4`, res, peer, g.Actions, source); err != nil {
			return err
		}
		for _, l := range g.Limits {
			if _, err = tx.Exec(ctx, `INSERT INTO mp_grant_limits(resource,grantee,action,expires_at,max_uses,approval,budget_tokens,attribution,source)
                VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT(resource,grantee,source,action) DO UPDATE SET
                expires_at=EXCLUDED.expires_at,max_uses=EXCLUDED.max_uses,approval=EXCLUDED.approval,
                budget_tokens=EXCLUDED.budget_tokens,attribution=EXCLUDED.attribution`,
				res, peer, l.Action, l.ExpiresAt, l.MaxUses, l.Approval, l.BudgetTokens, l.Attribution, source); err != nil {
				return err
			}
		}
		if _, err = tx.Exec(ctx, `UPDATE mp_grants SET used=(SELECT COALESCE(sum(used),0) FROM mp_grant_limits WHERE resource=$1 AND grantee=$2 AND source=$3)
            WHERE resource=$1 AND grantee=$2 AND source=$3`, res, peer, source); err != nil {
			return err
		}
	}
	_, err = tx.Exec(ctx, `UPDATE mp_children c SET status='revoked' WHERE resource=$1 AND sender=$2 AND status='pending' AND NOT(action=ANY($3)) AND NOT `+activeChildGrant, res, peer, g.Actions)
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
func consume(ctx context.Context, tx pgx.Tx, c Child) (string, bool, error) {
	var perAction, spendsUse bool
	var source string
	err := tx.QueryRow(ctx, `SELECT g.per_action,g.source,mp_action_spends_use(a.action) FROM mp_resources r JOIN mp_grants g ON g.resource=r.id
        JOIN mp_selected_grant_actions a ON (a.resource,a.grantee,a.source)=(g.resource,g.grantee,g.source) AND a.action=$5
        WHERE g.grantee=$1 AND r.id=$2 AND r.device=$3 AND r.owner_id=$4 AND $5=ANY(r.actions) AND $5=ANY(g.actions)
        AND a.expires_at>clock_timestamp() AND $6::timestamptz>clock_timestamp() FOR UPDATE OF g`, c.Sender, c.Resource, c.Device, c.Owner, c.Action, c.ExpiresAt).Scan(&perAction, &source, &spendsUse)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	if !spendsUse {
		return source, true, nil
	}
	if perAction {
		tag, err := tx.Exec(ctx, `UPDATE mp_grant_limits SET used=used+1 WHERE resource=$1 AND grantee=$2 AND action=$3 AND source=$5 AND used<max_uses AND expires_at>clock_timestamp() AND $4::timestamptz>clock_timestamp()`, c.Resource, c.Sender, c.Action, c.ExpiresAt, source)
		if err != nil || tag.RowsAffected() == 0 {
			return "", false, err
		}
		_, err = tx.Exec(ctx, `UPDATE mp_grants SET used=used+1 WHERE resource=$1 AND grantee=$2 AND source=$3`, c.Resource, c.Sender, source)
		return source, err == nil, err
	}
	tag, err := tx.Exec(ctx, `UPDATE mp_grants SET used=used+1 WHERE resource=$1 AND grantee=$2 AND source=$4 AND used<max_uses AND expires_at>clock_timestamp() AND $3::timestamptz>clock_timestamp()`, c.Resource, c.Sender, c.ExpiresAt, source)
	if err != nil || tag.RowsAffected() == 0 {
		return "", false, err
	}
	_, err = tx.Exec(ctx, `INSERT INTO mp_grant_limits(resource,grantee,action,used,source) VALUES($1,$2,$3,1,$4)
		ON CONFLICT(resource,grantee,source,action) DO UPDATE SET used=mp_grant_limits.used+1`, c.Resource, c.Sender, c.Action, source)
	return source, err == nil, err
}

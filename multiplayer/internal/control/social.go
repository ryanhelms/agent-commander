package control

import (
	"context"
	"net/http"
	"slices"
	"strings"

	"github.com/jackc/pgx/v5"
)

type User struct {
	User   string `json:"user"`
	Handle string `json:"handle"`
	Online bool   `json:"online"`
	Status string `json:"status,omitempty"`
}

func (s *Service) setProfile(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in struct {
		Handle string `json:"handle"`
	}
	if err := body(r, &in); err != nil {
		return nil, err
	}
	in.Handle = strings.ToLower(in.Handle)
	if !handlePattern.MatchString(in.Handle) {
		return nil, bad("handle must have 2–32 lowercase letters, numbers, underscores or hyphens")
	}
	_, err := s.pool.Exec(ctx, `INSERT INTO mp_profiles(user_id,handle) VALUES($1,$2) ON CONFLICT(user_id) DO UPDATE SET handle=EXCLUDED.handle`, p.User, in.Handle)
	if err != nil {
		return nil, err
	}
	return s.profile(ctx, p, r)
}
func (s *Service) profile(ctx context.Context, p Principal, r *http.Request) (any, error) {
	handle := strings.ToLower(r.PathValue("handle"))
	var v User
	// Exact-handle discovery reveals existence. Presence is limited to the account and accepted peers.
	err := s.pool.QueryRow(ctx, `SELECT p.user_id,p.handle,
	(p.user_id=$1 OR EXISTS (SELECT FROM mp_friends f WHERE f.a=least(p.user_id,$1) AND f.b=greatest(p.user_id,$1) AND f.accepted))
	AND EXISTS (SELECT FROM mp_leases l WHERE l.owner_id=p.user_id AND l.ready AND l.expires_at>now())
	FROM mp_profiles p WHERE ($2='' AND p.user_id=$1) OR ($2<>'' AND p.handle=$2)`, p.User, handle).Scan(&v.User, &v.Handle, &v.Online)
	return v, err
}
func (s *Service) friends(ctx context.Context, p Principal, _ *http.Request) (any, error) {
	rows, err := s.pool.Query(ctx, `SELECT u.user_id,u.handle,CASE WHEN f.accepted THEN 'accepted' WHEN f.requester=$1 THEN 'outgoing' ELSE 'incoming' END,
	f.accepted AND EXISTS (SELECT FROM mp_leases l WHERE l.owner_id=u.user_id AND l.ready AND l.expires_at>now())
	FROM mp_friends f JOIN mp_profiles u ON u.user_id=CASE WHEN f.a=$1 THEN f.b ELSE f.a END
	WHERE $1 IN (f.a,f.b) ORDER BY u.handle`, p.User)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []User{}
	for rows.Next() {
		var v User
		if err = rows.Scan(&v.User, &v.Handle, &v.Status, &v.Online); err != nil {
			return nil, err
		}
		result = append(result, v)
	}
	return map[string]any{"friends": result}, rows.Err()
}
func (s *Service) friendChange(ctx context.Context, p Principal, r *http.Request) (any, error) {
	err := s.write(ctx, func(tx pgx.Tx) error {
		var peer string
		if err := tx.QueryRow(ctx, "SELECT user_id FROM mp_profiles WHERE handle=$1", strings.ToLower(r.PathValue("handle"))).Scan(&peer); err != nil {
			return err
		}
		if peer == p.User {
			return bad("choose another user")
		}
		a, b := ownerPair(peer, p.User)
		switch r.Method {
		case "POST":
			_, err := tx.Exec(ctx, `INSERT INTO mp_friends(a,b,requester) VALUES($1,$2,$3) ON CONFLICT DO NOTHING`, a, b, p.User)
			return err
		case "PUT":
			tag, err := tx.Exec(ctx, `UPDATE mp_friends SET accepted=true WHERE a=$1 AND b=$2 AND (requester<>$3 OR accepted)`, a, b, p.User)
			if err == nil && tag.RowsAffected() == 0 {
				return forbidden()
			}
			return err
		default:
			if _, err := tx.Exec(ctx, `UPDATE mp_children SET status='revoked' WHERE status='pending' AND ((sender=$1 AND owner_id=$2) OR (sender=$2 AND owner_id=$1))`, a, b); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `DELETE FROM mp_grants g USING mp_resources r WHERE g.resource=r.id AND ((g.grantee=$1 AND r.owner_id=$2) OR(g.grantee=$2 AND r.owner_id=$1))`, a, b); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, "DELETE FROM mp_friends WHERE a=$1 AND b=$2", a, b)
			return err
		}
	})
	return nil, err
}

type Resource struct {
	ID      string   `json:"id"`
	Owner   string   `json:"owner"`
	Device  string   `json:"device"`
	Kind    string   `json:"kind"`
	Name    string   `json:"name"`
	Handle  string   `json:"handle"`
	Actions []string `json:"actions"`
}

func (s *Service) putResource(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in struct {
		Kind    string   `json:"kind"`
		Name    string   `json:"name"`
		Actions []string `json:"actions"`
	}
	if err := body(r, &in); err != nil {
		return nil, err
	}
	id := r.PathValue("id")
	if !identifier.MatchString(id) || !validActions(in.Actions) || (in.Kind != "agent" && in.Kind != "repo") || strings.TrimSpace(in.Name) == "" || len(in.Name) > 128 {
		return nil, bad("provide resource id, kind, name and unique actions")
	}
	slices.Sort(in.Actions)
	err := s.write(ctx, func(tx pgx.Tx) error {
		if err := s.requireDevice(ctx, tx, p); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `INSERT INTO mp_resources(id,owner_id,device,kind,name,actions) VALUES($1,$2,$3,$4,$5,$6)
		ON CONFLICT(id) DO UPDATE SET name=EXCLUDED.name,actions=EXCLUDED.actions
		WHERE mp_resources.owner_id=EXCLUDED.owner_id AND mp_resources.device=EXCLUDED.device AND mp_resources.kind=EXCLUDED.kind`, id, p.User, p.Device, in.Kind, in.Name, in.Actions)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return forbidden()
		}
		// Removing an advertised action permanently removes it from existing grants.
		_, err = tx.Exec(ctx, `UPDATE mp_grants SET actions=ARRAY(SELECT unnest(actions) INTERSECT SELECT unnest($2::text[])) WHERE resource=$1`, id, in.Actions)
		if err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `DELETE FROM mp_grant_limits l USING mp_grants g
            WHERE (l.resource,l.grantee)=(g.resource,g.grantee) AND g.per_action AND g.resource=$1 AND NOT(l.action=ANY($2))`, id, in.Actions); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE mp_children SET status='revoked' WHERE resource=$1 AND status='pending' AND NOT(action=ANY($2))`, id, in.Actions)
		return err
	})
	return map[string]any{"id": id}, err
}
func (s *Service) resources(ctx context.Context, p Principal, _ *http.Request) (any, error) {
	rows, err := s.pool.Query(ctx, `SELECT r.id,r.owner_id,r.device,r.kind,r.name,p.handle,
	CASE WHEN r.owner_id=$1 THEN r.actions ELSE access.actions END FROM mp_resources r
    JOIN mp_profiles p ON p.user_id=r.owner_id
    LEFT JOIN LATERAL (SELECT array_agg(action ORDER BY action) AS actions FROM mp_effective_actions
        WHERE resource=r.id AND grantee=$1 AND action=ANY(r.actions) AND expires_at>now() AND used<max_uses) access ON true
    WHERE r.owner_id=$1 OR (cardinality(access.actions)>0 AND EXISTS
    (SELECT FROM mp_friends WHERE a=least($1,r.owner_id) AND b=greatest($1,r.owner_id) AND accepted))
    ORDER BY p.handle,r.id`, p.User)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	results := []Resource{}
	for rows.Next() {
		var v Resource
		if err = rows.Scan(&v.ID, &v.Owner, &v.Device, &v.Kind, &v.Name, &v.Handle, &v.Actions); err != nil {
			return nil, err
		}
		results = append(results, v)
	}
	return map[string]any{"resources": results}, rows.Err()
}

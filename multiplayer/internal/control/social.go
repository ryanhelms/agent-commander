package control

import (
	"context"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

type User struct {
	User          string     `json:"user"`
	Handle        string     `json:"handle"`
	Online        bool       `json:"online"`
	Status        string     `json:"status,omitempty"`
	DisplayName   string     `json:"displayName"`
	StatusMessage string     `json:"statusMessage"`
	Presence      string     `json:"presence"`
	LastSeen      *time.Time `json:"lastSeen,omitempty"`
	HasAvatar     bool       `json:"hasAvatar"`
	ContactKey    string     `json:"contactKey,omitempty"`
}

func (s *Service) setProfile(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in struct {
		Handle        *string `json:"handle"`
		DisplayName   *string `json:"displayName"`
		StatusMessage *string `json:"statusMessage"`
		Presence      *string `json:"presence"`
		Avatar        *string `json:"avatar"`
	}
	if err := body(r, &in); err != nil {
		return nil, err
	}
	if in.Handle != nil {
		*in.Handle = strings.ToLower(*in.Handle)
		if !handlePattern.MatchString(*in.Handle) {
			return nil, bad("handle must have 2–32 lowercase letters, numbers, underscores or hyphens")
		}
	}
	if in.Presence != nil {
		switch *in.Presence {
		case "online", "away", "busy", "dnd":
		default:
			return nil, bad("invalid presence")
		}
	}
	var image profileAvatar
	if in.Avatar != nil {
		var err error
		image.contentType, image.data, err = decodeAvatar(*in.Avatar)
		if err != nil {
			return nil, err
		}
	}
	_, err := s.pool.Exec(ctx, `INSERT INTO mp_profiles(user_id,handle,display_name,status_message,presence,avatar_type,avatar)
		VALUES ($1,$2,coalesce($3,''),coalesce($4,''),coalesce($5,'online'),$6,$7)
		ON CONFLICT(user_id) DO UPDATE SET
		  handle=coalesce($2,mp_profiles.handle),display_name=coalesce($3,mp_profiles.display_name),
		  status_message=coalesce($4,mp_profiles.status_message),presence=coalesce($5,mp_profiles.presence),
		  avatar_type=CASE WHEN $8 THEN excluded.avatar_type ELSE mp_profiles.avatar_type END,
		  avatar=CASE WHEN $8 THEN excluded.avatar ELSE mp_profiles.avatar END`,
		p.User, in.Handle, in.DisplayName, in.StatusMessage, in.Presence, image.contentType, image.data, in.Avatar != nil)
	if err != nil {
		return nil, err
	}
	return s.profile(ctx, p, r)
}

type profileAvatar struct {
	contentType string
	data        []byte
}

func (s *Service) avatar(ctx context.Context, _ Principal, r *http.Request) (any, error) {
	var image profileAvatar
	err := s.pool.QueryRow(ctx, `SELECT avatar_type,avatar FROM mp_profiles WHERE handle=$1 AND avatar IS NOT NULL`,
		strings.ToLower(r.PathValue("handle"))).Scan(&image.contentType, &image.data)
	return image, err
}

// Snapshot the relationship, profile and all of the member's device leases in
// one query. Only the account and accepted friends see presence and contact keys.
const socialUsers = `SELECT u.user_id,coalesce(u.handle,''),coalesce(u.display_name,''),coalesce(u.status_message,''),
	coalesce(live.online,false),CASE WHEN live.online THEN coalesce(u.presence,'online') ELSE 'offline' END,
	CASE WHEN NOT coalesce(live.online,false) THEN live.last_seen END,u.has_avatar,
	CASE WHEN u.user_id=$1 OR f.accepted THEN coalesce(u.contact_key,'') ELSE '' END,
	CASE WHEN f.accepted THEN 'accepted' WHEN f.requester=$1 THEN 'outgoing' WHEN f.requester IS NOT NULL THEN 'incoming' ELSE '' END
	FROM (SELECT user_id,handle,display_name,status_message,presence,avatar IS NOT NULL AS has_avatar,contact_key
	      FROM mp_members FULL JOIN mp_profiles USING(user_id)) u
	LEFT JOIN mp_friends f ON f.a=least(u.user_id,$1) AND f.b=greatest(u.user_id,$1)
	LEFT JOIN LATERAL (
	    SELECT bool_or(ready AND expires_at>now()) AS online,
	           max(greatest(last_seen, CASE WHEN expires_at<=now() THEN expires_at END)) AS last_seen
	    FROM mp_leases WHERE owner_id=u.user_id AND (u.user_id=$1 OR f.accepted)
	) live ON true `

func scanUser(row pgx.Row) (User, error) {
	var u User
	err := row.Scan(&u.User, &u.Handle, &u.DisplayName, &u.StatusMessage, &u.Online, &u.Presence, &u.LastSeen, &u.HasAvatar, &u.ContactKey, &u.Status)
	return u, err
}

func (s *Service) profile(ctx context.Context, p Principal, r *http.Request) (any, error) {
	handle := strings.ToLower(r.PathValue("handle"))
	return scanUser(s.pool.QueryRow(ctx, socialUsers+`WHERE ($2='' AND u.user_id=$1) OR ($2<>'' AND u.handle=$2)`, p.User, handle))
}

func (s *Service) friends(ctx context.Context, p Principal, _ *http.Request) (any, error) {
	rows, err := s.pool.Query(ctx, socialUsers+`WHERE f.requester IS NOT NULL ORDER BY u.handle`, p.User)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []User{}
	for rows.Next() {
		u, err := scanUser(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, u)
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
			tag, err := tx.Exec(ctx, `INSERT INTO mp_friends(a,b,requester) VALUES($1,$2,$3) ON CONFLICT DO NOTHING`, a, b, p.User)
			if err != nil || tag.RowsAffected() == 0 {
				return err
			}
			return recordEvent(ctx, tx, peer, "friend.request", p.User, "")
		case "PUT":
			var requester string
			var accepted bool
			err := tx.QueryRow(ctx, "SELECT requester,accepted FROM mp_friends WHERE a=$1 AND b=$2 FOR UPDATE", a, b).Scan(&requester, &accepted)
			if err == pgx.ErrNoRows || (err == nil && !accepted && requester == p.User) {
				return forbidden()
			}
			if err != nil || accepted {
				return err
			}
			if _, err := tx.Exec(ctx, "UPDATE mp_friends SET accepted=true WHERE a=$1 AND b=$2", a, b); err != nil {
				return err
			}
			return recordEvent(ctx, tx, peer, "friend.accepted", p.User, "")
		default:
			if err := removeFriendFromGroups(ctx, tx, p.User, peer); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `DELETE FROM mp_grants g USING mp_resources r WHERE g.resource=r.id AND g.source=''
				AND ((g.grantee=$1 AND r.owner_id=$2) OR (g.grantee=$2 AND r.owner_id=$1))`, a, b); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `UPDATE mp_children c SET status='revoked' WHERE status='pending'
				AND ((sender=$1 AND owner_id=$2) OR (sender=$2 AND owner_id=$1)) AND NOT `+activeChildGrant, a, b); err != nil {
				return err
			}
			tag, err := tx.Exec(ctx, "DELETE FROM mp_friends WHERE a=$1 AND b=$2", a, b)
			if err != nil || tag.RowsAffected() == 0 {
				return err
			}
			return recordEvent(ctx, tx, peer, "friend.removed", p.User, "")
		}
	})
	return nil, err
}

type Capabilities struct {
	Harness      string   `json:"harness,omitempty"`
	Model        string   `json:"model,omitempty"`
	Slots        *int     `json:"slots,omitempty"`
	Tools        []string `json:"tools,omitzero"`
	Environments []string `json:"environments,omitzero"`
}

type Resource struct {
	ID           string        `json:"id"`
	Owner        string        `json:"owner"`
	Device       string        `json:"device"`
	Kind         string        `json:"kind"`
	Name         string        `json:"name"`
	Handle       string        `json:"handle"`
	Actions      []string      `json:"actions"`
	Capabilities *Capabilities `json:"capabilities,omitempty"`
	Listed       bool          `json:"listed"`
	Endorsements []Endorsement `json:"endorsements"`
}

// In the friends' directory, Actions lists everything the owner offers on the resource.
type DirectoryResource struct {
	Resource
	GrantedActions []string `json:"grantedActions"`
}

func (s *Service) putResource(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in struct {
		Kind         string        `json:"kind"`
		Name         string        `json:"name"`
		Actions      []string      `json:"actions"`
		Capabilities *Capabilities `json:"capabilities"`
		Listed       *bool         `json:"listed"`
	}
	if err := body(r, &in); err != nil {
		return nil, err
	}
	id := r.PathValue("id")
	if !identifier.MatchString(id) || !validActions(in.Actions) || (in.Kind != "agent" && in.Kind != "repo" && in.Kind != "host") || strings.TrimSpace(in.Name) == "" || len(in.Name) > 128 {
		return nil, bad("provide resource id, kind, name and unique actions")
	}
	if c := in.Capabilities; c != nil {
		if c.Harness != "" && c.Harness != "claude" && c.Harness != "codex" && c.Harness != "other" {
			return nil, bad("harness must be claude, codex or other")
		}
		if c.Slots != nil && *c.Slots < 0 {
			return nil, bad("slots must be nonnegative")
		}
	}
	slices.Sort(in.Actions)
	err := s.write(ctx, func(tx pgx.Tx) error {
		if err := s.requireDevice(ctx, tx, p); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `INSERT INTO mp_resources(id,owner_id,device,kind,name,actions,capabilities,listed) VALUES($1,$2,$3,$4,$5,$6,$7,coalesce($8,false))
		ON CONFLICT(id) DO UPDATE SET name=EXCLUDED.name,actions=EXCLUDED.actions,capabilities=EXCLUDED.capabilities,listed=coalesce($8,mp_resources.listed)
		WHERE mp_resources.owner_id=EXCLUDED.owner_id AND mp_resources.device=EXCLUDED.device AND mp_resources.kind=EXCLUDED.kind`, id, p.User, p.Device, in.Kind, in.Name, in.Actions, in.Capabilities, in.Listed)
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
		if _, err = tx.Exec(ctx, `UPDATE mp_group_grants SET actions=ARRAY(SELECT unnest(actions) INTERSECT SELECT unnest($2::text[])) WHERE resource=$1`, id, in.Actions); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `DELETE FROM mp_grant_limits l USING mp_grants g
            WHERE (l.resource,l.grantee,l.source)=(g.resource,g.grantee,g.source) AND g.per_action AND g.resource=$1 AND NOT(l.action=ANY($2))`, id, in.Actions); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE mp_children SET status='revoked' WHERE resource=$1 AND status='pending' AND NOT(action=ANY($2))`, id, in.Actions)
		return err
	})
	out := map[string]any{"id": id}
	if in.Capabilities != nil {
		out["capabilities"] = in.Capabilities
	}
	return out, err
}
func (s *Service) resources(ctx context.Context, p Principal, _ *http.Request) (any, error) {
	rows, err := s.pool.Query(ctx, `SELECT r.id,r.owner_id,r.device,r.kind,r.name,coalesce(p.handle,''),
	r.actions,r.capabilities,r.listed,`+resourceEndorsements+`,coalesce(access.actions,'{}'),coalesce(f.accepted,false) FROM mp_resources r
    JOIN mp_profiles p ON p.user_id=r.owner_id
    LEFT JOIN mp_friends f ON f.a=least($1,r.owner_id) AND f.b=greatest($1,r.owner_id)
    LEFT JOIN LATERAL (SELECT array_agg(action ORDER BY action) AS actions FROM mp_effective_actions
        WHERE resource=r.id AND grantee=$1 AND action=ANY(r.actions) AND expires_at>now() AND used<max_uses) access ON true
    WHERE r.owner_id=$1 OR (cardinality(r.actions)>0 AND f.accepted) OR cardinality(access.actions)>0
    ORDER BY p.handle,r.id`, p.User)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	results := []Resource{}
	directory := []DirectoryResource{}
	for rows.Next() {
		var v DirectoryResource
		var friend bool
		if err = rows.Scan(&v.ID, &v.Owner, &v.Device, &v.Kind, &v.Name, &v.Handle, &v.Actions, &v.Capabilities, &v.Listed, &v.Endorsements, &v.GrantedActions, &friend); err != nil {
			return nil, err
		}
		if v.Owner != p.User {
			if friend {
				directory = append(directory, v)
			}
			if len(v.GrantedActions) == 0 {
				continue
			}
			// Existing coordinator clients discover only executable actions in resources.
			v.Actions = v.GrantedActions
		}
		results = append(results, v.Resource)
	}
	return map[string]any{"resources": results, "directory": directory}, rows.Err()
}

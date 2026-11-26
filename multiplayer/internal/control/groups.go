package control

import (
	"context"
	_ "embed"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

//go:embed groups.sql
var groupsSchema string

type Group struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Owner       string   `json:"owner"`
	OwnerHandle string   `json:"ownerHandle"`
	Members     []string `json:"members"`
}

func (s *Service) groupRoutes(routes map[string]endpoint) {
	routes["GET /v1/groups"] = s.groups
	routes["POST /v1/groups"] = s.createGroup
	routes["DELETE /v1/groups/{id}"] = s.deleteGroup
	routes["PUT /v1/groups/{id}/members/{handle}"] = s.changeGroupMember
	routes["DELETE /v1/groups/{id}/members/{handle}"] = s.changeGroupMember
}

func (s *Service) groups(ctx context.Context, p Principal, _ *http.Request) (any, error) {
	rows, err := s.pool.Query(ctx, `SELECT g.id,g.name,g.owner_id,coalesce(owner.handle,''),
		ARRAY(SELECT coalesce(u.handle,'') FROM mp_group_members m JOIN mp_profiles u ON u.user_id=m.user_id
		      WHERE m.group_id=g.id ORDER BY u.handle)
		FROM mp_groups g JOIN mp_profiles owner ON owner.user_id=g.owner_id
		JOIN mp_group_members mine ON mine.group_id=g.id AND mine.user_id=$1 ORDER BY g.name,g.id`, p.User)
	if err != nil {
		return nil, err
	}
	groups, err := pgx.CollectRows(rows, pgx.RowToStructByPos[Group])
	return map[string]any{"groups": groups}, err
}

func (s *Service) createGroup(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in struct{ Name string }
	if err := body(r, &in); err != nil {
		return nil, err
	}
	name := strings.TrimSpace(in.Name)
	if name == "" || len(name) > 128 {
		return nil, bad("provide a group name of 1–128 bytes")
	}
	id := secret()
	err := s.write(ctx, func(tx pgx.Tx) error {
		if err := s.requireDevice(ctx, tx, p); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO mp_profiles(user_id) VALUES($1) ON CONFLICT DO NOTHING`, p.User); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO mp_groups(id,owner_id,name) VALUES($1,$2,$3)`, id, p.User, name); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO mp_group_members(group_id,user_id) VALUES($1,$2)`, id, p.User); err != nil {
			return err
		}
		return recordEvent(ctx, tx, p.User, "group.added", p.User, id)
	})
	return map[string]string{"id": id}, err
}

func lockOwnedGroup(ctx context.Context, tx pgx.Tx, id, user string) error {
	var owner string
	if err := tx.QueryRow(ctx, "SELECT owner_id FROM mp_groups WHERE id=$1 FOR UPDATE", id).Scan(&owner); err != nil {
		return missingRow(err, "no group "+id)
	}
	if owner != user {
		return &fault{http.StatusForbidden, "only the owner can change group " + id}
	}
	return nil
}

func (s *Service) changeGroupMember(ctx context.Context, p Principal, r *http.Request) (any, error) {
	id, handle := r.PathValue("id"), strings.ToLower(r.PathValue("handle"))
	err := s.write(ctx, func(tx pgx.Tx) error {
		if err := s.requireDevice(ctx, tx, p); err != nil {
			return err
		}
		if err := lockOwnedGroup(ctx, tx, id, p.User); err != nil {
			return err
		}
		var peer string
		if err := tx.QueryRow(ctx, "SELECT user_id FROM mp_profiles WHERE handle=$1", handle).Scan(&peer); err != nil {
			if r.Method == "DELETE" {
				return missingRow(err, handle+" is not a member of group "+id)
			}
			return missingRow(err, handle+" is not your friend")
		}
		if peer == p.User {
			return bad("the group owner is a permanent member")
		}
		if r.Method == "DELETE" {
			return removeGroupMember(ctx, tx, id, peer, p.User)
		}
		if err := requireFriend(ctx, tx, p.User, peer, handle); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `INSERT INTO mp_group_members(group_id,user_id) VALUES($1,$2) ON CONFLICT DO NOTHING`, id, peer)
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		if err := recordEvent(ctx, tx, peer, "group.added", p.User, id); err != nil {
			return err
		}
		return expandGroupForMember(ctx, tx, id, peer)
	})
	return nil, err
}

func expandGroupForMember(ctx context.Context, tx pgx.Tx, group, peer string) error {
	type template struct {
		Owner    string
		Resource string
		Actions  []string
		Policy   grantPolicy
	}
	rows, err := tx.Query(ctx, `SELECT r.owner_id,g.resource,g.actions,g.policy FROM mp_group_grants g
		JOIN mp_resources r ON r.id=g.resource WHERE g.group_id=$1 AND r.owner_id<>$2
		AND cardinality(g.actions)>0 ORDER BY g.resource`, group, peer)
	if err != nil {
		return err
	}
	policies, err := pgx.CollectRows(rows, pgx.RowToStructByPos[template])
	if err != nil {
		return err
	}
	for _, item := range policies {
		// Capability withdrawals are permanent even when the device later
		// advertises the same capability again.
		g := item.Policy
		g.Actions = item.Actions
		if g.Limits != nil {
			g.Limits = slices.DeleteFunc(g.Limits, func(l Limit) bool { return !slices.Contains(g.Actions, l.Action) })
			g.MaxUses, g.ExpiresAt = 0, time.Time{}
			for _, l := range g.Limits {
				g.MaxUses += l.MaxUses
				if l.ExpiresAt.After(g.ExpiresAt) {
					g.ExpiresAt = l.ExpiresAt
				}
			}
		}
		if !g.ExpiresAt.After(time.Now()) {
			continue
		}
		if err := checkGrantPolicy(ctx, tx, g); err != nil {
			// A tighter admin cap applies to new grants. Membership and
			// other resources can still be granted independently.
			var limit *fault
			if errors.As(err, &limit) && limit.code == http.StatusBadRequest {
				continue
			}
			return err
		}
		if err := g.apply(ctx, tx, item.Resource, peer, item.Owner, group); err != nil {
			return err
		}
	}
	return nil
}

func removeGroupMember(ctx context.Context, tx pgx.Tx, group, peer, actor string) error {
	tag, err := tx.Exec(ctx, `DELETE FROM mp_group_members WHERE group_id=$1 AND user_id=$2`, group, peer)
	if err != nil || tag.RowsAffected() == 0 {
		return err
	}
	// Withdrawal covers both sides of a member's participation: what they
	// received from other members and resources they offered to the group.
	if _, err := tx.Exec(ctx, `DELETE FROM mp_group_grants g USING mp_resources r
		WHERE g.group_id=$1 AND r.id=g.resource AND r.owner_id=$2`, group, peer); err != nil {
		return err
	}
	rows, err := tx.Query(ctx, `SELECT g.resource,g.grantee FROM mp_grants g JOIN mp_resources r ON r.id=g.resource
		WHERE g.source=$1 AND (g.grantee=$2 OR r.owner_id=$2) ORDER BY g.resource,g.grantee`, group, peer)
	if err != nil {
		return err
	}
	type recipient struct{ Resource, Grantee string }
	grants, err := pgx.CollectRows(rows, pgx.RowToStructByPos[recipient])
	if err != nil {
		return err
	}
	for _, g := range grants {
		if err := revokeGrant(ctx, tx, g.Resource, g.Grantee, actor, group); err != nil {
			return err
		}
	}
	return recordEvent(ctx, tx, peer, "group.removed", actor, group)
}

func (s *Service) deleteGroup(ctx context.Context, p Principal, r *http.Request) (any, error) {
	id := r.PathValue("id")
	err := s.write(ctx, func(tx pgx.Tx) error {
		if err := s.requireDevice(ctx, tx, p); err != nil {
			return err
		}
		if err := lockOwnedGroup(ctx, tx, id, p.User); err != nil {
			return err
		}
		members, err := otherGroupMembers(ctx, tx, id, p.User)
		if err != nil {
			return err
		}
		for _, peer := range members {
			if err := removeGroupMember(ctx, tx, id, peer, p.User); err != nil {
				return err
			}
		}
		if _, err = tx.Exec(ctx, "DELETE FROM mp_groups WHERE id=$1", id); err != nil {
			return err
		}
		return recordEvent(ctx, tx, p.User, "group.removed", p.User, id)
	})
	return nil, err
}

func otherGroupMembers(ctx context.Context, tx pgx.Tx, group, owner string) ([]string, error) {
	rows, err := tx.Query(ctx, `SELECT user_id FROM mp_group_members WHERE group_id=$1 AND user_id<>$2 ORDER BY user_id`, group, owner)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

func changeGroupGrant(ctx context.Context, tx pgx.Tx, res, owner, group string, policy *grantPolicy) error {
	var member string
	if err := tx.QueryRow(ctx, `SELECT m.user_id FROM mp_groups g JOIN mp_group_members m ON m.group_id=g.id
		WHERE g.id=$1 AND m.user_id=$2 FOR UPDATE OF g FOR SHARE OF m`, group, owner).Scan(&member); err != nil {
		return missingRow(err, "you do not belong to group "+group)
	}
	if policy == nil {
		if _, err := tx.Exec(ctx, `DELETE FROM mp_group_grants WHERE group_id=$1 AND resource=$2`, group, res); err != nil {
			return err
		}
	} else if _, err := tx.Exec(ctx, `INSERT INTO mp_group_grants(group_id,resource,actions,policy) VALUES($1,$2,$3,$4)
		ON CONFLICT(group_id,resource) DO UPDATE SET actions=excluded.actions,policy=excluded.policy`, group, res, policy.Actions, policy); err != nil {
		return err
	}
	members, err := otherGroupMembers(ctx, tx, group, owner)
	if err != nil {
		return err
	}
	for _, peer := range members {
		if policy == nil {
			err = revokeGrant(ctx, tx, res, peer, owner, group)
		} else {
			err = policy.apply(ctx, tx, res, peer, owner, group)
		}
		if err != nil {
			return err
		}
	}
	return nil
}

// Ending a friendship also ends membership in groups owned by that friend.
func removeFriendFromGroups(ctx context.Context, tx pgx.Tx, actor, peer string) error {
	rows, err := tx.Query(ctx, `SELECT m.group_id,m.user_id FROM mp_group_members m JOIN mp_groups g ON g.id=m.group_id
		WHERE (g.owner_id=$1 AND m.user_id=$2) OR (g.owner_id=$2 AND m.user_id=$1) ORDER BY g.id`, actor, peer)
	if err != nil {
		return err
	}
	type member struct{ Group, User string }
	members, err := pgx.CollectRows(rows, pgx.RowToStructByPos[member])
	if err != nil {
		return err
	}
	for _, m := range members {
		if err := removeGroupMember(ctx, tx, m.Group, m.User, actor); err != nil {
			return err
		}
	}
	return nil
}

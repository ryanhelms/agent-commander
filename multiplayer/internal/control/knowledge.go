package control

import (
	"context"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

type knowledgeItem struct {
	ID         string    `json:"id"`
	Owner      string    `json:"owner"`
	Kind       string    `json:"kind"`
	Name       string    `json:"name"`
	Content    string    `json:"content"`
	Visibility string    `json:"visibility"`
	Version    int       `json:"version"`
	CreatedAt  time.Time `json:"createdAt"`
}

// Store the stable user ID for a friend. A reassigned handle cannot inherit
// access. Check group membership, friendship and the current policy at read time.
const visibleKnowledge = `WITH visible AS (
	SELECT k.id,k.owner_id,v.kind,v.name,v.content,
		CASE v.scope WHEN 'friend' THEN 'friend:'||coalesce(p.handle,v.target)
			WHEN 'group' THEN 'group:'||v.target ELSE v.scope END AS visibility,
		v.version,v.created_at,k.version AS latest
	FROM mp_knowledge k JOIN mp_knowledge_versions v ON v.item=k.id
	CROSS JOIN mp_policy policy
	LEFT JOIN mp_profiles p ON v.scope='friend' AND p.user_id=v.target
	WHERE (($2='' AND v.version=k.version) OR k.id=$2) AND (k.owner_id=$1 OR (
		array_position(ARRAY['private','friend','group','server'],v.scope) <=
		array_position(ARRAY['private','friend','group','server'],policy.knowledge_widest) AND (
			v.scope='server' OR
			(v.scope='friend' AND v.target=$1 AND EXISTS(SELECT FROM mp_friends
				WHERE a=least(k.owner_id,$1) AND b=greatest(k.owner_id,$1) AND accepted)) OR
			(v.scope='group' AND EXISTS(SELECT FROM mp_group_members WHERE group_id=v.target AND user_id=$1)
				AND EXISTS(SELECT FROM mp_group_members WHERE group_id=v.target AND user_id=k.owner_id))
		)
	))
)`

func (s *Service) readKnowledge(ctx context.Context, p Principal, r *http.Request) (any, error) {
	id := r.PathValue("id")
	rows, err := s.pool.Query(ctx, visibleKnowledge+`
		SELECT id,owner_id,kind,name,content,visibility,version,created_at FROM visible v
		WHERE ($2='' AND version=latest) OR (id=$2 AND EXISTS(
			SELECT FROM visible current WHERE current.id=v.id AND current.version=current.latest))
		ORDER BY created_at DESC,version DESC,id`, p.User, id)
	if err != nil {
		return nil, err
	}
	items, err := pgx.CollectRows(rows, pgx.RowToStructByPos[knowledgeItem])
	if id != "" {
		if err == nil && len(items) == 0 {
			return nil, missing()
		}
		return map[string]any{"versions": items}, err
	}
	return map[string]any{"items": items}, err
}

type knowledgeInput struct {
	Kind       *string `json:"kind"`
	Name       *string `json:"name"`
	Content    *string `json:"content"`
	Visibility *string `json:"visibility"`
}

func knowledgeScopeRank(scope string) int {
	return slices.Index([]string{"private", "friend", "group", "server"}, scope)
}

func knowledgeAudience(ctx context.Context, tx pgx.Tx, owner, visibility string) (string, string, error) {
	scope, target, hasTarget := strings.Cut(visibility, ":")
	switch scope {
	case "private", "server":
		if !hasTarget {
			return scope, "", nil
		}
	case "friend":
		if !handlePattern.MatchString(strings.ToLower(target)) {
			break
		}
		var user string
		err := tx.QueryRow(ctx, `SELECT p.user_id FROM mp_profiles p JOIN mp_friends f
			ON f.a=least(p.user_id,$1) AND f.b=greatest(p.user_id,$1)
			WHERE p.handle=$2 AND f.accepted`, owner, strings.ToLower(target)).Scan(&user)
		if err == pgx.ErrNoRows {
			return "", "", forbidden()
		}
		return scope, user, err
	case "group":
		if !identifier.MatchString(target) {
			break
		}
		var member bool
		err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT FROM mp_group_members WHERE user_id=$1 AND group_id=$2)`, owner, target).Scan(&member)
		if err == nil && !member {
			return "", "", forbidden()
		}
		return scope, target, err
	}
	return "", "", bad("use private, friend:<handle>, group:<id> or server")
}

func (s *Service) writeKnowledge(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in knowledgeInput
	if err := body(r, &in); err != nil {
		return nil, err
	}
	id := r.PathValue("id")
	create := r.Method == "POST"
	if create {
		id = secret()
	}
	var saved knowledgeItem
	err := s.write(ctx, func(tx pgx.Tx) error {
		if err := s.requireDevice(ctx, tx, p); err != nil {
			return err
		}
		var defaultScope, widest string
		if err := tx.QueryRow(ctx, "SELECT knowledge_default,knowledge_widest FROM mp_policy").Scan(&defaultScope, &widest); err != nil {
			return err
		}
		v := knowledgeItem{ID: id, Owner: p.User, Visibility: defaultScope}
		if !create {
			err := tx.QueryRow(ctx, `SELECT v.kind,v.name,v.content,
				CASE v.scope WHEN 'friend' THEN 'friend:'||coalesce(p.handle,'')
				WHEN 'group' THEN 'group:'||v.target ELSE v.scope END,k.version
				FROM mp_knowledge k JOIN mp_knowledge_versions v ON (v.item,v.version)=(k.id,k.version)
				LEFT JOIN mp_profiles p ON v.scope='friend' AND p.user_id=v.target
				WHERE k.id=$1 AND k.owner_id=$2 FOR UPDATE OF k`, id, p.User).Scan(&v.Kind, &v.Name, &v.Content, &v.Visibility, &v.Version)
			if err != nil {
				return err
			}
		}
		if in.Kind != nil {
			v.Kind = *in.Kind
		}
		if in.Name != nil {
			v.Name = strings.TrimSpace(*in.Name)
		}
		if in.Content != nil {
			v.Content = *in.Content
		}
		if in.Visibility != nil {
			v.Visibility = *in.Visibility
		}
		if !slices.Contains([]string{"prompt", "skill", "instructions", "mcp", "summary"}, v.Kind) || v.Name == "" || len(v.Name) > 256 || strings.TrimSpace(v.Content) == "" {
			return bad("provide a knowledge kind, name and content")
		}
		scope, target, err := knowledgeAudience(ctx, tx, p.User, v.Visibility)
		if err != nil {
			return err
		}
		if knowledgeScopeRank(scope) > knowledgeScopeRank(widest) {
			return forbidden()
		}
		v.Version++
		if create {
			_, err = tx.Exec(ctx, `INSERT INTO mp_knowledge(id,owner_id,version) VALUES($1,$2,$3)`, id, p.User, v.Version)
		} else {
			_, err = tx.Exec(ctx, `UPDATE mp_knowledge SET version=$2 WHERE id=$1`, id, v.Version)
		}
		if err != nil {
			return err
		}
		err = tx.QueryRow(ctx, `INSERT INTO mp_knowledge_versions(item,version,kind,name,content,scope,target)
			VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING created_at`, id, v.Version, v.Kind, v.Name, v.Content, scope, target).Scan(&v.CreatedAt)
		saved = v
		return err
	})
	return saved, err
}

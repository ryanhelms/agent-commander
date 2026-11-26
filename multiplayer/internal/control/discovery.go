package control

import (
	"context"
	_ "embed"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5"
)

//go:embed sharing.sql
var sharingSchema string

func (s *Service) sharingRoutes(routes map[string]endpoint) {
	routes["GET /v1/knowledge"] = s.readKnowledge
	routes["POST /v1/knowledge"] = s.writeKnowledge
	routes["PUT /v1/knowledge/{id}"] = s.writeKnowledge
	routes["GET /v1/knowledge/{id}/versions"] = s.readKnowledge
	routes["POST /v1/outcomes"] = s.reportOutcome
	routes["GET /v1/reputation/{resource}"] = s.reputation
	routes["POST /v1/endorsements"] = s.endorse
	routes["GET /v1/directory"] = s.directory
}

type Endorsement struct {
	Handle string `json:"handle"`
	Skill  string `json:"skill"`
}

const resourceEndorsements = `coalesce((SELECT jsonb_agg(jsonb_build_object('handle',coalesce(p.handle,''),'skill',e.skill)
    ORDER BY p.handle,e.skill) FROM mp_endorsements e JOIN mp_profiles p ON p.user_id=e.endorser
    WHERE e.resource=r.id),'[]'::jsonb)`

type directoryHit struct {
	ID           string        `json:"id"`
	Handle       string        `json:"handle"`
	Name         string        `json:"name"`
	Kind         string        `json:"kind"`
	Actions      []string      `json:"actions"`
	Capabilities *Capabilities `json:"capabilities,omitempty"`
	Endorsements []Endorsement `json:"endorsements"`
}

func (s *Service) directory(ctx context.Context, _ Principal, r *http.Request) (any, error) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	var result struct {
		Handles   []string       `json:"handles"`
		Resources []directoryHit `json:"resources"`
	}
	// Keep opt-in, the directory switch and both sets of matches in one snapshot.
	err := pgx.BeginTxFunc(ctx, s.pool, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		var enabled bool
		if err := tx.QueryRow(ctx, "SELECT directory FROM mp_policy").Scan(&enabled); err != nil {
			return err
		}
		if !enabled {
			return forbidden()
		}
		if err := tx.QueryRow(ctx, `SELECT ARRAY(SELECT handle FROM mp_profiles p
			WHERE handle IS NOT NULL AND strpos(lower(handle),lower($1))>0
			AND NOT EXISTS(SELECT FROM mp_members m WHERE m.user_id=p.user_id AND m.suspended)
			AND ($1<>'' OR EXISTS(SELECT FROM mp_resources r WHERE r.owner_id=p.user_id AND r.listed AND cardinality(r.actions)>0))
			ORDER BY handle)`, q).Scan(&result.Handles); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT r.id,coalesce(p.handle,''),r.name,r.kind,r.actions,r.capabilities,`+resourceEndorsements+`
			FROM mp_resources r JOIN mp_profiles p ON p.user_id=r.owner_id
			WHERE r.listed AND cardinality(r.actions)>0
			AND NOT EXISTS(SELECT FROM mp_members m WHERE m.user_id=p.user_id AND m.suspended)
			AND (
				strpos(lower(r.name),lower($1))>0 OR strpos(lower(p.handle),lower($1))>0 OR
				EXISTS(SELECT FROM unnest(r.actions) a WHERE strpos(lower(a),lower($1))>0) OR
				EXISTS(SELECT FROM jsonb_path_query(r.capabilities,'$.** ? (@.type() == "string")') AS c(val)
					WHERE strpos(lower(c.val #>> '{}'),lower($1))>0))
			ORDER BY p.handle,r.name,r.id`, q)
		if err != nil {
			return err
		}
		result.Resources, err = pgx.CollectRows(rows, pgx.RowToStructByPos[directoryHit])
		return err
	})
	return result, err
}

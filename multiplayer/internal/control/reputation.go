package control

import (
	"context"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5"
)

type reputationSummary struct {
	Resource      string   `json:"resource"`
	Completed     int64    `json:"completed"`
	Accepted      int64    `json:"accepted"`
	Rejected      int64    `json:"rejected"`
	MedianSeconds *float64 `json:"medianSeconds"`
}

func (s *Service) reputation(ctx context.Context, p Principal, r *http.Request) (any, error) {
	out := reputationSummary{Resource: r.PathValue("resource")}
	var visible bool
	err := s.pool.QueryRow(ctx, `SELECT r.owner_id=$1 OR CASE policy.reputation_visibility
		WHEN 'users' THEN EXISTS (SELECT FROM mp_children WHERE resource=r.id AND sender=$1
			AND status IN ('processing','completed','declined','uncertain'))
		WHEN 'friends' THEN EXISTS (SELECT FROM mp_friends WHERE a=least($1,r.owner_id) AND b=greatest($1,r.owner_id) AND accepted)
		WHEN 'server' THEN true ELSE false END,
		stats.completed,stats.accepted,stats.rejected,stats.median
		FROM mp_resources r CROSS JOIN mp_policy policy
		CROSS JOIN LATERAL (SELECT count(*) AS completed,
			count(*) FILTER (WHERE o.accepted) AS accepted, count(*) FILTER (WHERE NOT o.accepted) AS rejected,
			percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM c.completed_at-c.submitted_at)::float8) AS median
			FROM mp_children c LEFT JOIN mp_outcomes o ON o.child=c.id
			WHERE c.resource=r.id AND c.status='completed') stats
		WHERE r.id=$2`, p.User, out.Resource).Scan(&visible, &out.Completed, &out.Accepted, &out.Rejected, &out.MedianSeconds)
	if err == nil && !visible {
		return nil, &fault{http.StatusForbidden, "you cannot view the reputation of resource " + out.Resource}
	}
	return out, missingRow(err, "no resource "+out.Resource)
}

type outcomeRequest struct {
	Resource string `json:"resource"`
	Request  string `json:"request"`
	Accepted *bool  `json:"accepted"`
}

func (s *Service) reportOutcome(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in outcomeRequest
	if err := body(r, &in); err != nil {
		return nil, err
	}
	if !identifier.MatchString(in.Resource) || !identifier.MatchString(in.Request) || in.Accepted == nil {
		return nil, bad("provide a resource, request and accepted flag")
	}
	err := s.write(ctx, func(tx pgx.Tx) error {
		if err := s.requireDevice(ctx, tx, p); err != nil {
			return err
		}
		// The tray uses the submission ID for single-target requests. A fan-out
		// with multiple actions on one resource can identify each child directly.
		type match struct{ ID, Owner, Status string }
		rows, err := tx.Query(ctx, `SELECT id,owner_id,status FROM mp_children
			WHERE sender=$1 AND resource=$2 AND (id=$3 OR parent=$3)
			ORDER BY (id=$3) DESC,id LIMIT 2`, p.User, in.Resource, in.Request)
		if err != nil {
			return err
		}
		candidates, err := pgx.CollectRows(rows, pgx.RowToStructByPos[match])
		if err != nil {
			return err
		}
		if len(candidates) == 0 {
			return &fault{http.StatusNotFound, "no request " + in.Request + " from you for resource " + in.Resource}
		}
		child := candidates[0]
		if len(candidates) > 1 && child.ID != in.Request {
			return conflict("multiple actions for this resource; report the child ID")
		}
		if child.Status != "completed" {
			return conflict("the request has no completed result")
		}
		tag, err := tx.Exec(ctx, `INSERT INTO mp_outcomes(child,accepted) VALUES($1,$2) ON CONFLICT(child) DO NOTHING`, child.ID, *in.Accepted)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			var accepted bool
			if err := tx.QueryRow(ctx, "SELECT accepted FROM mp_outcomes WHERE child=$1", child.ID).Scan(&accepted); err != nil {
				return err
			}
			if accepted != *in.Accepted {
				return conflict("a different outcome was already reported")
			}
			return nil
		}
		return recordEvent(ctx, tx, child.Owner, "outcome.reported", p.User, in.Resource)
	})
	return nil, err
}

func (s *Service) endorse(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in struct {
		Resource string `json:"resource"`
		Skill    string `json:"skill"`
	}
	if err := body(r, &in); err != nil {
		return nil, err
	}
	in.Skill = strings.TrimSpace(in.Skill)
	if !identifier.MatchString(in.Resource) || in.Skill == "" || len(in.Skill) > 128 {
		return nil, bad("provide a resource and skill")
	}
	err := s.write(ctx, func(tx pgx.Tx) error {
		if err := s.requireDevice(ctx, tx, p); err != nil {
			return err
		}
		var owner string
		err := tx.QueryRow(ctx, `SELECT owner_id FROM mp_resources r JOIN mp_friends f
			ON f.a=least(r.owner_id,$1) AND f.b=greatest(r.owner_id,$1) AND f.accepted
			WHERE r.id=$2 AND EXISTS(SELECT FROM mp_children c
				WHERE c.sender=$1 AND c.resource=r.id AND c.status='completed')`, p.User, in.Resource).Scan(&owner)
		if err == pgx.ErrNoRows {
			return &fault{http.StatusForbidden, "to endorse resource " + in.Resource + ", you must be friends with its owner and have completed a request for it"}
		}
		if err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `INSERT INTO mp_endorsements(resource,endorser,skill)
			VALUES($1,$2,$3) ON CONFLICT DO NOTHING`, in.Resource, p.User, in.Skill)
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		return recordEvent(ctx, tx, owner, "resource.endorsed", p.User, in.Resource)
	})
	return nil, err
}

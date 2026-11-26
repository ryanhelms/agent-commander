package control

import (
	"context"
	"errors"
	"net/http"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
)

type AccessRequest struct {
	ID              string    `json:"id"`
	Resource        string    `json:"resource"`
	Owner           string    `json:"owner"`
	OwnerHandle     string    `json:"ownerHandle"`
	Requester       string    `json:"requester"`
	RequesterHandle string    `json:"requesterHandle"`
	Actions         []string  `json:"actions"`
	Note            string    `json:"note"`
	Status          string    `json:"status"`
	CreatedAt       time.Time `json:"createdAt"`
}

func (s *Service) requestAccess(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in struct {
		Resource string   `json:"resource"`
		Actions  []string `json:"actions"`
		Note     string   `json:"note"`
	}
	if err := body(r, &in); err != nil {
		return nil, err
	}
	if !identifier.MatchString(in.Resource) || !validActions(in.Actions) {
		return nil, bad("provide a resource and 1–32 distinct actions")
	}
	slices.Sort(in.Actions)
	id := secret()
	err := s.write(ctx, func(tx pgx.Tx) error {
		var owner string
		var offered []string
		err := tx.QueryRow(ctx, `SELECT r.owner_id,r.actions FROM mp_resources r
			JOIN mp_friends f ON f.a=least(r.owner_id,$1) AND f.b=greatest(r.owner_id,$1) AND f.accepted
			WHERE r.id=$2 FOR SHARE OF r,f`, p.User, in.Resource).Scan(&owner, &offered)
		if errors.Is(err, pgx.ErrNoRows) {
			return forbidden()
		}
		if err != nil {
			return err
		}
		for _, action := range in.Actions {
			if !slices.Contains(offered, action) {
				return bad("requested action is not offered by this resource")
			}
		}
		if _, err = tx.Exec(ctx, `INSERT INTO mp_access_requests(id,resource,requester,actions,note)
			VALUES($1,$2,$3,$4,$5)`, id, in.Resource, p.User, in.Actions, in.Note); err != nil {
			return err
		}
		return recordEvent(ctx, tx, owner, "access.requested", p.User, in.Resource)
	})
	return map[string]string{"id": id}, err
}

func (s *Service) accessRequests(ctx context.Context, p Principal, _ *http.Request) (any, error) {
	rows, err := s.pool.Query(ctx, `SELECT q.id,q.resource,r.owner_id,coalesce(o.handle,''),
		q.requester,coalesce(p.handle,''),q.actions,q.note,q.status,q.created_at
		FROM mp_access_requests q JOIN mp_resources r ON r.id=q.resource
		JOIN mp_profiles o ON o.user_id=r.owner_id JOIN mp_profiles p ON p.user_id=q.requester
		WHERE r.owner_id=$1 OR q.requester=$1 ORDER BY q.created_at DESC,q.id`, p.User)
	if err != nil {
		return nil, err
	}
	requests, err := pgx.CollectRows(rows, pgx.RowToStructByPos[AccessRequest])
	return map[string]any{"requests": requests}, err
}

func (s *Service) deleteAccessRequest(ctx context.Context, p Principal, r *http.Request) (any, error) {
	tag, err := s.pool.Exec(ctx, `DELETE FROM mp_access_requests q USING mp_resources r
		WHERE q.resource=r.id AND q.id=$1 AND q.status='pending' AND (r.owner_id=$2 OR q.requester=$2)`, r.PathValue("id"), p.User)
	if err == nil && tag.RowsAffected() == 0 {
		return nil, missing()
	}
	return nil, err
}

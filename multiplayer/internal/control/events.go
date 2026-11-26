package control

import (
	"context"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
)

type Event struct {
	Seq      int64     `json:"seq"`
	At       time.Time `json:"at"`
	Kind     string    `json:"kind"`
	Actor    string    `json:"actor"`
	Resource string    `json:"resource,omitempty"`
	Detail   string    `json:"detail,omitempty"`
}

// Allocate sequence numbers in commit order so a poll cannot advance past an
// uncommitted, lower-numbered event. Feed reads continue while writers commit.
func lockEventWriters(ctx context.Context, tx pgx.Tx) error {
	_, err := tx.Exec(ctx, "LOCK TABLE mp_events IN SHARE ROW EXCLUSIVE MODE")
	return err
}

func recordEvent(ctx context.Context, tx pgx.Tx, recipient, kind, actor, resource string) error {
	if err := lockEventWriters(ctx, tx); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `INSERT INTO mp_events(recipient,kind,actor,resource) VALUES($1,$2,$3,$4)`, recipient, kind, actor, resource)
	return err
}

// RecordMemberJoined announces a first enrollment to existing members on this relay.
func RecordMemberJoined(ctx context.Context, tx pgx.Tx, user string) error {
	if err := lockEventWriters(ctx, tx); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `INSERT INTO mp_events(recipient,kind,actor)
		SELECT user_id,'member.joined',$1 FROM mp_members WHERE user_id<>$1`, user)
	return err
}

func (s *Service) events(ctx context.Context, p Principal, r *http.Request) (any, error) {
	query := r.URL.Query()
	var after int64
	if query.Has("after") {
		value, err := strconv.ParseInt(query.Get("after"), 10, 64)
		if err != nil || value < 0 {
			return nil, bad("after must be a nonnegative sequence number")
		}
		after = value
	}
	limit := 50
	if query.Has("limit") {
		value, err := strconv.Atoi(query.Get("limit"))
		if err != nil || value < 0 {
			return nil, bad("limit must be a nonnegative integer")
		}
		limit = min(value, 200)
	}
	rows, err := s.pool.Query(ctx, `SELECT e.seq,e.at,e.kind,COALESCE(p.handle,e.actor),e.resource,e.detail
		FROM mp_events e CROSS JOIN mp_policy policy LEFT JOIN mp_profiles p ON p.user_id=e.actor
		WHERE e.recipient=$1 AND e.seq>$2 AND now()-e.at < make_interval(days=>policy.retention_days)
		ORDER BY e.seq LIMIT $3`, p.User, after, limit)
	if err != nil {
		return nil, err
	}
	events, err := pgx.CollectRows(rows, pgx.RowToStructByPos[Event])
	return map[string]any{"events": events}, err
}

// PruneHistory removes expired feed entries and sealed payloads. Keep the
// addressed child and its status for retry reconciliation and reputation.
func (s *Service) PruneHistory(ctx context.Context) error {
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DELETE FROM mp_events e USING mp_policy p
			WHERE now()-e.at >= make_interval(days=>p.retention_days)`); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE mp_children c SET envelope='null'::jsonb,
			status=CASE WHEN status='pending' THEN 'expired' ELSE status END FROM mp_policy p
			WHERE c.envelope <> 'null'::jsonb AND now()-coalesce(c.submitted_at,c.expires_at) >= make_interval(days=>p.retention_days)`); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE mp_children c SET result=NULL,receipt_digest=sha256(convert_to(c.result::text,'UTF8'))
			FROM mp_policy p WHERE c.result IS NOT NULL
			AND now()-coalesce(c.completed_at,c.expires_at) >= make_interval(days=>p.retention_days)`)
		return err
	})
}

// RecordModeration publishes the change only if the credential transaction commits.
func RecordModeration(ctx context.Context, tx pgx.Tx, member, kind, admin, device string) error {
	return recordEvent(ctx, tx, member, kind, admin, device)
}

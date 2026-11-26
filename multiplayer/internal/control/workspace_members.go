package control

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// The owner edits a workspace's description. The group stays fixed because
// claims and departures are keyed to it.
func (s *Service) editWorkspace(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in struct{ Name, Goal, Repository, Base, Integration *string }
	if err := body(r, &in); err != nil {
		return nil, err
	}
	fields := []*string{in.Name, in.Goal, in.Repository, in.Base, in.Integration}
	changed := false
	for _, f := range fields {
		if f != nil {
			if strings.TrimSpace(*f) == "" {
				return nil, bad("workspace name, goal, repository and base cannot be empty")
			}
			changed = true
		}
	}
	if !changed {
		return nil, bad("nothing to change")
	}
	if in.Integration != nil && *in.Integration != "queue" && *in.Integration != "pull_request" {
		return nil, bad("integration must be queue or pull_request")
	}
	id := r.PathValue("id")
	var out workspace
	err := s.writeWorkspace(ctx, p, id, func(tx pgx.Tx, _ string) error {
		tag, err := tx.Exec(ctx, `UPDATE mp_workspaces SET name=coalesce($3,name),goal=coalesce($4,goal),
			repository=coalesce($5,repository),base=coalesce($6,base),integration=coalesce($7,integration)
			WHERE id=$1 AND owner_id=$2`, id, p.User, in.Name, in.Goal, in.Repository, in.Base, in.Integration)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return &fault{http.StatusForbidden, "only the owner can edit workspace " + id}
		}
		rows, err := readWorkspaces(ctx, tx, p.User, id)
		if err != nil {
			return err
		}
		if len(rows) != 1 {
			return missing()
		}
		out = rows[0]
		return nil
	})
	return out, err
}

// A member leaves one workspace and keeps its group. Their live claims there end.
func (s *Service) leaveWorkspace(ctx context.Context, p Principal, r *http.Request) (any, error) {
	id := r.PathValue("id")
	err := s.writeWorkspace(ctx, p, id, func(tx pgx.Tx, group string) error {
		var owner bool
		if err := tx.QueryRow(ctx, `SELECT owner_id=$2 FROM mp_workspaces WHERE id=$1`, id, p.User).Scan(&owner); err != nil {
			return err
		}
		if owner {
			return &fault{http.StatusForbidden, "the owner cannot leave workspace " + id}
		}
		if _, err := tx.Exec(ctx, `DELETE FROM mp_workspace_claims WHERE workspace_id=$1 AND holder_id=$2`, id, p.User); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO mp_workspace_departures(workspace_id,group_id,user_id) VALUES($1,$2,$3)`, id, group, p.User)
		return err
	})
	return nil, err
}

// CombinedView is a workspace's members and the workers the relay knows for each.
type CombinedView struct {
	Workspace string           `json:"workspace"`
	Members   []CombinedMember `json:"members"`
}

type CombinedMember struct {
	Handle  string           `json:"handle"`
	Online  bool             `json:"online"`
	Workers []CombinedWorker `json:"workers"`
	user    string
}

// CombinedWorker is a published agent or an agent holding claims. The relay
// has no record of a worker's branch or check results, so Branch is empty and
// Checks is nil.
type CombinedWorker struct {
	ID       string          `json:"id"`
	Name     string          `json:"name"`
	Resource string          `json:"resource"`
	Agent    string          `json:"agent"`
	Harness  string          `json:"harness"`
	Model    string          `json:"model"`
	State    string          `json:"state"`
	Branch   string          `json:"branch"`
	Checks   *WorkerChecks   `json:"checks"`
	Claims   []CombinedClaim `json:"claims"`
}

type WorkerChecks struct {
	Passed  int `json:"passed"`
	Failed  int `json:"failed"`
	Running int `json:"running"`
}

type CombinedClaim struct {
	ID        string    `json:"id"`
	Kind      string    `json:"kind"`
	Key       string    `json:"key"`
	ExpiresAt time.Time `json:"expiresAt"`
}

func (s *Service) combinedWorkspace(ctx context.Context, p Principal, r *http.Request) (any, error) {
	id := r.PathValue("id")
	view := CombinedView{Workspace: id, Members: []CombinedMember{}}
	err := pgx.BeginTxFunc(ctx, s.pool, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		var group string
		err := tx.QueryRow(ctx, `SELECT w.group_id FROM mp_workspaces w JOIN mp_group_members m ON m.group_id=w.group_id
			WHERE w.id=$1 AND m.user_id=$2 AND `+notDeparted, id, p.User).Scan(&group)
		if err != nil {
			return missingRow(err, "no workspace "+id+" in your groups")
		}
		rows, err := tx.Query(ctx, `SELECT m.user_id,coalesce(u.handle,''),
			EXISTS(SELECT FROM mp_leases l WHERE l.owner_id=m.user_id AND l.ready AND l.expires_at>now())
			FROM mp_workspaces w JOIN mp_group_members m ON m.group_id=w.group_id JOIN mp_profiles u ON u.user_id=m.user_id
			WHERE w.id=$1 AND `+notDeparted+` ORDER BY u.handle,m.user_id`, id)
		if err != nil {
			return err
		}
		index := map[string]int{}
		for rows.Next() {
			var m CombinedMember
			if err := rows.Scan(&m.user, &m.Handle, &m.Online); err != nil {
				rows.Close()
				return err
			}
			m.Workers = []CombinedWorker{}
			index[m.user] = len(view.Members)
			view.Members = append(view.Members, m)
		}
		if err := rows.Err(); err != nil {
			return err
		}
		// Show a member's agent where the caller could already see it: their own,
		// one shared with this workspace's group, or one visible as a friend or grantee.
		rows, err = tx.Query(ctx, `SELECT r.id,r.owner_id,r.name,coalesce(r.capabilities->>'harness',''),coalesce(r.capabilities->>'model',''),
			EXISTS(SELECT FROM mp_leases l WHERE l.device=r.device AND l.owner_id=r.owner_id AND l.ready AND l.expires_at>now())
			FROM mp_resources r
			WHERE r.kind='agent' AND r.owner_id=ANY($3) AND (r.owner_id=$1
				OR EXISTS(SELECT FROM mp_group_grants g WHERE g.group_id=$2 AND g.resource=r.id AND cardinality(g.actions)>0)
				OR (cardinality(r.actions)>0 AND EXISTS(SELECT FROM mp_friends f WHERE f.a=least($1,r.owner_id) AND f.b=greatest($1,r.owner_id) AND f.accepted))
				OR EXISTS(SELECT FROM mp_available_actions a WHERE a.resource=r.id AND a.grantee=$1 AND a.action=ANY(r.actions)))
			ORDER BY r.name,r.id`, p.User, group, memberIDs(view.Members))
		if err != nil {
			return err
		}
		for rows.Next() {
			var w CombinedWorker
			var owner string
			var online bool
			if err := rows.Scan(&w.ID, &owner, &w.Name, &w.Harness, &w.Model, &online); err != nil {
				rows.Close()
				return err
			}
			w.Resource, w.State, w.Claims = w.ID, "offline", []CombinedClaim{}
			if online {
				w.State = "online"
			}
			m := &view.Members[index[owner]]
			m.Workers = append(m.Workers, w)
		}
		if err := rows.Err(); err != nil {
			return err
		}
		rows, err = tx.Query(ctx, `SELECT holder_id,agent,holder,id,kind,key,expires_at FROM mp_live_workspace_claims
			WHERE workspace_id=$1 ORDER BY holder,kind,key,id`, id)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var holderID, agent, holder string
			var c CombinedClaim
			if err := rows.Scan(&holderID, &agent, &holder, &c.ID, &c.Kind, &c.Key, &c.ExpiresAt); err != nil {
				return err
			}
			i, ok := index[holderID]
			if !ok {
				continue
			}
			m := &view.Members[i]
			j := -1
			for k, w := range m.Workers {
				if w.Resource == "" && w.ID == holder {
					j = k
				}
			}
			if j < 0 {
				m.Workers = append(m.Workers, CombinedWorker{ID: holder, Name: agent, Agent: agent, State: "working", Claims: []CombinedClaim{}})
				j = len(m.Workers) - 1
			}
			m.Workers[j].Claims = append(m.Workers[j].Claims, c)
		}
		return rows.Err()
	})
	return view, err
}

func memberIDs(members []CombinedMember) []string {
	ids := make([]string, len(members))
	for i, m := range members {
		ids[i] = m.user
	}
	return ids
}

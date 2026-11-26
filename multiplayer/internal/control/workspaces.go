package control

import (
	"context"
	_ "embed"
	"errors"
	"net/http"
	"path"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

//go:embed workspaces.sql
var workspacesSchema string

func (s *Service) workspaceRoutes(routes map[string]endpoint) {
	const workspaces = "/v1/workspaces"
	const claims = workspaces + "/{id}/claims"
	const cards = workspaces + "/{id}/cards"
	routes["POST "+workspaces] = s.createWorkspace
	routes["GET "+workspaces] = s.workspaces
	routes["POST "+claims] = s.claimWorkspace
	routes["DELETE "+claims+"/{claim}"] = s.releaseWorkspaceClaim
	routes["PUT "+workspaces+"/{id}"] = s.editWorkspace
	routes["DELETE "+workspaces+"/{id}/membership"] = s.leaveWorkspace
	routes["GET "+workspaces+"/{id}/combined"] = s.combinedWorkspace
	routes["POST "+cards] = s.createCard
	routes["GET "+cards] = s.cards
	routes["GET "+cards+"/{card}"] = s.card
	routes["PUT "+cards+"/{card}"] = s.updateCard
}

type workspace struct {
	ID          string           `json:"id"`
	Owner       string           `json:"owner"`
	OwnerHandle string           `json:"ownerHandle"`
	Group       string           `json:"group"`
	Name        string           `json:"name"`
	Goal        string           `json:"goal"`
	Repository  string           `json:"repository"`
	Base        string           `json:"base"`
	Integration string           `json:"integration"`
	Claims      []workspaceClaim `json:"claims"`
}

type workspaceClaim struct {
	ID        string    `json:"id"`
	Kind      string    `json:"kind"`
	Key       string    `json:"key"`
	Holder    string    `json:"holder"`
	ExpiresAt time.Time `json:"expiresAt"`
}

// claimConflict names the live claim that blocked a request. Holder is the
// claim's handle/agent form; Claim is its ID in the workspace's claims.
type claimConflict struct{ Holder, Claim string }

func (e *claimConflict) Error() string { return "overlapping claim held by " + e.Holder }

// HolderHandle is the handle part of the holder.
func (e *claimConflict) HolderHandle() string {
	handle, _, _ := strings.Cut(e.Holder, "/")
	return handle
}

// notDeparted filters a member row m of workspace w to members who have not left it.
const notDeparted = `NOT EXISTS (SELECT FROM mp_workspace_departures d WHERE d.workspace_id=w.id AND d.user_id=m.user_id)`

func (s *Service) createWorkspace(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in struct{ Name, Goal, Repository, Base, Group, Integration string }
	if err := body(r, &in); err != nil {
		return nil, err
	}
	if strings.TrimSpace(in.Name) == "" || strings.TrimSpace(in.Goal) == "" || strings.TrimSpace(in.Repository) == "" || strings.TrimSpace(in.Base) == "" || in.Group == "" {
		return nil, bad("provide a name, goal, repository, base and group")
	}
	if in.Integration != "queue" && in.Integration != "pull_request" {
		return nil, bad("integration must be queue or pull_request")
	}
	w := workspace{ID: secret(), Owner: p.User, Group: in.Group, Name: in.Name, Goal: in.Goal, Repository: in.Repository, Base: in.Base, Integration: in.Integration, Claims: []workspaceClaim{}}
	err := s.write(ctx, func(tx pgx.Tx) error {
		if err := s.requireDevice(ctx, tx, p); err != nil {
			return err
		}
		err := tx.QueryRow(ctx, `INSERT INTO mp_workspaces(id,owner_id,group_id,name,goal,repository,base,integration)
			SELECT $1,$2,$3,$4,$5,$6,$7,$8 FROM mp_group_members WHERE group_id=$3 AND user_id=$2
			RETURNING (SELECT coalesce(handle,'') FROM mp_profiles WHERE user_id=$2)`,
			w.ID, w.Owner, w.Group, w.Name, w.Goal, w.Repository, w.Base, w.Integration).Scan(&w.OwnerHandle)
		return missingRow(err, "you do not belong to group "+in.Group)
	})
	return w, err
}

func (s *Service) workspaces(ctx context.Context, p Principal, _ *http.Request) (any, error) {
	result, err := readWorkspaces(ctx, s.pool, p.User, "")
	return map[string]any{"workspaces": result}, err
}

type workspaceReader interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
}

// readWorkspaces lists the workspaces the user can see, or the one named by id.
func readWorkspaces(ctx context.Context, db workspaceReader, user, id string) ([]workspace, error) {
	rows, err := db.Query(ctx, `SELECT w.id,w.owner_id,coalesce(owner.handle,''),w.group_id,w.name,w.goal,w.repository,w.base,w.integration,
		coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'kind',kind,'key',key,'holder',holder,'expiresAt',expires_at) ORDER BY kind,key,id)
		FROM mp_live_workspace_claims c WHERE c.workspace_id=w.id),'[]'::jsonb)
		FROM mp_workspaces w JOIN mp_profiles owner ON owner.user_id=w.owner_id
		JOIN mp_group_members m ON m.group_id=w.group_id AND m.user_id=$1
		WHERE ($2='' OR w.id=$2) AND `+notDeparted+` ORDER BY w.name,w.id`, user, id)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[workspace])
}

// Membership, overlap checks and any change to a board/claim share the same
// serializable transaction. Removing a member cascades to their existing claims.
func (s *Service) writeWorkspace(ctx context.Context, p Principal, id string, op func(pgx.Tx, string) error) error {
	return s.write(ctx, func(tx pgx.Tx) error {
		if err := s.requireDevice(ctx, tx, p); err != nil {
			return err
		}
		var group string
		if err := tx.QueryRow(ctx, `SELECT w.group_id FROM mp_workspaces w JOIN mp_group_members m
			ON m.group_id=w.group_id WHERE w.id=$1 AND m.user_id=$2 AND `+notDeparted+` FOR UPDATE OF w FOR SHARE OF m`, id, p.User).Scan(&group); err != nil {
			return missingRow(err, "no workspace "+id+" in your groups")
		}
		return op(tx, group)
	})
}

// A paths key is a comma-separated set of repository-relative paths. Each
// entry covers its descendants (including the familiar trailing /** spelling).
func claimKey(kind, key string) (string, error) {
	key = strings.TrimSpace(key)
	if key == "" || strings.ContainsRune(key, 0) {
		return "", bad("provide a nonempty claim key")
	}
	switch kind {
	case "issue", "card":
		return key, nil
	case "paths":
		paths := strings.Split(key, ",")
		for i, entry := range paths {
			entry = strings.TrimSpace(entry)
			if entry == "**" {
				entry = "."
			}
			entry = strings.TrimSuffix(entry, "/**")
			clean := path.Clean(entry)
			if entry == "" || path.IsAbs(entry) || clean == ".." || strings.HasPrefix(clean, "../") || strings.ContainsRune(clean, '*') {
				return "", bad("paths must be repository-relative files or directories")
			}
			paths[i] = clean
		}
		slices.Sort(paths)
		return strings.Join(slices.Compact(paths), ","), nil
	default:
		return "", bad("claim kind must be issue, paths or card")
	}
}

func claimsOverlap(kind, a, b string) bool {
	if kind != "paths" {
		return a == b
	}
	// Include the component boundary in the sort key. In this order a whole
	// subtree is contiguous, even beside names such as "src-go" and "src.go".
	subtrees := func(key string) []string {
		entries := strings.Split(key, ",")
		for i, entry := range entries {
			if entry == "." {
				entries[i] = ""
			} else {
				entries[i] = entry + "/"
			}
		}
		slices.Sort(entries)
		return entries
	}
	left, right := subtrees(a), subtrees(b)
	for len(left) > 0 && len(right) > 0 {
		if strings.HasPrefix(left[0], right[0]) || strings.HasPrefix(right[0], left[0]) {
			return true
		}
		if left[0] < right[0] {
			left = left[1:]
		} else {
			right = right[1:]
		}
	}
	return false
}

type claimInput struct{ Kind, Key, Holder string }

func (s *Service) claimWorkspace(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in claimInput
	if err := body(r, &in); err != nil {
		return nil, err
	}
	key, err := claimKey(in.Kind, in.Key)
	if err != nil {
		return nil, err
	}
	in.Key = key
	id := r.PathValue("id")
	var out workspaceClaim
	err = s.writeWorkspace(ctx, p, id, func(tx pgx.Tx, group string) error {
		var err error
		out, err = acquireWorkspaceClaim(ctx, tx, p, id, group, in)
		return err
	})
	return out, err
}

func acquireWorkspaceClaim(ctx context.Context, tx pgx.Tx, p Principal, id, group string, in claimInput) (workspaceClaim, error) {
	var c workspaceClaim
	handle, agent, found := strings.Cut(in.Holder, "/")
	if !found || !handlePattern.MatchString(handle) || !identifier.MatchString(agent) {
		return c, bad("holder must be handle/agent")
	}
	var ownHandle string
	if err := tx.QueryRow(ctx, `SELECT coalesce(handle,'') FROM mp_profiles WHERE user_id=$1`, p.User).Scan(&ownHandle); err != nil {
		return c, err
	}
	if handle != ownHandle {
		return c, &fault{http.StatusForbidden, "you can only claim work under your own handle"}
	}
	if in.Kind == "card" {
		var done bool
		if err := tx.QueryRow(ctx, `SELECT done FROM mp_workspace_cards WHERE workspace_id=$1 AND id=$2`, id, in.Key).Scan(&done); err != nil {
			return c, missingRow(err, "no card "+in.Key+" in workspace "+id)
		}
		if done {
			return c, conflict("reopen the completed card before claiming it")
		}
	}
	rows, err := tx.Query(ctx, `SELECT id,key,holder FROM mp_live_workspace_claims WHERE workspace_id=$1 AND kind=$2 ORDER BY id`, id, in.Kind)
	if err != nil {
		return c, err
	}
	defer rows.Close()
	for rows.Next() {
		var claim, other, holder string
		if err := rows.Scan(&claim, &other, &holder); err != nil {
			return c, err
		}
		if claimsOverlap(in.Kind, in.Key, other) {
			return c, &claimConflict{holder, claim}
		}
	}
	if err := rows.Err(); err != nil {
		return c, err
	}
	// Expired rows have no further work; discard them as the workspace receives new claims.
	if _, err := tx.Exec(ctx, `DELETE FROM mp_workspace_claims c WHERE c.workspace_id=$1 AND NOT EXISTS
		(SELECT FROM mp_live_workspace_claims live WHERE live.id=c.id)`, id); err != nil {
		return c, err
	}
	c = workspaceClaim{ID: secret(), Kind: in.Kind, Key: in.Key, Holder: in.Holder}
	err = tx.QueryRow(ctx, `WITH lease AS (
		SELECT device,generation,expires_at FROM mp_leases WHERE owner_id=$1 AND device=$2 AND expires_at>clock_timestamp() FOR SHARE)
		INSERT INTO mp_workspace_claims(id,workspace_id,group_id,kind,key,holder_id,agent,device,generation)
		SELECT $3,$4,$5,$6,$7,$1,$8,device,generation FROM lease
		RETURNING (SELECT expires_at + interval '10 minutes' FROM lease)`, p.User, p.Device, c.ID, id, group, c.Kind, c.Key, agent).Scan(&c.ExpiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return c, conflict("an active device lease is required to claim work")
	}
	if err == nil && in.Kind == "card" {
		_, err = tx.Exec(ctx, `UPDATE mp_workspace_cards SET assignee='' WHERE workspace_id=$1 AND id=$2`, id, in.Key)
	}
	return c, err
}

func (s *Service) releaseWorkspaceClaim(ctx context.Context, p Principal, r *http.Request) (any, error) {
	id := r.PathValue("id")
	err := s.writeWorkspace(ctx, p, id, func(tx pgx.Tx, _ string) error {
		tag, err := tx.Exec(ctx, `DELETE FROM mp_workspace_claims WHERE workspace_id=$1 AND id=$2 AND holder_id=$3 AND device=$4`, id, r.PathValue("claim"), p.User, p.Device)
		if err == nil && tag.RowsAffected() == 0 {
			return &fault{http.StatusNotFound, "no claim " + r.PathValue("claim") + " held by this device in workspace " + id}
		}
		return err
	})
	return nil, err
}

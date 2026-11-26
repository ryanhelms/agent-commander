package control

import (
	"context"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5"
)

type workspaceCard struct {
	ID       string `json:"id"`
	Title    string `json:"title"`
	Body     string `json:"body"`
	State    string `json:"state"`
	Assignee string `json:"assignee"`
	Result   string `json:"result"`
}

func (s *Service) createCard(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in struct{ Title, Body string }
	if err := body(r, &in); err != nil {
		return nil, err
	}
	if strings.TrimSpace(in.Title) == "" {
		return nil, bad("provide a card title")
	}
	id := r.PathValue("id")
	card := workspaceCard{ID: secret(), Title: in.Title, Body: in.Body, State: "open"}
	err := s.writeWorkspace(ctx, p, id, func(tx pgx.Tx, _ string) error {
		_, err := tx.Exec(ctx, `INSERT INTO mp_workspace_cards(id,workspace_id,title,body) VALUES($1,$2,$3,$4)`, card.ID, id, card.Title, card.Body)
		return err
	})
	return card, err
}

func (s *Service) cards(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var cards []workspaceCard
	err := s.pool.QueryRow(ctx, `SELECT coalesce((SELECT jsonb_agg(jsonb_build_object(
		'id',id,'title',title,'body',body,'state',state,'assignee',assignee,'result',result) ORDER BY created_at,id)
		FROM mp_workspace_board b WHERE workspace_id=w.id),'[]'::jsonb)
		FROM mp_workspaces w JOIN mp_group_members m ON m.group_id=w.group_id WHERE w.id=$1 AND m.user_id=$2`, r.PathValue("id"), p.User).Scan(&cards)
	return map[string]any{"cards": cards}, missingRow(err, "no workspace "+r.PathValue("id")+" in your groups")
}

func readCard(ctx context.Context, db membershipReader, p Principal, id, card string) (workspaceCard, error) {
	var b workspaceCard
	err := db.QueryRow(ctx, `SELECT b.id,b.title,b.body,b.state,b.assignee,b.result
		FROM mp_workspace_board b JOIN mp_workspaces w ON w.id=b.workspace_id JOIN mp_group_members m ON m.group_id=w.group_id
		WHERE w.id=$1 AND b.id=$2 AND m.user_id=$3`, id, card, p.User).Scan(&b.ID, &b.Title, &b.Body, &b.State, &b.Assignee, &b.Result)
	return b, missingRow(err, "no card "+card+" available to you in workspace "+id)
}

func (s *Service) card(ctx context.Context, p Principal, r *http.Request) (any, error) {
	return readCard(ctx, s.pool, p, r.PathValue("id"), r.PathValue("card"))
}

func (s *Service) updateCard(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in struct{ State, Assignee, Result *string }
	if err := body(r, &in); err != nil {
		return nil, err
	}
	if in.State != nil && *in.State != "open" && *in.State != "done" && *in.State != "claimed" {
		return nil, bad("state must be open, claimed or done")
	}
	id, key := r.PathValue("id"), r.PathValue("card")
	var card workspaceCard
	err := s.writeWorkspace(ctx, p, id, func(tx pgx.Tx, group string) error {
		var err error
		card, err = readCard(ctx, tx, p, id, key)
		if err != nil {
			return err
		}
		wasClaimed := card.State == "claimed"
		if wasClaimed {
			var mine bool
			if err := tx.QueryRow(ctx, `SELECT holder_id=$3 AND device=$4 FROM mp_live_workspace_claims
				WHERE workspace_id=$1 AND kind='card' AND key=$2`, id, key, p.User, p.Device).Scan(&mine); err != nil {
				return err
			}
			if !mine {
				return &claimConflict{card.Assignee}
			}
		}
		if in.State != nil {
			card.State = *in.State
		}
		if in.Result != nil {
			card.Result = *in.Result
		}
		if in.Assignee != nil {
			if wasClaimed && card.State == "claimed" && card.Assignee != *in.Assignee {
				return &claimConflict{card.Assignee}
			}
			card.Assignee = *in.Assignee
		} else if wasClaimed && card.State == "open" {
			card.Assignee = ""
		}

		if card.State == "claimed" && !wasClaimed {
			_, err = acquireWorkspaceClaim(ctx, tx, p, id, group, claimInput{"card", key, card.Assignee})
			if err != nil {
				return err
			}
		} else if card.State != "claimed" && wasClaimed {
			if _, err := tx.Exec(ctx, `DELETE FROM mp_workspace_claims WHERE workspace_id=$1 AND kind='card' AND key=$2`, id, key); err != nil {
				return err
			}
		}
		assignee := card.Assignee
		if card.State == "claimed" {
			assignee = "" // The claim supplies the displayed assignee until release or expiry.
		} else if in.Assignee != nil && assignee != "" {
			handle, _, _ := strings.Cut(assignee, "/")
			var member bool
			if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT FROM mp_profiles p JOIN mp_group_members m ON m.user_id=p.user_id
				WHERE p.handle=$1 AND m.group_id=$2)`, handle, group).Scan(&member); err != nil {
				return err
			}
			if !member {
				return bad("assignee must be a workspace member")
			}
		}
		_, err = tx.Exec(ctx, `UPDATE mp_workspace_cards SET done=$3,assignee=$4,result=$5 WHERE workspace_id=$1 AND id=$2`, id, key, card.State == "done", assignee, card.Result)
		return err
	})
	return card, err
}

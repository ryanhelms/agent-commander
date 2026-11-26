package device

import (
	"context"
	"errors"
	"net/url"
	"regexp"

	"agentcommander.network/pilot/internal/identity"
)

// boardInput is the coordinator verb "board" used by commander_network_board.
type boardInput struct {
	Op        string `json:"op"`
	Workspace string `json:"workspace"`
	Card      string `json:"card"`
	Result    string `json:"result"`
	Text      string `json:"text"`
}

var boardID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

// board lets an agent read and work the task board of workspaces its owner
// belongs to. The relay enforces membership; agents cannot create workspaces,
// groups or grants.
func (a *Agent) board(ctx context.Context, s identity.Session, actor string, in boardInput) (any, error) {
	if in.Op == "" {
		in.Op = "list"
	}
	if in.Workspace == "" {
		if in.Op != "list" {
			return nil, errors.New("name a workspace")
		}
		var out any
		return out, a.remote(ctx, s, "GET", "/v1/workspaces", nil, &out)
	}
	if !boardID.MatchString(in.Workspace) || (in.Card != "" && !boardID.MatchString(in.Card)) {
		return nil, errors.New("invalid workspace or card id")
	}
	cards := "/v1/workspaces/" + url.PathEscape(in.Workspace) + "/cards"
	if in.Op == "list" {
		var out any
		return out, a.remote(ctx, s, "GET", cards, nil, &out)
	}
	if in.Card == "" {
		return nil, errors.New("name a card")
	}
	card := cards + "/" + url.PathEscape(in.Card)
	holder := a.handle + "/" + actor
	var body map[string]any
	switch in.Op {
	case "claim":
		body = map[string]any{"state": "claimed", "assignee": holder}
	case "release":
		body = map[string]any{"state": "open"}
	case "complete":
		body = map[string]any{"state": "done", "result": in.Result}
	case "comment":
		if in.Text == "" {
			return nil, errors.New("comment text is empty")
		}
		var cur struct{ Result string }
		if e := a.remote(ctx, s, "GET", card, nil, &cur); e != nil {
			return nil, e
		}
		note := "[" + holder + "] " + in.Text
		if cur.Result != "" {
			note = cur.Result + "\n" + note
		}
		body = map[string]any{"result": note}
	default:
		return nil, errors.New("op must be list, claim, release, complete or comment")
	}
	var out any
	return out, a.remote(ctx, s, "PUT", card, body, &out)
}

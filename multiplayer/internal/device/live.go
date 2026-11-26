package device

import (
	"agentcommander.network/pilot/internal/actions"
	"context"
	"encoding/json"
	"errors"
	"os/exec"
	"slices"
	"strings"
	"time"

	"agentcommander.network/pilot/internal/identity"
)

func (a *Agent) liveVerb(ctx context.Context, s identity.Session, verb string, in input) (any, error) {
	switch verb {
	case "watch":
		payload, _ := json.Marshal(map[string]string{"after": in.After})
		_, row, e := a.sendOne(ctx, s, in.Resource, "agent.watch", payload, 8*time.Second)
		if e != nil {
			return nil, e
		}
		return row, nil
	case "handover":
		if in.Handle == "" || in.Resource == "" || in.Minutes < 1 || in.Minutes > 240 {
			return nil, errors.New("handover needs a friend, a resource and 1–240 minutes")
		}
		peer, e := a.lookupUser(ctx, s, in.Handle)
		if e != nil {
			return nil, e
		}
		if peer.User == s.User {
			return nil, errors.New("hand control to a friend, not to yourself")
		}
		if peer.Status != "accepted" {
			return nil, errors.New("hand control to an accepted friend")
		}
		a.mu.Lock()
		granted := slices.ContainsFunc(a.policy.Grants, func(g actions.Grant) bool {
			return g.Peer == peer.User && g.Resource == in.Resource && g.ExpiresAt.After(time.Now()) && (g.Action == "agent.ask" || g.Action == "agent.suggest")
		})
		a.mu.Unlock()
		if !granted {
			return nil, errors.New("that friend has no Consult or Suggest grant on this worker")
		}
		until := time.Now().Add(time.Duration(in.Minutes) * time.Minute)
		a.mu.Lock()
		if a.handovers == nil {
			a.handovers = map[string]time.Time{}
		}
		a.handovers[peer.User+"|"+in.Resource] = until
		a.mu.Unlock()
		return map[string]any{"handle": in.Handle, "resource": in.Resource, "until": until}, nil
	case "handback":
		// The tray may name the holder by handle or by the account ID handovers lists.
		a.mu.Lock()
		_, byID := a.handovers[in.Handle+"|"+in.Resource]
		a.mu.Unlock()
		peer := in.Handle
		if !byID {
			user, e := a.lookupUser(ctx, s, in.Handle)
			if e != nil {
				return nil, e
			}
			peer = user.User
		}
		a.mu.Lock()
		delete(a.handovers, peer+"|"+in.Resource)
		a.mu.Unlock()
		return struct{}{}, nil
	case "handovers":
		a.mu.Lock()
		out := []map[string]any{}
		for k, until := range a.handovers {
			if time.Now().After(until) {
				delete(a.handovers, k)
				continue
			}
			user, resource, _ := strings.Cut(k, "|")
			out = append(out, map[string]any{"user": user, "resource": resource, "until": until, "server": a.cfg.ServerID})
		}
		a.mu.Unlock()
		if len(out) > 0 {
			handles := a.friendHandles(ctx, s)
			for _, row := range out {
				row["handle"] = handles[row["user"].(string)]
			}
		}
		return map[string]any{"handovers": out}, nil
	case "fanout":
		if len(in.Targets) < 2 || len(in.Targets) > 32 || len(in.Payload) == 0 || !json.Valid(in.Payload) {
			return nil, errors.New("fan-out needs 2–32 targets and a JSON payload")
		}
		id := newID()
		targets := make([]Target, len(in.Targets))
		for i, t := range in.Targets {
			targets[i] = Target{Resource: t.Resource, Action: t.Action, Payload: in.Payload}
		}
		res, e := a.submit(ctx, s, Submit{ID: id, Targets: targets})
		if e != nil {
			return nil, e
		}
		title := in.Name
		if title == "" {
			title = "Fan-out"
		}
		record := SentRequest{ID: id, Resource: in.Targets[0].Resource, Action: "fanout:" + in.Targets[0].Action, Title: title, At: time.Now().UTC()}
		for _, c := range allRows(res) {
			cid, _ := c["id"].(string)
			resource, _ := c["resource"].(string)
			record.Children = append(record.Children, SentChild{ID: cid, Resource: resource})
		}
		_ = a.logSent(record)
		return map[string]any{"request": id, "children": res}, nil
	case "review-post":
		if !strings.HasPrefix(in.PR, "https://") {
			return nil, errors.New("name the pull request URL")
		}
		res, e := a.receipt(ctx, s, in.Request)
		if e != nil {
			return nil, e
		}
		b, _ := json.Marshal(firstRow(res)["value"])
		var review struct {
			Summary  string
			Findings []struct {
				File, Severity, Text string
				Line                 int
			}
		}
		if json.Unmarshal(b, &review) != nil || review.Summary == "" {
			return nil, errors.New("that request has no review result yet")
		}
		var body strings.Builder
		body.WriteString(review.Summary + "\n")
		for _, f := range review.Findings {
			loc := f.File
			if f.Line > 0 {
				loc += ":" + itoa(f.Line)
			}
			body.WriteString("\n- **" + f.Severity + "** `" + loc + "`: " + f.Text)
		}
		out, e := exec.CommandContext(ctx, "gh", "pr", "review", in.PR, "--comment", "--body", body.String()).CombinedOutput()
		if e != nil {
			return nil, errors.New("gh pr review failed: " + strings.TrimSpace(string(out)))
		}
		return map[string]string{"posted": in.PR}, nil
	}
	return nil, errors.New("unknown operation")
}

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }

func (a *Agent) lookupUser(ctx context.Context, s identity.Session, handle string) (Friend, error) {
	var u Friend
	part, e := segment(handle)
	if e != nil {
		return u, e
	}
	if e = a.remote(ctx, s, "GET", "/v1/users/"+part, nil, &u); e != nil {
		return u, e
	}
	if u.User == "" {
		return u, errors.New("unknown friend")
	}
	return u, nil
}

// online lists accepted friends with presence and the resources they share.
func (a *Agent) online(ctx context.Context, s identity.Session) (any, error) {
	var social struct{ Friends []Friend }
	if e := a.remote(ctx, s, "GET", "/v1/friends", nil, &social); e != nil {
		return nil, e
	}
	rs, e := a.resources(ctx, s)
	if e != nil {
		return nil, e
	}
	out := []map[string]any{}
	for _, f := range social.Friends {
		if f.Status != "accepted" {
			continue
		}
		shared := []map[string]any{}
		for _, r := range rs {
			if r.Owner == f.User {
				shared = append(shared, map[string]any{"id": r.ID, "name": r.Name, "kind": r.Kind, "actions": r.Actions})
			}
		}
		out = append(out, map[string]any{"handle": f.Handle, "displayName": f.DisplayName, "online": f.Online, "presence": f.Presence, "statusMessage": f.StatusMessage, "resources": shared})
	}
	return map[string]any{"friends": out}, nil
}

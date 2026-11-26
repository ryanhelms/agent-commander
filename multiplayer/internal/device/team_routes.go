package device

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"

	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/identity"
)

// Both named tray verbs and the generic relay verb use these routes and checks.
var teamRoutes = []string{"/v1/groups", "/v1/workspaces", "/v1/knowledge", "/v1/outcomes", "/v1/reputation", "/v1/endorsements", "/v1/directory", "/v1/admin", "/v1/access-requests"}

func publicInfoRoute(method, route string) bool {
	path, _, _ := strings.Cut(route, "?")
	return strings.EqualFold(method, "GET") && path == "/v1/info"
}

func (a *Agent) teamRelay(ctx context.Context, s identity.Session, method, route string, body json.RawMessage) (any, error) {
	method = strings.ToUpper(method)
	path, _, _ := strings.Cut(route, "?")
	allowed := publicInfoRoute(method, route) || slices.ContainsFunc(teamRoutes, func(base string) bool {
		return path == base || strings.HasPrefix(path, base+"/")
	})
	if !allowed || !slices.Contains([]string{"GET", "POST", "PUT", "DELETE"}, method) || strings.Contains(route, "..") {
		return nil, errors.New("that relay route is not available to the tray")
	}
	var payload any
	if len(body) > 0 {
		if !json.Valid(body) {
			return nil, errors.New("invalid body")
		}
		payload = body
		if path == "/v1/knowledge" || strings.HasPrefix(path, "/v1/knowledge/") {
			var item struct{ Content string }
			if err := json.Unmarshal(body, &item); err != nil {
				return nil, errors.New("invalid knowledge item")
			}
			if LooksSecret(item.Content) {
				return nil, errors.New("this item seems to contain a secret; replace it with a ${NAME} placeholder before sharing")
			}
		}
	}
	var out any
	err := a.remote(ctx, s, method, route, payload, &out)
	return out, teamRefusal(err)
}

// The relay can explain a refused team edit with the exact group, resource,
// or member. Pass that sentence through to the tray.
func teamRefusal(err error) error {
	var status statusError
	if errors.As(err, &status) && status.message != "" {
		switch status.code {
		case http.StatusBadRequest, http.StatusForbidden, http.StatusNotFound:
			return errors.New(status.message)
		}
	}
	return err
}

func (a *Agent) namedTeamRelay(ctx context.Context, s identity.Session, verb string, in input) (any, error) {
	var method, path string
	var fields map[string]string
	switch verb {
	case "groups", "workspaces", "knowledge":
		method, path = "GET", "/v1/"+verb
	case "admin-members":
		method, path = "GET", "/v1/admin/members"
	case "workspace-edit", "workspace-leave":
		workspace, err := segment(cmp.Or(in.Workspace, in.ID))
		if err != nil {
			return nil, err
		}
		method, path = "PUT", "/v1/workspaces/"+workspace
		if verb == "workspace-leave" {
			method, path = "DELETE", path+"/membership"
			break
		}
		// Only named fields change; an empty one keeps its current value.
		fields = map[string]string{}
		for k, v := range map[string]string{"name": in.Name, "goal": in.Goal, "repository": in.Repository, "base": in.Base, "integration": in.Integration} {
			if v != "" {
				fields[k] = v
			}
		}
		if len(fields) == 0 && (len(in.Body) == 0 || string(in.Body) == "null") {
			return nil, errors.New("nothing to change")
		}
	case "group-create":
		method, path = "POST", "/v1/groups"
		fields = map[string]string{"name": in.Name}
	case "group-delete", "group-add", "group-remove":
		group, err := segment(cmp.Or(in.Group, in.ID))
		if err != nil {
			return nil, err
		}
		method, path = "DELETE", "/v1/groups/"+group
		if verb != "group-delete" {
			handle, err := segment(in.Handle)
			if err != nil {
				return nil, err
			}
			path += "/members/" + handle
			if verb == "group-add" {
				method = "PUT"
			}
		}
	case "workspace-create":
		method, path = "POST", "/v1/workspaces"
		fields = map[string]string{"name": in.Name, "goal": in.Goal, "repository": in.Repository, "base": in.Base, "group": in.Group, "integration": in.Integration}
	case "claim", "release":
		workspace, err := segment(in.Workspace)
		if err != nil {
			return nil, err
		}
		method, path = "POST", "/v1/workspaces/"+workspace+"/claims"
		if verb == "release" {
			claim, err := segment(cmp.Or(in.Claim, in.ID))
			if err != nil {
				return nil, err
			}
			method, path = "DELETE", path+"/"+claim
		} else {
			fields = map[string]string{"kind": in.Kind, "key": in.Key, "holder": in.Holder}
		}
	default:
		return nil, errors.New("unknown team operation")
	}
	var payload json.RawMessage
	if fields != nil {
		payload = in.Body
		if len(payload) == 0 || string(payload) == "null" {
			payload, _ = json.Marshal(fields) // string fields always encode
		}
	}
	return a.teamRelay(ctx, s, method, path, payload)
}

// combinedWorkspace reads a workspace's combined view. The relay cannot tell
// which Commander worker a published agent runs, but this device can for its
// own agents: a claim held under an own agent's enrolled worker joins that
// agent's row.
func (a *Agent) combinedWorkspace(ctx context.Context, s identity.Session, in input) (any, error) {
	workspace, err := segment(cmp.Or(in.Workspace, in.ID))
	if err != nil {
		return nil, err
	}
	var view control.CombinedView
	if err := a.remote(ctx, s, "GET", "/v1/workspaces/"+workspace+"/combined", nil, &view); err != nil {
		return nil, teamRefusal(err)
	}
	a.mu.Lock()
	targets := map[string]string{} // resource ID -> enrolled worker
	for _, r := range a.policy.Resources {
		if r.Kind == "agent" {
			targets[r.ID] = r.Target
		}
	}
	a.mu.Unlock()
	for i := range view.Members {
		view.Members[i].Workers = mergeOwnClaims(view.Members[i].Workers, targets)
	}
	return view, nil
}

func mergeOwnClaims(workers []control.CombinedWorker, targets map[string]string) []control.CombinedWorker {
	own := map[string]int{} // enrolled worker -> the own agent's row
	for i, w := range workers {
		if target := targets[w.Resource]; w.Resource != "" && target != "" {
			workers[i].Agent = target
			if _, seen := own[target]; !seen {
				own[target] = i
			}
		}
	}
	joined := make([]bool, len(workers))
	for i, w := range workers {
		if j, ok := own[w.Agent]; ok && w.Resource == "" {
			workers[j].Claims = append(workers[j].Claims, w.Claims...)
			workers[j].Agent, workers[j].State = w.Agent, "working"
			joined[i] = true
		}
	}
	merged := make([]control.CombinedWorker, 0, len(workers))
	for i, w := range workers {
		if !joined[i] {
			merged = append(merged, w)
		}
	}
	return merged
}

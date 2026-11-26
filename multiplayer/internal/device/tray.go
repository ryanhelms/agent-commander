package device

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"

	"agentcommander.network/pilot/internal/actions"
	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/identity"
)

type input struct {
	ID            string          `json:"id"`
	Handle        string          `json:"handle"`
	Resource      string          `json:"resource"`
	Capability    string          `json:"capability"`
	Name          string          `json:"name"`
	Kind          string          `json:"kind"`
	Target        string          `json:"target"`
	MaxUses       int             `json:"maxUses"`
	ExpiresAt     time.Time       `json:"expiresAt"`
	Token         string          `json:"token"`
	Server        string          `json:"server"`
	DisplayName   *string         `json:"displayName"`
	StatusMessage *string         `json:"statusMessage"`
	Avatar        *string         `json:"avatar"`
	Presence      string          `json:"presence"`
	Mode          string          `json:"mode"`
	AllowedEmails []string        `json:"allowedEmails"`
	Admins        []string        `json:"admins"`
	TTLHours      int             `json:"ttlHours"`
	Invite        string          `json:"invite"`
	Approval      string          `json:"approval"`
	BudgetTokens  int             `json:"budgetTokens"`
	Attribution   string          `json:"attribution"`
	Reason        string          `json:"reason"`
	Payload       json.RawMessage `json:"payload"`
	Request       string          `json:"request"`
	Text          string          `json:"text"`
	Checkout      string          `json:"checkout"`
	Artifact      int             `json:"artifact"`
	Minutes       int             `json:"minutes"`
	After         string          `json:"after"`
	PR            string          `json:"pr"`
	Targets       []Target        `json:"targets"`
	Method        string          `json:"method"`
	Path          string          `json:"path"`
	Body          json.RawMessage `json:"body"`
	Workspace     string          `json:"workspace"`
	Branch        string          `json:"branch"`
	TestCommand   []string        `json:"testCommand"`
	Item          json.RawMessage `json:"item"`
	Destination   string          `json:"destination"`
}
type trayGrant struct {
	ID         string    `json:"id"`
	Handle     string    `json:"handle"`
	Kind       string    `json:"kind"`
	Resource   string    `json:"resource"`
	Capability string    `json:"capability"`
	ExpiresAt  time.Time `json:"expiresAt"`
	MaxUses    int       `json:"maxUses"`
}

func (a *Agent) status(ctx context.Context) (any, error) {
	a.mu.Lock()
	s := a.creds.Session
	pending, why := a.loginPending, a.problem
	online := s.User != "" && time.Now().Before(a.lease.ExpiresAt)
	a.mu.Unlock()
	result := map[string]any{"signedIn": s.User != "", "online": online, "loginPending": pending, "handle": "", "friends": []any{}, "incoming": []any{}, "outgoing": []any{}, "grants": []any{}, "resources": []any{}, "shared": []any{}, "error": why}
	if s.User == "" {
		return result, nil
	}
	s, e := a.getSession(ctx)
	if e != nil {
		result["error"] = e.Error()
		result["online"] = false
		return result, nil
	}
	var profile control.User
	if e = a.remote(ctx, s, "GET", "/v1/profile", nil, &profile); e != nil {
		var status statusError
		if errors.As(e, &status) && status.code == 404 {
			return result, nil
		}
		result["error"] = e.Error()
		result["online"] = false
		return result, nil
	}
	result["handle"] = profile.Handle
	a.mu.Lock()
	a.handle = profile.Handle
	a.mu.Unlock()
	var social struct{ Friends []Friend }
	if e = a.remote(ctx, s, "GET", "/v1/friends", nil, &social); e != nil {
		return nil, e
	}
	friends, incoming, outgoing := []map[string]any{}, []map[string]any{}, []map[string]any{}
	for _, f := range social.Friends {
		row := map[string]any{"id": f.Handle, "handle": f.Handle, "online": f.Online, "displayName": f.DisplayName, "statusMessage": f.StatusMessage, "presence": f.Presence, "hasAvatar": f.HasAvatar, "contactKey": f.ContactKey, "lastSeen": f.LastSeen}
		switch f.Status {
		case "accepted":
			friends = append(friends, row)
		case "incoming":
			incoming = append(incoming, row)
		case "outgoing":
			outgoing = append(outgoing, row)
		}
	}
	result["friends"], result["incoming"], result["outgoing"] = friends, incoming, outgoing
	on := 0
	for _, f := range friends {
		if f["online"] == true {
			on++
		}
	}
	a.mu.Lock()
	a.friendsOn, a.incoming = on, len(incoming)
	a.mu.Unlock()
	rr, e := a.resources(ctx, s)
	if e != nil {
		return nil, e
	}
	own, shared := []map[string]any{}, []map[string]any{}
	kind := map[string]string{}
	for _, r := range rr {
		row := map[string]any{"id": r.ID, "kind": r.Kind, "name": r.Name, "actions": r.Actions, "owner": r.Handle, "device": r.Device}
		kind[r.ID] = r.Kind
		if r.Device == s.Device && r.Owner == s.User {
			own = append(own, row)
		} else if r.Owner != s.User {
			shared = append(shared, row)
		}
	}
	result["resources"], result["shared"] = own, shared
	var grants struct{ Grants []control.Grant }
	if e = a.remote(ctx, s, "GET", "/v1/grants", nil, &grants); e != nil {
		return nil, e
	}
	local := []trayGrant{}
	a.mu.Lock()
	byID := make(map[string]actions.Grant, len(a.policy.Grants))
	for _, entry := range a.policy.Grants {
		byID[entry.ID] = entry
	}
	a.mu.Unlock()
	for _, g := range grants.Grants {
		if g.Owner != s.User || g.Device != s.Device {
			continue
		}
		for _, cap := range g.Actions {
			id := grantID(g.Resource, g.Grantee, cap)
			limit, expiry := int(g.MaxUses), g.ExpiresAt
			if entry, ok := byID[id]; ok {
				limit, expiry = entry.MaxUses, entry.ExpiresAt
			}
			local = append(local, trayGrant{id, g.Handle, kind[g.Resource], g.Resource, cap, expiry, limit})
		}
	}
	result["grants"] = local
	return result, nil
}
func grantID(resource, user, action string) string { return key(resource + "|" + user + "|" + action) }
func (a *Agent) grant(ctx context.Context, s identity.Session, in input, revoke bool) error {
	var p localPolicy
	a.mu.Lock()
	p = a.policy
	p.Grants = slices.Clone(p.Grants)
	a.mu.Unlock()
	var peer control.User
	var published struct{ Grants []control.Grant }
	if err := a.remote(ctx, s, "GET", "/v1/grants", nil, &published); err != nil {
		return err
	}
	resource := in.Resource
	action := in.Capability
	if revoke {
		for _, g := range published.Grants {
			if g.Owner != s.User || g.Device != s.Device {
				continue
			}
			for _, cap := range g.Actions {
				if grantID(g.Resource, g.Grantee, cap) == in.ID {
					resource, action, peer = g.Resource, cap, control.User{User: g.Grantee, Handle: g.Handle}
				}
			}
		}
		if peer.User == "" {
			return nil
		}
	} else {
		if !idPattern.MatchString(in.Handle) {
			return errors.New("invalid peer handle")
		}
		if e := a.remote(ctx, s, "GET", "/v1/users/"+url.PathEscape(in.Handle), nil, &peer); e != nil {
			return e
		}
	}
	i := slices.IndexFunc(p.Resources, func(r actions.Resource) bool { return r.ID == resource })
	if i < 0 || !slices.Contains(actions.ResourceCapabilities(p.Resources[i]), action) {
		return errors.New("unsupported local resource or capability")
	}
	// The other user can end the friendship from a different device. Reconcile
	// with the relay before carrying any previously granted capability forward.
	var current []string
	for _, g := range published.Grants {
		if g.Owner == s.User && g.Device == s.Device && g.Grantee == peer.User && g.Resource == resource && g.ExpiresAt.After(time.Now()) {
			current = g.Actions
			break
		}
	}
	next := []actions.Grant{}
	for _, g := range p.Grants {
		if g.Resource != resource || g.Peer != peer.User {
			next = append(next, g)
			continue
		}
		if g.Action != action && g.ExpiresAt.After(time.Now()) && slices.Contains(current, g.Action) {
			next = append(next, g)
		}
	}
	expiry := in.ExpiresAt
	limit := in.MaxUses
	if !revoke {
		if expiry.IsZero() {
			expiry = time.Now().UTC().Add(24 * time.Hour)
		}
		if limit == 0 {
			limit = 100
		}
		if !expiry.After(time.Now()) || limit < 1 || limit > 1000000 {
			return errors.New("invalid expiry or use limit")
		}
		if in.Approval != "" && in.Approval != "ask" && in.Approval != "auto" {
			return errors.New("approval must be ask or auto")
		}
		if in.Attribution != "" && in.Attribution != "owner" && in.Attribution != "requester" {
			return errors.New("attribution must be owner or requester")
		}
		if in.BudgetTokens < 0 {
			return errors.New("invalid token budget")
		}
		next = append(next, actions.Grant{ID: grantID(resource, peer.User, action), Peer: peer.User, Resource: resource, Action: action, ExpiresAt: expiry, MaxUses: limit,
			Approval: in.Approval, BudgetTokens: in.BudgetTokens, Attribution: in.Attribution})
	}
	// Both sides apply the same per-action policy. Updating a different action
	// must preserve this capability's remaining uses and expiry.
	limits := []map[string]any{}
	for _, g := range next {
		if g.Resource == resource && g.Peer == peer.User {
			limits = append(limits, map[string]any{"action": g.Action, "expires_at": g.ExpiresAt, "max_uses": g.MaxUses})
		}
	}
	path := "/v1/grants/" + url.PathEscape(resource) + "/" + url.PathEscape(peer.Handle)
	persist := func() error {
		a.mu.Lock()
		defer a.mu.Unlock()
		if a.creds.Session.User != s.User {
			return errors.New("local identity changed")
		}
		updated := a.policy
		updated.Grants = next
		if e := save(a.policyPath(s.User), updated); e != nil {
			return e
		}
		a.policy = updated
		return nil
	}
	// The relay serializes this change against new execution claims. Persist
	// the matching device policy only after the relay acknowledges the edit.
	if len(limits) == 0 {
		if e := a.remote(ctx, s, "DELETE", path, nil, nil); e != nil {
			return e
		}
	} else if e := a.remote(ctx, s, "PUT", path, map[string]any{"limits": limits}, nil); e != nil {
		return e
	}
	return persist()
}
func (a *Agent) tray(ctx context.Context, verb string, in input) (any, error) {
	switch verb {
	case "status":
		return a.status(ctx)
	case "login":
		return a.startLogin(in.Handle, in.Invite)
	case "presence":
		return a.setPresenceMode(ctx, in.Presence)
	}
	a.edit.Lock()
	defer a.edit.Unlock()
	if verb == "logout" {
		return nil, a.signout(ctx)
	}
	s, e := a.getSession(ctx)
	if e != nil {
		return nil, e
	}
	switch verb {
	case "profile":
		body := map[string]any{}
		if in.Handle != "" {
			body["handle"] = in.Handle
		}
		for k, v := range map[string]*string{"displayName": in.DisplayName, "statusMessage": in.StatusMessage, "avatar": in.Avatar} {
			if v != nil {
				body[k] = *v
			}
		}
		if len(body) == 0 {
			return nil, errors.New("nothing to change")
		}
		return nil, a.remote(ctx, s, "PUT", "/v1/profile", body, nil)
	case "relay", "knowledge-share", "knowledge-install", "queue", "queue-add", "queue-merge":
		return a.teamVerb(ctx, s, verb, in)
	case "watch", "handover", "handback", "handovers", "review-post", "fanout":
		return a.liveVerb(ctx, s, verb, in)
	case "send", "sent", "handoffs", "thread", "comment", "apply-artifact":
		return a.requesterVerb(ctx, s, verb, in)
	case "approvals":
		return a.approvals(), nil
	case "approve", "deny":
		return nil, a.decide(ctx, nil, in.ID, verb == "approve", in.Reason)
	case "audit":
		return a.audit(in.Resource, in.Handle)
	case "avatar", "membership", "membership-set", "invite-create", "me":
		return a.socialVerb(ctx, s, verb, in)
	case "search", "request", "accept", "unfriend":
		handle := in.Handle
		if handle == "" {
			handle = in.ID
		}
		part, e := segment(handle)
		if e != nil {
			return nil, e
		}
		if verb == "search" {
			var u control.User
			e = a.remote(ctx, s, "GET", "/v1/users/"+part, nil, &u)
			return u, e
		}
		method := map[string]string{"request": "POST", "accept": "PUT", "unfriend": "DELETE"}[verb]
		return nil, a.remote(ctx, s, method, "/v1/friends/"+part, nil, nil)
	case "resource-add":
		id := in.ID
		if id == "" {
			id = newID()
		}
		r, e := actions.PrepareLocalResource(ctx, a.cfg.CommanderSocket, actions.Resource{ID: id, Name: in.Name, Kind: in.Kind, Target: in.Target})
		if e != nil {
			return nil, e
		}
		a.mu.Lock()
		old := slices.Clone(a.policy.Resources)
		a.mu.Unlock()
		i := slices.IndexFunc(old, func(v actions.Resource) bool { return v.ID == r.ID })
		if i >= 0 && r != old[i] {
			return nil, errors.New("resource id is already mapped to a different target")
		}
		if e = a.remote(ctx, s, "PUT", "/v1/resources/"+url.PathEscape(id), map[string]any{"kind": r.Kind, "name": r.Name, "actions": actions.ResourceCapabilities(r)}, nil); e != nil {
			return nil, e
		}
		if i < 0 {
			a.mu.Lock()
			next := a.policy
			next.Resources = append(slices.Clone(next.Resources), r)
			e = save(a.policyPath(s.User), next)
			if e == nil {
				a.policy = next
			}
			a.mu.Unlock()
		}
		return map[string]string{"id": id}, e
	case "grant", "revoke":
		return nil, a.grant(ctx, s, in, verb == "revoke")
	case "repo-credential":
		a.mu.Lock()
		defer a.mu.Unlock()
		if in.Token == "" || len(in.Token) > 8192 || strings.TrimSpace(in.Token) != in.Token {
			return nil, errors.New("invalid repository credential")
		}
		if !slices.ContainsFunc(a.policy.Resources, func(r actions.Resource) bool { return r.Kind == "repo" && r.ID == in.Resource }) {
			return nil, errors.New("unknown local repository")
		}
		next := a.creds
		next.Tokens = map[string]string{}
		for k, v := range a.creds.Tokens {
			next.Tokens[k] = v
		}
		next.Tokens[key(s.User+"|"+in.Resource)] = in.Token
		if e := a.persistCredentials(next); e != nil {
			return nil, e
		}
		a.creds = next
		return nil, nil
	default:
		return nil, errors.New("unknown tray operation")
	}
}
func proofCoordinator(ctx context.Context, socket string, h http.Header) error {
	for _, name := range []string{"Authorization", "X-Commander-Run", "X-Commander-Worker"} {
		if len(h.Values(name)) != 1 || strings.Contains(h.Get(name), ",") {
			return errors.New("expected exactly one coordinator credential")
		}
	}
	if socket == "" || !strings.HasPrefix(h.Get("Authorization"), "Bearer ") || h.Get("X-Commander-Run") == "" || h.Get("X-Commander-Worker") == "" {
		return errors.New("coordinator credential required")
	}
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socket)
	}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	req, e := http.NewRequestWithContext(ctx, "GET", "http://commander/v1/network/coordinator", nil)
	if e != nil {
		return e
	}
	for _, k := range []string{"Authorization", "X-Commander-Run", "X-Commander-Worker"} {
		req.Header.Set(k, h.Get(k))
	}
	resp, e := client.Do(req)
	if e != nil {
		return errors.New("local Commander unavailable")
	}
	defer resp.Body.Close()
	var actor struct{ Run, Worker string }
	if resp.StatusCode != 200 || json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&actor) != nil || actor.Run != h.Get("X-Commander-Run") || actor.Worker != h.Get("X-Commander-Worker") {
		return errors.New("coordinator identity denied")
	}
	return nil
}
func reply(w http.ResponseWriter, value any, e error) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if e != nil {
		w.WriteHeader(400)
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": e.Error()})
		return
	}
	if value == nil {
		value = struct{}{}
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "data": value})
}
func body(r *http.Request, v any) error {
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if e := d.Decode(v); e != nil {
		return errors.New("invalid request")
	}
	if e := d.Decode(new(any)); e != io.EOF {
		return errors.New("expected one JSON value")
	}
	return nil
}
func (a *Agent) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /tray/{verb}", func(w http.ResponseWriter, r *http.Request) {
		var in input
		r.Body = http.MaxBytesReader(w, r.Body, 32768)
		if e := body(r, &in); e != nil {
			reply(w, nil, e)
			return
		}
		res, e := a.tray(r.Context(), r.PathValue("verb"), in)
		reply(w, res, e)
	})
	mux.HandleFunc("POST /coordinator/{verb}", func(w http.ResponseWriter, r *http.Request) {
		if e := proofCoordinator(r.Context(), a.cfg.CommanderSocket, r.Header); e != nil {
			reply(w, nil, e)
			return
		}
		s, e := a.getSession(r.Context())
		if e != nil {
			reply(w, nil, e)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
		var res any
		var publicID string
		scope := func(id string) (string, error) {
			if _, err := segment(id); err != nil {
				return "", err
			}
			publicID = id
			return key(r.Header.Get("X-Commander-Run") + "\x00" + r.Header.Get("X-Commander-Worker") + "\x00" + id), nil
		}
		switch r.PathValue("verb") {
		case "inbox":
			var empty struct{}
			if e = body(r, &empty); e == nil {
				res, e = actions.CoordinatorInbox(a.localConfig(s), r.Header.Get("X-Commander-Worker"), r.Header.Get("X-Commander-Run"))
			}
		case "discover":
			var empty struct{}
			if e = body(r, &empty); e == nil {
				var rs []control.Resource
				rs, e = a.resources(r.Context(), s)
				if e == nil {
					rs = slices.DeleteFunc(rs, func(r control.Resource) bool { return r.Owner == s.User })
					contracts := make(map[string]actions.ActionContract)
					for _, resource := range rs {
						for _, action := range resource.Actions {
							if _, exists := contracts[action]; exists {
								continue
							}
							if contract, ok := actions.ContractFor(action); ok {
								contracts[action] = contract
							}
						}
					}
					res = map[string]any{"resources": rs, "actionContracts": contracts}
				}
			}
		case "online":
			var empty struct{}
			if e = body(r, &empty); e == nil {
				res, e = a.online(r.Context(), s)
			}
		case "thread":
			var in struct {
				Request string `json:"request"`
				Text    string `json:"text"`
			}
			if e = body(r, &in); e == nil {
				verb := "thread"
				if in.Text != "" {
					verb = "comment"
				}
				res, e = a.requesterVerb(r.Context(), s, verb, input{Request: in.Request, Text: in.Text})
			}
		case "submit":
			var in Submit
			if e = body(r, &in); e == nil {
				if in.ID, e = scope(in.ID); e == nil {
					res, e = a.submit(r.Context(), s, in)
				}
			}
		case "receipt":
			var in struct {
				ID string `json:"id"`
			}
			if e = body(r, &in); e == nil {
				if in.ID, e = scope(in.ID); e == nil {
					res, e = a.receipt(r.Context(), s, in.ID)
				}
			}
		default:
			e = fmt.Errorf("unknown coordinator operation")
		}
		if row, ok := res.(map[string]any); ok && publicID != "" {
			row["id"] = publicID
		}
		reply(w, res, e)
	})
	return mux
}

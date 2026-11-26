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
	ID            string                `json:"id"`
	Handle        string                `json:"handle"`
	Group         string                `json:"group"`
	Resource      string                `json:"resource"`
	Capability    string                `json:"capability"`
	Actions       []string              `json:"actions,omitempty"`
	Capabilities  *control.Capabilities `json:"capabilities,omitempty"`
	Name          string                `json:"name"`
	Kind          string                `json:"kind"`
	Target        string                `json:"target"`
	MaxUses       int                   `json:"maxUses"`
	ExpiresAt     time.Time             `json:"expiresAt"`
	Token         string                `json:"token"`
	Server        string                `json:"server"`
	DisplayName   *string               `json:"displayName"`
	StatusMessage *string               `json:"statusMessage"`
	Avatar        *string               `json:"avatar"`
	Presence      string                `json:"presence"`
	Mode          string                `json:"mode"`
	AllowedEmails []string              `json:"allowedEmails"`
	Admins        []string              `json:"admins"`
	TTLHours      int                   `json:"ttlHours"`
	Invite        string                `json:"invite"`
	Approval      string                `json:"approval"`
	BudgetTokens  int                   `json:"budgetTokens"`
	Attribution   string                `json:"attribution"`
	Peer          string                `json:"peer"`
	Reason        string                `json:"reason"`
	Payload       json.RawMessage       `json:"payload"`
	Request       string                `json:"request"`
	Handoff       string                `json:"handoff"`
	Text          string                `json:"text"`
	Checkout      string                `json:"checkout"`
	Artifact      int                   `json:"artifact"`
	Minutes       int                   `json:"minutes"`
	After         string                `json:"after"`
	PR            string                `json:"pr"`
	Targets       []Target              `json:"targets"`
	Method        string                `json:"method"`
	Path          string                `json:"path"`
	Body          json.RawMessage       `json:"body"`
	Workspace     string                `json:"workspace"`
	Goal          string                `json:"goal"`
	Repository    string                `json:"repository"`
	Base          string                `json:"base"`
	Integration   string                `json:"integration"`
	Key           string                `json:"key"`
	Holder        string                `json:"holder"`
	Claim         string                `json:"claim"`
	Branch        string                `json:"branch"`
	TestCommand   []string              `json:"testCommand"`
	Item          json.RawMessage       `json:"item"`
	Destination   string                `json:"destination"`
}
type trayGrant struct {
	ID           string    `json:"id"`
	Handle       string    `json:"handle"`
	Kind         string    `json:"kind"`
	Resource     string    `json:"resource"`
	Capability   string    `json:"capability"`
	ExpiresAt    time.Time `json:"expiresAt"`
	MaxUses      int       `json:"maxUses"`
	Approval     string    `json:"approval"`
	BudgetTokens int       `json:"budgetTokens"`
	Attribution  string    `json:"attribution"`
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
	result["displayName"], result["statusMessage"], result["hasAvatar"], result["presence"] = profile.DisplayName, profile.StatusMessage, profile.HasAvatar, profile.Presence
	a.mu.Lock()
	a.handle = profile.Handle
	a.mu.Unlock()
	var social struct{ Friends []Friend }
	if e = a.remote(ctx, s, "GET", "/v1/friends", nil, &social); e != nil {
		return nil, e
	}
	friends, incoming, outgoing := []map[string]any{}, []map[string]any{}, []map[string]any{}
	for _, f := range social.Friends {
		row := map[string]any{"id": f.Handle, "handle": f.Handle, "online": f.Online, "displayName": f.DisplayName, "statusMessage": f.StatusMessage, "presence": f.Presence, "hasAvatar": f.HasAvatar, "contactKey": f.ContactKey, "lastSeen": f.LastSeen, "requestedAt": f.RequestedAt}
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
	var catalog struct {
		Resources []control.Resource
		Directory json.RawMessage
	}
	if e := a.remote(ctx, s, "GET", "/v1/resources", nil, &catalog); e != nil {
		return nil, e
	}
	own, shared := []map[string]any{}, []map[string]any{}
	kind := map[string]string{}
	for _, r := range catalog.Resources {
		row := map[string]any{"id": r.ID, "kind": r.Kind, "name": r.Name, "actions": r.Actions, "owner": r.Handle, "device": r.Device, "endorsements": r.Endorsements}
		if r.Capabilities != nil {
			row["capabilities"] = r.Capabilities
		}
		kind[r.ID] = r.Kind
		if r.Device == s.Device && r.Owner == s.User {
			own = append(own, row)
		} else if r.Owner != s.User {
			shared = append(shared, row)
		}
	}
	result["resources"], result["shared"] = own, shared
	if len(catalog.Directory) > 0 {
		result["directory"] = catalog.Directory
	}
	grants, e := a.readGrants(ctx, s)
	if e != nil {
		return nil, e
	}
	rows := slices.Clone(grants.rows)
	for i := range rows {
		rows[i].Kind = kind[rows[i].Resource]
	}
	result["grants"] = rows
	return result, nil
}

type grantList struct {
	Grants []control.Grant
	rows   []trayGrant
}

func (a *Agent) readGrants(ctx context.Context, s identity.Session) (grantList, error) {
	// Serialize snapshots with edits so older membership cannot replace a newer mirror.
	a.grantReadMu.Lock()
	defer a.grantReadMu.Unlock()
	return a.refreshGrants(ctx, s)
}

// The caller holds grantReadMu.
func (a *Agent) refreshGrants(ctx context.Context, s identity.Session) (grantList, error) {
	var grants grantList
	if err := a.remote(ctx, s, "GET", "/v1/grants", nil, &grants); err != nil {
		return grants, err
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.creds.Session.User != s.User {
		return grants, errors.New("local identity changed")
	}
	byID := make(map[string]actions.Grant, len(a.policy.Grants))
	for _, entry := range a.policy.Grants {
		byID[entry.ID] = entry
	}
	grants.rows = []trayGrant{}
	for _, g := range grants.Grants {
		if g.Owner != s.User || g.Device != s.Device {
			continue
		}
		for _, cap := range g.Actions {
			id := grantID(g.Resource, g.Grantee, cap)
			entry, ok := byID[id]
			if !ok {
				entry = actions.Grant{MaxUses: int(g.MaxUses), ExpiresAt: g.ExpiresAt}
			}
			for _, l := range g.Limits {
				if l.Action != cap {
					continue
				}
				entry.MaxUses, entry.ExpiresAt = int(l.MaxUses), l.ExpiresAt
				// Relays that predate policy metadata omit both mode fields.
				if l.Approval != "" || l.Attribution != "" || l.BudgetTokens != 0 {
					entry.Approval, entry.BudgetTokens, entry.Attribution = l.Approval, int(l.BudgetTokens), l.Attribution
				}
				break
			}
			entry = grantDefaults(entry)
			grants.rows = append(grants.rows, trayGrant{ID: id, Handle: g.Handle, Resource: g.Resource, Capability: cap,
				ExpiresAt: entry.ExpiresAt.UTC(), MaxUses: entry.MaxUses, Approval: entry.Approval, BudgetTokens: entry.BudgetTokens, Attribution: entry.Attribution})
		}
	}
	mirrored := a.policy.mirrorGroupGrants(s, grants.Grants)
	if !slices.Equal(grants.rows, a.policy.Published) || !slices.Equal(mirrored, a.policy.Grants) {
		next := a.policy
		next.Published = grants.rows
		next.Grants = mirrored
		if err := save(a.policyPath(s.User), next); err != nil {
			return grants, err
		}
		a.policy = next
	}
	return grants, nil
}

// A relay confirms which peers belong to each group. Only locally enrolled
// group policies supply executable actions, limits and approval settings.
func (p localPolicy) mirrorGroupGrants(s identity.Session, rows []control.Grant) []actions.Grant {
	var result []actions.Grant
	previous := make(map[string]string)
	for _, g := range p.Grants {
		if g.Group == "" {
			result = append(result, g)
		} else {
			previous[g.ID] = g.UsageID
		}
	}
	for _, row := range rows {
		if row.Owner != s.User || row.Device != s.Device || row.Grantee == "" || row.Grantee == s.User {
			continue
		}
		for _, template := range p.GroupTemplates {
			if template.Resource != row.Resource || !slices.Contains(row.Sources[template.Group], template.Action) {
				continue
			}
			g := template
			g.Peer = row.Grantee
			g.ID = key(template.ID + "|" + row.Grantee)
			g.UsageID = previous[g.ID]
			if g.UsageID == "" {
				g.UsageID = newID()
			}
			result = append(result, g)
		}
	}
	return result
}

func grantDefaults(g actions.Grant) actions.Grant {
	if g.Approval == "" {
		g.Approval = "ask"
	}
	if g.Attribution == "" {
		g.Attribution = "owner"
	}
	return g
}
func grantID(resource, user, action string) string { return key(resource + "|" + user + "|" + action) }
func (a *Agent) grant(ctx context.Context, s identity.Session, in input, revoke bool) error {
	a.grantReadMu.Lock()
	defer a.grantReadMu.Unlock()
	var peer control.User
	published, err := a.refreshGrants(ctx, s)
	if err != nil {
		return err
	}
	resource := in.Resource
	action := in.Capability
	group := in.Group
	if group != "" && (!idPattern.MatchString(group) || in.Handle != "" || revoke) {
		return errors.New("provide one group or peer handle for the grant")
	}
	if revoke {
		for _, g := range published.Grants {
			if g.Owner != s.User || g.Device != s.Device {
				continue
			}
			for _, cap := range g.Actions {
				if grantID(g.Resource, g.Grantee, cap) == in.ID {
					if g.Sources != nil && !slices.Contains(g.Sources[""], cap) {
						return errors.New("this grant comes from a group; remove the member to withdraw access")
					}
					resource, action, peer = g.Resource, cap, control.User{User: g.Grantee, Handle: g.Handle}
				}
			}
		}
		if peer.User == "" {
			return nil
		}
	} else if group == "" {
		if !idPattern.MatchString(in.Handle) {
			return errors.New("invalid peer handle")
		}
		if e := a.remote(ctx, s, "GET", "/v1/users/"+url.PathEscape(in.Handle), nil, &peer); e != nil {
			return e
		}
	}
	a.mu.Lock()
	p := a.policy
	a.mu.Unlock()
	i := slices.IndexFunc(p.Resources, func(r actions.Resource) bool { return r.ID == resource })
	if resource == "" {
		return errors.New("provide a resource for the grant")
	}
	if i < 0 {
		return fmt.Errorf("no resource %s", resource)
	}
	if action == "" {
		return errors.New("provide a capability for the grant")
	}
	if !slices.Contains(actions.ResourceCapabilities(p.Resources[i]), action) {
		return fmt.Errorf("resource %s does not support %s", resource, action)
	}
	// The other user can end the friendship from a different device. Reconcile
	// with the relay before carrying any previously granted capability forward.
	var current []string
	for _, g := range published.Grants {
		if g.Owner == s.User && g.Device == s.Device && g.Grantee == peer.User && g.Resource == resource {
			current = g.Actions
			if g.Sources != nil {
				current = g.Sources[""]
			}
			break
		}
	}
	existing := p.Grants
	target, subject := peer.Handle, peer.User
	if group != "" {
		existing = p.GroupTemplates
		target = "group:" + group
		subject = target
	}
	next := []actions.Grant{}
	var usageID string
	for _, g := range existing {
		if g.Resource != resource || g.Peer != peer.User || g.Group != group {
			next = append(next, g)
			continue
		}
		if group == "" && !slices.Contains(current, g.Action) {
			continue
		}
		if g.Action == action {
			usageID = g.ReceiptKey()
		} else if g.ExpiresAt.After(time.Now()) {
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
		if usageID == "" {
			usageID = newID()
		}
		next = append(next, grantDefaults(actions.Grant{ID: grantID(resource, subject, action), UsageID: usageID, Peer: peer.User, Group: group, Resource: resource, Action: action, ExpiresAt: expiry, MaxUses: limit,
			Approval: in.Approval, BudgetTokens: in.BudgetTokens, Attribution: in.Attribution}))
	}
	// Both sides apply the same per-action policy. Updating a different action
	// must preserve this capability's remaining uses and expiry.
	var limits []control.Limit
	for _, g := range next {
		if g.Resource == resource && g.Peer == peer.User && g.Group == group {
			g = grantDefaults(g)
			limits = append(limits, control.Limit{Action: g.Action, ExpiresAt: g.ExpiresAt, MaxUses: int64(g.MaxUses),
				Approval: g.Approval, BudgetTokens: int64(g.BudgetTokens), Attribution: g.Attribution})
		}
	}
	path := "/v1/grants/" + url.PathEscape(resource) + "/" + url.PathEscape(target)
	persist := func() error {
		a.mu.Lock()
		defer a.mu.Unlock()
		if a.creds.Session.User != s.User {
			return errors.New("local identity changed")
		}
		updated := a.policy
		if group != "" {
			updated.GroupTemplates = next
			// Apply changed limits to existing members even if the next relay read fails.
			updated.Grants = updated.mirrorGroupGrants(s, published.Grants)
		} else {
			updated.Grants = next
		}
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
	if err := persist(); err != nil {
		return err
	}
	if group != "" {
		_, err = a.refreshGrants(ctx, s)
	}
	return err
}

func (a *Agent) publishResource(ctx context.Context, s identity.Session, in input, update bool) (any, error) {
	id := in.ID
	if update && id == "" {
		id = in.Resource
	}
	if id == "" {
		if update {
			return nil, errors.New("resource id required")
		}
		id = newID()
	}
	a.mu.Lock()
	resources := slices.Clone(a.policy.Resources)
	a.mu.Unlock()
	i := slices.IndexFunc(resources, func(v actions.Resource) bool { return v.ID == id })
	r := actions.Resource{ID: id, Name: in.Name, Kind: in.Kind, Target: in.Target, Capabilities: in.Capabilities}
	if update {
		if i < 0 {
			return nil, errors.New("unknown local resource")
		}
		r = resources[i]
		if in.Target != "" && in.Target != r.Target || in.Kind != "" && in.Kind != r.Kind {
			return nil, errors.New("resource id is already mapped to a different target")
		}
		if in.Name != "" {
			r.Name = in.Name
		}
		r.Capabilities = in.Capabilities.WithDefaults(r.Capabilities)
		if r.Kind == "host" {
			var err error
			if r, err = actions.PrepareResource(ctx, r); err != nil {
				return nil, err
			}
		}
		if r.Kind == "agent" && (r.Capabilities == nil || r.Capabilities.Harness == "" || r.Capabilities.Model == "") {
			// An enrolled target can be edited even while Commander is offline.
			if info, err := actions.PrepareLocalResource(ctx, a.cfg.CommanderSocket, r); err == nil {
				r.Capabilities = info.Capabilities
			}
		}
	} else {
		if i >= 0 {
			r.Capabilities = in.Capabilities.WithDefaults(resources[i].Capabilities)
		}
		var err error
		if r, err = actions.PrepareLocalResource(ctx, a.cfg.CommanderSocket, r); err != nil {
			return nil, err
		}
		if i >= 0 {
			old := resources[i]
			old.Capabilities = r.Capabilities
			if r != old {
				return nil, errors.New("resource id is already mapped to a different target")
			}
		}
	}
	if i < 0 {
		resources = append(resources, r)
	} else {
		resources[i] = r
	}
	body := map[string]any{"kind": r.Kind, "name": r.Name, "actions": actions.ResourceCapabilities(r)}
	if r.Capabilities != nil {
		body["capabilities"] = r.Capabilities
	}
	if err := a.remote(ctx, s, "PUT", "/v1/resources/"+url.PathEscape(id), body, nil); err != nil {
		return nil, err
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.creds.Session.User != s.User {
		return nil, errors.New("local identity changed")
	}
	next := a.policy
	next.Resources = resources
	if err := save(a.policyPath(s.User), next); err != nil {
		return nil, err
	}
	a.policy = next
	return map[string]string{"id": id}, nil
}

func (a *Agent) tray(ctx context.Context, verb string, in input) (any, error) {
	if in.Actions != nil {
		// Grant callers can also use the relay's actions array. The tray
		// edits one capability and its limits at a time.
		if verb != "grant" {
			return nil, errors.New("the actions field is only accepted for a grant")
		}
		if len(in.Actions) != 1 || in.Actions[0] == "" || in.Capability != "" {
			return nil, errors.New("provide one grant action using either capability or actions")
		}
		in.Capability = in.Actions[0]
	}
	switch verb {
	case "status":
		return a.status(ctx)
	case "login":
		return a.startLogin(in.Handle, in.Invite)
	case "presence":
		return a.setPresenceMode(ctx, in.Presence)
	case "relay":
		if publicInfoRoute(in.Method, in.Path) {
			return a.teamRelay(ctx, identity.Session{}, in.Method, in.Path, in.Body)
		}
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
	case "relay", "knowledge-share", "knowledge-install", "queue", "queue-add", "queue-merge", "queue-remove", "workspace-prs":
		return a.teamVerb(ctx, s, verb, in)
	case "groups", "group-create", "group-add", "group-remove", "group-delete", "workspaces", "workspace-create", "claim", "release", "knowledge":
		return a.namedTeamRelay(ctx, s, verb, in)
	case "watch", "handover", "handback", "handovers", "review-post", "fanout":
		return a.liveVerb(ctx, s, verb, in)
	case "send", "sent", "handoffs", "thread", "comment", "apply-artifact":
		return a.requesterVerb(ctx, s, verb, in)
	case "approvals":
		return a.approvals(ctx, s), nil
	case "approve":
		return nil, a.resolve(ctx, in.ID, "", "")
	case "deny":
		return nil, a.resolve(ctx, in.ID, "denied", in.Reason)
	case "audit":
		peer := in.Peer
		if peer == "" {
			peer = in.Handle
		}
		return a.audit(ctx, s, in.Resource, peer)
	case "avatar", "membership", "membership-set", "invite-create", "me":
		return a.socialVerb(ctx, s, verb, in)
	case "search", "request", "accept", "unfriend", "decline":
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
		// decline refuses an incoming request; the relay deletes the pending pair either way.
		method := map[string]string{"request": "POST", "accept": "PUT", "unfriend": "DELETE", "decline": "DELETE"}[verb]
		return nil, a.remote(ctx, s, method, "/v1/friends/"+part, nil, nil)
	case "resource-add", "resource-update":
		return a.publishResource(ctx, s, in, verb == "resource-update")
	case "grant", "revoke":
		err := a.grant(ctx, s, in, verb == "revoke")
		if in.Group != "" {
			err = teamRefusal(err)
		}
		return nil, err
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
		r.Body = http.MaxBytesReader(w, r.Body, 196608)
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
		case "board":
			var in boardInput
			if e = body(r, &in); e == nil {
				res, e = a.board(r.Context(), s, r.Header.Get("X-Commander-Worker"), in)
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

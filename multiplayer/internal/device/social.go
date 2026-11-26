package device

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"agentcommander.network/pilot/internal/identity"
)

// Friend is a relay user as the friends list reports it.
type Friend struct {
	User          string `json:"user"`
	Handle        string `json:"handle"`
	Online        bool   `json:"online"`
	Status        string `json:"status,omitempty"`
	DisplayName   string `json:"displayName,omitempty"`
	StatusMessage string `json:"statusMessage,omitempty"`
	Presence      string `json:"presence,omitempty"`
	LastSeen      string `json:"lastSeen,omitempty"`
	HasAvatar     bool   `json:"hasAvatar,omitempty"`
	ContactKey    string `json:"contactKey,omitempty"`
}

// Event is one relay activity event.
type Event struct {
	Server   string    `json:"server,omitempty"`
	Seq      int64     `json:"seq"`
	At       time.Time `json:"at"`
	Kind     string    `json:"kind"`
	Actor    string    `json:"actor"`
	Resource string    `json:"resource,omitempty"`
	Detail   string    `json:"detail,omitempty"`
}

type socialState struct {
	PresenceMode string  `json:"presenceMode"` // auto or a fixed presence
	Pushed       string  `json:"pushed"`       // last presence sent to the relay
	Events       []Event `json:"events"`
	After        int64   `json:"after"`
	Seen         int64   `json:"seen"`
}

const keepEvents = 500

var presences = map[string]bool{"online": true, "away": true, "busy": true, "dnd": true}

func (a *Agent) socialPath() string { return filepath.Join(a.cfg.Dir, "social.json") }

func (a *Agent) loadSocial() {
	b, e := os.ReadFile(a.socialPath())
	if e == nil {
		_ = json.Unmarshal(b, &a.social)
	}
	if a.social.PresenceMode == "" {
		a.social.PresenceMode = "auto"
	}
}

// saveSocial must be called with a.mu held.
func (a *Agent) saveSocial() error { return save(a.socialPath(), a.social) }

func (a *Agent) setPresenceMode(ctx context.Context, mode string) (any, error) {
	if mode != "auto" && !presences[mode] {
		return nil, errors.New("presence must be auto, online, away, busy or dnd")
	}
	a.mu.Lock()
	a.social.PresenceMode = mode
	e := a.saveSocial()
	a.mu.Unlock()
	if e != nil {
		return nil, e
	}
	if mode != "auto" {
		if e = a.pushPresence(ctx, mode); e != nil {
			return nil, e
		}
	}
	return map[string]any{"presence": mode, "auto": mode == "auto"}, nil
}

// pushPresence sends a presence to the relay when it changed.
func (a *Agent) pushPresence(ctx context.Context, p string) error {
	a.mu.Lock()
	same := a.social.Pushed == p
	a.mu.Unlock()
	if same {
		return nil
	}
	s, e := a.getSession(ctx)
	if e != nil {
		return e
	}
	if e = a.remote(ctx, s, "PUT", "/v1/profile", map[string]string{"presence": p}, nil); e != nil {
		return e
	}
	a.mu.Lock()
	a.social.Pushed = p
	e = a.saveSocial()
	a.mu.Unlock()
	return e
}

func (a *Agent) presenceMode() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.social.PresenceMode
}

func (a *Agent) eventsLoop() {
	for a.ctx.Err() == nil {
		a.pollEvents(a.ctx)
		if !wait(a.ctx, 15*time.Second) {
			return
		}
	}
}

func (a *Agent) pollEvents(ctx context.Context) {
	a.mu.Lock()
	signed := a.creds.Session.User != ""
	after := a.social.After
	a.mu.Unlock()
	if !signed {
		return
	}
	s, e := a.getSession(ctx)
	if e != nil {
		return
	}
	var res struct{ Events []Event }
	if e = a.remote(ctx, s, "GET", "/v1/events?limit=200&after="+strconv.FormatInt(after, 10), nil, &res); e != nil || len(res.Events) == 0 {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, ev := range res.Events {
		if ev.Seq > a.social.After {
			a.social.Events = append(a.social.Events, ev)
			a.social.After = ev.Seq
		}
	}
	if n := len(a.social.Events); n > keepEvents {
		a.social.Events = slices.Clone(a.social.Events[n-keepEvents:])
	}
	_ = a.saveSocial()
}

func (a *Agent) unseen() int {
	n := 0
	for _, ev := range a.social.Events {
		if ev.Seq > a.social.Seen {
			n++
		}
	}
	return n
}

func (a *Agent) socialVerb(ctx context.Context, s identity.Session, verb string, in input) (any, error) {
	switch verb {
	case "avatar":
		part, e := segment(in.Handle)
		if e != nil {
			return nil, e
		}
		return a.avatar(ctx, s, part)
	case "me":
		var me map[string]any
		return me, a.remote(ctx, s, "GET", "/v1/me", nil, &me)
	case "membership":
		var m map[string]any
		return m, a.remote(ctx, s, "GET", "/v1/admin/membership", nil, &m)
	case "membership-set":
		if in.Mode == "" {
			return nil, errors.New("choose a membership mode")
		}
		var m map[string]any
		body := map[string]any{"mode": in.Mode, "allowedEmails": nonNil(in.AllowedEmails), "admins": nonNil(in.Admins)}
		return m, a.remote(ctx, s, "PUT", "/v1/admin/membership", body, &m)
	case "invite-create":
		uses, ttl := in.MaxUses, in.TTLHours
		if uses <= 0 {
			uses = 5
		}
		if ttl <= 0 {
			ttl = 168
		}
		var inv struct {
			Code      string    `json:"code"`
			ExpiresAt time.Time `json:"expiresAt"`
			MaxUses   int       `json:"maxUses"`
		}
		if e := a.remote(ctx, s, "POST", "/v1/invites", map[string]int{"maxUses": uses, "ttlHours": ttl}, &inv); e != nil {
			return nil, e
		}
		a.mu.Lock()
		from := a.handle
		a.mu.Unlock()
		return map[string]any{"link": InviteLink(a.cfg.Relay, a.cfg.Pin, inv.Code, from), "code": inv.Code, "expiresAt": inv.ExpiresAt, "maxUses": inv.MaxUses}, nil
	}
	return nil, fmt.Errorf("unknown operation")
}

func nonNil(v []string) []string {
	if v == nil {
		return []string{}
	}
	return v
}

func (a *Agent) avatar(ctx context.Context, s identity.Session, handle string) (any, error) {
	req, e := http.NewRequestWithContext(ctx, "GET", a.cfg.Relay+"/v1/users/"+handle+"/avatar", nil)
	if e != nil {
		return nil, e
	}
	req.Header.Set("Authorization", "Bearer "+s.AccessToken)
	resp, e := a.http.Do(req)
	if e != nil {
		return nil, e
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, statusError{resp.StatusCode, "no avatar"}
	}
	b, e := io.ReadAll(io.LimitReader(resp.Body, 65<<10))
	if e != nil {
		return nil, e
	}
	return map[string]string{"contentType": resp.Header.Get("Content-Type"), "data": base64.StdEncoding.EncodeToString(b)}, nil
}

// InviteLink builds agentcommander://join?server=…&pin=…&code=…&from=….
func InviteLink(server, pin, code, from string) string {
	q := url.Values{}
	q.Set("server", server)
	q.Set("pin", pin)
	q.Set("code", code)
	if from != "" {
		q.Set("from", from)
	}
	return "agentcommander://join?" + q.Encode()
}

// Invite is a parsed invite link.
type Invite struct{ Server, Pin, Code, From string }

// ParseInvite reads an agentcommander://join link.
func ParseInvite(link string) (Invite, error) {
	u, e := url.Parse(strings.TrimSpace(link))
	if e != nil || u.Scheme != "agentcommander" || (u.Host != "join" && u.Opaque != "join" && strings.Trim(u.Path, "/") != "join") {
		return Invite{}, errors.New("not an Agent Commander invite link")
	}
	q := u.Query()
	server, e := NormalizeRelay(q.Get("server"))
	if e != nil {
		return Invite{}, e
	}
	inv := Invite{Server: server, Pin: q.Get("pin"), Code: q.Get("code"), From: q.Get("from")}
	if inv.Pin != "" && !strings.HasPrefix(inv.Pin, "sha256/") {
		return Invite{}, errors.New("invalid certificate pin in invite")
	}
	return inv, nil
}

// Contact is one person, possibly on several servers.
type Contact struct {
	ContactKey  string       `json:"contactKey"`
	DisplayName string       `json:"displayName"`
	Rows        []ContactRow `json:"rows"`
}

// ContactRow is a contact's presence on one server.
type ContactRow struct {
	Server        string `json:"server"`
	Handle        string `json:"handle"`
	Presence      string `json:"presence"`
	Online        bool   `json:"online"`
	StatusMessage string `json:"statusMessage"`
	HasAvatar     bool   `json:"hasAvatar"`
}

func (m *Manager) contacts(ctx context.Context) (any, error) {
	type target struct {
		id string
		a  *Agent
	}
	var targets []target
	for _, s := range m.Summaries() {
		m.mu.Lock()
		a := m.agents[s.ID]
		m.mu.Unlock()
		if a != nil && s.SignedIn {
			targets = append(targets, target{s.ID, a})
		}
	}
	byKey := map[string]int{}
	out := []Contact{}
	for _, t := range targets {
		sess, e := t.a.getSession(ctx)
		if e != nil {
			continue
		}
		var res struct{ Friends []Friend }
		if t.a.remote(ctx, sess, "GET", "/v1/friends", nil, &res) != nil {
			continue
		}
		for _, f := range res.Friends {
			if f.Status != "accepted" {
				continue
			}
			p := f.Presence
			if p == "" {
				p = map[bool]string{true: "online", false: "offline"}[f.Online]
			}
			row := ContactRow{Server: t.id, Handle: f.Handle, Presence: p, Online: f.Online, StatusMessage: f.StatusMessage, HasAvatar: f.HasAvatar}
			name := f.DisplayName
			if name == "" {
				name = f.Handle
			}
			if i, ok := byKey[f.ContactKey]; ok && f.ContactKey != "" {
				out[i].Rows = append(out[i].Rows, row)
				continue
			}
			if f.ContactKey != "" {
				byKey[f.ContactKey] = len(out)
			}
			out = append(out, Contact{ContactKey: f.ContactKey, DisplayName: name, Rows: []ContactRow{row}})
		}
	}
	return map[string]any{"contacts": out}, nil
}

func (m *Manager) activity() any {
	m.mu.Lock()
	defer m.mu.Unlock()
	var all []Event
	cursor := map[string]int64{}
	unseen := 0
	for id, a := range m.agents {
		a.mu.Lock()
		for _, ev := range a.social.Events {
			ev.Server = id
			all = append(all, ev)
		}
		cursor[id] = a.social.After
		unseen += a.unseen()
		a.mu.Unlock()
	}
	slices.SortFunc(all, func(x, y Event) int { return y.At.Compare(x.At) })
	if all == nil {
		all = []Event{}
	}
	c, _ := json.Marshal(cursor)
	return map[string]any{"events": all, "cursor": base64.RawURLEncoding.EncodeToString(c), "unseen": unseen}
}

func (m *Manager) activitySeen(cursor string) error {
	raw, e := base64.RawURLEncoding.DecodeString(cursor)
	var seen map[string]int64
	if e != nil || json.Unmarshal(raw, &seen) != nil {
		return errors.New("invalid activity cursor")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	for id, seq := range seen {
		if a := m.agents[id]; a != nil {
			a.mu.Lock()
			if seq > a.social.Seen {
				a.social.Seen = seq
				_ = a.saveSocial()
			}
			a.mu.Unlock()
		}
	}
	return nil
}

// join adds the server from an invite link and starts sign-in with its code.
func (m *Manager) join(ctx context.Context, link string) (any, error) {
	inv, e := ParseInvite(link)
	if e != nil {
		return nil, e
	}
	m.mu.Lock()
	i := slices.IndexFunc(m.servers, func(s Server) bool { return s.URL == inv.Server })
	m.mu.Unlock()
	var sum ServerSummary
	if i < 0 {
		res, e := m.serverVerb(ctx, "server-add", serverInput{URL: inv.Server, Pin: inv.Pin})
		if e != nil {
			return nil, e
		}
		sum = res.(ServerSummary)
	} else {
		m.mu.Lock()
		sum = m.summary(m.servers[i])
		m.mu.Unlock()
	}
	a, e := m.agentFor(sum.ID)
	if e != nil {
		return nil, e
	}
	if !sum.SignedIn {
		if _, e = a.startLogin("", inv.Code); e != nil {
			return nil, e
		}
	}
	if inv.From != "" {
		if part, err := segment(inv.From); err == nil {
			go func() {
				ctx, cancel := context.WithTimeout(a.ctx, 6*time.Minute)
				defer cancel()
				for ctx.Err() == nil {
					if s, err := a.getSession(ctx); err == nil {
						_ = a.remote(ctx, s, "POST", "/v1/friends/"+part, nil, nil)
						return
					}
					if !wait(ctx, 2*time.Second) {
						return
					}
				}
			}()
		}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if j := m.find(sum.ID); j >= 0 {
		return m.summary(m.servers[j]), nil
	}
	return sum, nil
}

// Automatic presence.

var idlePattern = regexp.MustCompile(`"HIDIdleTime" = (\d+)`)

// IdleTime reports how long the Mac has had no keyboard or mouse input.
func IdleTime() (time.Duration, error) {
	out, e := exec.Command("/usr/sbin/ioreg", "-c", "IOHIDSystem", "-d", "4").Output()
	if e != nil {
		return 0, e
	}
	m := idlePattern.FindSubmatch(out)
	if m == nil {
		return 0, errors.New("no HIDIdleTime")
	}
	ns, e := strconv.ParseInt(string(m[1]), 10, 64)
	return time.Duration(ns), e
}

var idleStates = map[string]bool{"": true, "idle": true, "ready": true, "waiting": true, "done": true, "finished": true, "stopped": true, "failed": true, "exited": true, "cancelled": true, "completed": true}

// agentsBusy asks the local Commander service whether any worker is running.
func agentsBusy(ctx context.Context, socket string) bool {
	client := &http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socket)
	}}}
	defer client.CloseIdleConnections()
	req, _ := http.NewRequestWithContext(ctx, "GET", "http://commander/v1/runs", nil)
	resp, e := client.Do(req)
	if e != nil {
		return false
	}
	defer resp.Body.Close()
	var res struct {
		Runs []struct {
			Status  string
			Workers []struct{ State string }
		}
	}
	if json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&res) != nil {
		return false
	}
	for _, r := range res.Runs {
		if r.Status != "running" {
			continue
		}
		for _, w := range r.Workers {
			if !idleStates[w.State] {
				return true
			}
		}
	}
	return false
}

// AutoPresence computes the automatic presence.
func AutoPresence(busy bool, idle time.Duration) string {
	switch {
	case busy:
		return "busy"
	case idle >= 10*time.Minute:
		return "away"
	}
	return "online"
}

func (m *Manager) presenceLoop() {
	for m.ctx.Err() == nil {
		idle, _ := IdleTime()
		want := AutoPresence(agentsBusy(m.ctx, m.cfg.CommanderSocket), idle)
		m.mu.Lock()
		agents := make([]*Agent, 0, len(m.agents))
		for _, a := range m.agents {
			agents = append(agents, a)
		}
		m.mu.Unlock()
		for _, a := range agents {
			if a.presenceMode() == "auto" {
				ctx, cancel := context.WithTimeout(m.ctx, 10*time.Second)
				_ = a.pushPresence(ctx, want)
				cancel()
			}
		}
		if !wait(m.ctx, 30*time.Second) {
			return
		}
	}
}

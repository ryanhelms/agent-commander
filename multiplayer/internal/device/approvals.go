package device

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"time"

	"agentcommander.network/pilot/internal/actions"
	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/devicekeys"
	"agentcommander.network/pilot/internal/identity"
)

// maxApprovalWait bounds how long a request waits for the owner.
const maxApprovalWait = 24 * time.Hour

type claimedRequest struct {
	child   control.Child
	payload []byte
	peer    devicekeys.Public
	arrived time.Time
	timer   *time.Timer
}

// Approval is a request waiting for the owner, as the tray shows it.
type Approval struct {
	ID       string    `json:"id"`
	Server   string    `json:"server"`
	Handle   string    `json:"handle"`
	Friend   string    `json:"friend"`
	Peer     string    `json:"peer"`
	Resource string    `json:"resource"`
	Action   string    `json:"action"`
	Summary  string    `json:"summary"`
	Arrived  time.Time `json:"arrived"`
	Expires  time.Time `json:"expires"`
}

// AuditEntry records one executed, denied or expired request.
type AuditEntry struct {
	Recipient  string    `json:"recipient,omitempty"`
	Unverified bool      `json:"unverified,omitempty"`
	Request    string    `json:"request"`
	Peer       string    `json:"peer"`
	Resource   string    `json:"resource"`
	Action     string    `json:"action"`
	Started    time.Time `json:"started"`
	Ended      time.Time `json:"ended"`
	Outcome    string    `json:"outcome"`
	Tokens     int       `json:"tokens"`
	Summary    string    `json:"summary"`
}

func (a *Agent) needsApproval(c control.Child) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if actions.IsFollowUp(c.Action) {
		return false
	}
	if until, ok := a.handovers[c.Sender+"|"+c.Resource]; ok && time.Now().Before(until) && c.Action == "agent.ask" {
		return false
	}
	if c.Action == "agent.suggest" {
		return true
	}
	for _, g := range a.policy.Grants {
		if g.Peer == c.Sender && g.Resource == c.Resource && g.Action == c.Action {
			return g.Approval != "auto"
		}
	}
	return false
}

func (a *Agent) queueApproval(p claimedRequest) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.pending == nil {
		a.pending = map[string]claimedRequest{}
	}
	id := p.child.ID
	p.timer = time.AfterFunc(time.Until(approvalDeadline(p.child, p.arrived)), func() {
		ctx, cancel := context.WithTimeout(a.ctx, 30*time.Second)
		defer cancel()
		_ = a.resolve(ctx, id, "expired", "")
	})
	a.pending[id] = p
	a.social.Events = append(a.social.Events, Event{At: p.arrived, Kind: "approval.pending", Actor: p.child.Sender, Resource: p.child.Resource, Detail: p.child.Action})
}

func approvalDeadline(c control.Child, arrived time.Time) time.Time {
	d := arrived.Add(maxApprovalWait)
	if !c.ExpiresAt.IsZero() && c.ExpiresAt.Before(d) {
		d = c.ExpiresAt
	}
	return d
}

func (a *Agent) friendHandles(ctx context.Context, s identity.Session) map[string]string {
	var social struct{ Friends []Friend }
	handles := map[string]string{}
	if a.remote(ctx, s, "GET", "/v1/friends", nil, &social) == nil {
		for _, f := range social.Friends {
			handles[f.User] = f.Handle
		}
	}
	return handles
}

func (a *Agent) approvals(ctx context.Context, s identity.Session) map[string]any {
	a.mu.Lock()
	list := []Approval{}
	for id, p := range a.pending {
		if p.child.Owner == s.User {
			list = append(list, Approval{ID: id, Server: a.cfg.ServerID, Peer: p.child.Sender, Resource: p.child.Resource, Action: p.child.Action, Summary: summarize(p.payload), Arrived: p.arrived, Expires: approvalDeadline(p.child, p.arrived)})
		}
	}
	a.mu.Unlock()
	if len(list) != 0 {
		handles := a.friendHandles(ctx, s)
		for i := range list {
			list[i].Friend = handles[list[i].Peer]
			list[i].Handle = list[i].Friend
		}
	}
	slices.SortFunc(list, func(x, y Approval) int { return x.Arrived.Compare(y.Arrived) })
	return map[string]any{"approvals": list}
}

func (a *Agent) resolve(ctx context.Context, id, denial, reason string) error {
	s, err := a.getSession(ctx)
	if err != nil {
		return err
	}
	a.mu.Lock()
	p, ok := a.pending[id]
	if !ok || p.child.Owner != s.User {
		a.mu.Unlock()
		return errors.New("no such pending request")
	}
	delete(a.pending, id)
	if p.timer != nil {
		p.timer.Stop()
	}
	l := a.lease
	a.mu.Unlock()

	if !time.Now().Before(approvalDeadline(p.child, p.arrived)) {
		denial, reason = "expired", ""
	}
	return a.finish(ctx, s, l, p, nil, denial, reason)
}

func summarize(b []byte) string {
	s := string(b)
	if len(s) > 240 {
		s = s[:240] + "…"
	}
	return s
}

func (a *Agent) auditPath() string { return filepath.Join(a.cfg.Dir, "audit.jsonl") }

func (a *Agent) record(e AuditEntry) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	f, err := os.OpenFile(a.auditPath(), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	return json.NewEncoder(f).Encode(e)
}

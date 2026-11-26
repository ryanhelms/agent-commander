package device

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"time"

	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/devicekeys"
)

// maxApprovalWait bounds how long a request waits for the owner.
const maxApprovalWait = 24 * time.Hour

type pendingApproval struct {
	child   control.Child
	payload []byte
	peer    devicekeys.Public
	arrived time.Time
}

// Approval is a request waiting for the owner, as the tray shows it.
type Approval struct {
	ID       string    `json:"id"`
	Peer     string    `json:"peer"`
	Resource string    `json:"resource"`
	Action   string    `json:"action"`
	Summary  string    `json:"summary"`
	Arrived  time.Time `json:"arrived"`
	Expires  time.Time `json:"expires"`
}

// AuditEntry records one executed, denied or expired request.
type AuditEntry struct {
	Request  string    `json:"request"`
	Peer     string    `json:"peer"`
	Resource string    `json:"resource"`
	Action   string    `json:"action"`
	Started  time.Time `json:"started"`
	Ended    time.Time `json:"ended"`
	Outcome  string    `json:"outcome"`
	Tokens   int       `json:"tokens"`
	Summary  string    `json:"summary"`
}

func (a *Agent) needsApproval(c control.Child) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if until, ok := a.handovers[c.Sender+"|"+c.Resource]; ok && time.Now().Before(until) && (c.Action == "agent.suggest" || c.Action == "agent.ask") {
		return false
	}
	if c.Action == "agent.suggest" {
		return true
	}
	for _, g := range a.policy.Grants {
		if g.Peer == c.Sender && g.Resource == c.Resource && g.Action == c.Action {
			return g.Approval == "ask"
		}
	}
	return false
}

func (a *Agent) queueApproval(c control.Child, payload []byte, peer devicekeys.Public) {
	a.mu.Lock()
	if a.pending == nil {
		a.pending = map[string]pendingApproval{}
	}
	a.pending[c.ID] = pendingApproval{c, payload, peer, time.Now()}
	a.social.Events = append(a.social.Events, Event{Seq: 0, At: time.Now().UTC(), Kind: "approval.pending", Actor: c.Sender, Resource: c.Resource, Detail: c.Action})
	a.mu.Unlock()
	time.AfterFunc(time.Until(approvalDeadline(c, time.Now())), func() {
		ctx, cancel := context.WithTimeout(a.ctx, 30*time.Second)
		defer cancel()
		_ = a.resolve(ctx, c.ID, false, "expired")
	})
}

func approvalDeadline(c control.Child, arrived time.Time) time.Time {
	d := arrived.Add(maxApprovalWait)
	if !c.ExpiresAt.IsZero() && c.ExpiresAt.Before(d) {
		d = c.ExpiresAt.Add(-5 * time.Second)
	}
	return d
}

func (a *Agent) approvals() map[string]any {
	a.mu.Lock()
	defer a.mu.Unlock()
	handles := map[string]string{}
	list := []Approval{}
	for id, p := range a.pending {
		_ = handles
		list = append(list, Approval{ID: id, Peer: p.child.Sender, Resource: p.child.Resource, Action: p.child.Action, Summary: summarize(p.payload), Arrived: p.arrived, Expires: approvalDeadline(p.child, p.arrived)})
	}
	slices.SortFunc(list, func(x, y Approval) int { return x.Arrived.Compare(y.Arrived) })
	return map[string]any{"approvals": list}
}

func (a *Agent) decide(ctx context.Context, _ any, id string, approve bool, reason string) error {
	code := ""
	if !approve {
		code = "denied"
	}
	return a.resolve(ctx, id, approve, code)
}

func (a *Agent) resolve(ctx context.Context, id string, approve bool, denial string) error {
	a.mu.Lock()
	p, ok := a.pending[id]
	if ok {
		delete(a.pending, id)
	}
	l := a.lease
	a.mu.Unlock()
	if !ok {
		return errors.New("no such pending request")
	}
	s, e := a.getSession(ctx)
	if e != nil {
		return e
	}
	if approve {
		denial = ""
	}
	return a.finish(ctx, s, l, p.child, p.payload, p.peer, nil, denial)
}

func summarize(b []byte) string {
	s := string(b)
	if len(s) > 240 {
		s = s[:240] + "…"
	}
	return s
}

func (a *Agent) auditPath() string { return filepath.Join(a.cfg.Dir, "audit.jsonl") }

func (a *Agent) record(e AuditEntry) {
	a.mu.Lock()
	defer a.mu.Unlock()
	f, err := os.OpenFile(a.auditPath(), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return
	}
	defer f.Close()
	b, _ := json.Marshal(e)
	_, _ = f.Write(append(b, '\n'))
}

func (a *Agent) audit(resource, peer string) (any, error) {
	f, err := os.Open(a.auditPath())
	if errors.Is(err, os.ErrNotExist) {
		return map[string]any{"entries": []AuditEntry{}}, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var all []AuditEntry
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		var e AuditEntry
		if json.Unmarshal(sc.Bytes(), &e) != nil {
			continue
		}
		if (resource == "" || e.Resource == resource) && (peer == "" || e.Peer == peer) {
			all = append(all, e)
		}
	}
	slices.Reverse(all)
	if len(all) > 200 {
		all = all[:200]
	}
	if all == nil {
		all = []AuditEntry{}
	}
	return map[string]any{"entries": all}, nil
}

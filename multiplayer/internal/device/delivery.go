package device

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"time"

	"agentcommander.network/pilot/internal/actions"
	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/devicekeys"
	"agentcommander.network/pilot/internal/identity"
)

var idPattern = regexp.MustCompile("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")

func segment(id string) (string, error) {
	if !idPattern.MatchString(id) {
		return "", errors.New("invalid identifier")
	}
	return url.PathEscape(id), nil
}
func proof(l control.Lease) map[string]any {
	return map[string]any{"session": l.Session, "generation": l.Generation}
}
func newID() string { var b [16]byte; rand.Read(b[:]); return hex.EncodeToString(b[:]) }

type Target struct {
	Resource string          `json:"resource"`
	Action   string          `json:"action"`
	Payload  json.RawMessage `json:"payload"`
}
type Submit struct {
	ID      string   `json:"id"`
	Targets []Target `json:"targets"`
}
type outbound struct {
	ID       string              `json:"id"`
	Children []control.Addressed `json:"children"`
}
type sendRecord struct {
	Digest          string
	Wire            outbound
	Audit           []AuditEntry                             `json:"audit,omitempty"`
	BuildChallenges map[string]actions.DesktopBuildChallenge `json:"buildChallenges,omitempty"`
}

func (a *Agent) submit(ctx context.Context, s identity.Session, in Submit) (any, error) {
	if !idPattern.MatchString(in.ID) || len(in.Targets) < 1 || len(in.Targets) > 32 {
		return nil, errors.New("supply a stable id and 1–32 targets")
	}
	a.sendMu.Lock()
	defer a.sendMu.Unlock()
	dir := filepath.Join(a.cfg.Dir, key(s.User), "submissions")
	if e := privateDir(dir); e != nil {
		return nil, e
	}
	path := filepath.Join(dir, key(in.ID)+".json")
	var record sendRecord
	intent, e := json.Marshal(in)
	if e != nil {
		return nil, e
	}
	digest := key(string(intent))
	data, e := os.ReadFile(path)
	switch {
	case e == nil:
		if e = json.Unmarshal(data, &record); e != nil {
			return nil, e
		}
		if record.Digest != digest {
			return nil, errors.New("submission id already binds a different intent")
		}
	case errors.Is(e, os.ErrNotExist):
		resources, e := a.resources(ctx, s)
		if e != nil {
			return nil, e
		}
		record = sendRecord{Digest: digest, Wire: outbound{ID: in.ID}}
		started := time.Now().UTC()
		for _, t := range in.Targets {
			expiry := started.Add(maxApprovalWait).Truncate(time.Microsecond)
			i := slices.IndexFunc(resources, func(r control.Resource) bool {
				return r.ID == t.Resource && r.Owner != s.User && slices.Contains(r.Actions, t.Action)
			})
			if i < 0 {
				return nil, errors.New("requested shared resource or capability unavailable")
			}
			r := resources[i]
			p, e := a.pin(ctx, s, r.Owner, r.Device)
			if e != nil {
				return nil, e
			}
			id := newID()
			if t.Action == "app.build" {
				challenge, err := actions.ParseDesktopBuildChallenge(t.Payload)
				if err != nil {
					return nil, err
				}
				now := time.Now().UTC()
				expiry = challenge.ExpiresAt().Truncate(time.Microsecond)
				if !challenge.FreshAt(now) || !expiry.After(now) {
					return nil, actions.ErrBuildRequestExpired
				}
				if record.BuildChallenges == nil {
					record.BuildChallenges = make(map[string]actions.DesktopBuildChallenge)
				}
				record.BuildChallenges[id] = challenge
			}
			h := devicekeys.Header{Sender: s.User, SenderDevice: s.Device, Recipient: r.Owner, RecipientDevice: r.Device, Operation: id, Resource: r.ID, Action: t.Action, Kind: "request", ExpiresAt: expiry}
			env, e := a.keys.Seal(p, h, t.Payload)
			if e != nil {
				return nil, e
			}
			record.Audit = append(record.Audit, AuditEntry{Request: id, Peer: r.Owner, Resource: r.ID, Action: t.Action, Started: started, Outcome: "pending"})
			record.Wire.Children = append(record.Wire.Children, control.Addressed{ID: id, Device: r.Device, Resource: r.ID, Action: t.Action, ExpiresAt: expiry, Envelope: env})
		}
		if e = save(path, record); e != nil {
			return nil, e
		}
	default:
		return nil, e
	}
	// A lost HTTP response can still mean the relay accepted these children.
	if a.auditUser == s.User && record.pendingAudit() {
		a.unsettled[in.ID] = true
	}
	var res control.Submission
	if e = a.remote(ctx, s, "POST", "/v1/submissions", record.Wire, &res); e != nil {
		var rejected statusError
		if errors.As(e, &rejected) && rejected.code >= 400 && rejected.code < 500 {
			for i := range record.Audit {
				entry := &record.Audit[i]
				if entry.Outcome != "pending" {
					continue
				}
				entry.Outcome = "failed"
				if rejected.code == http.StatusForbidden {
					entry.Outcome = "denied"
				}
				entry.Ended, entry.Summary = time.Now().UTC(), rejected.message
			}
			if err := save(path, record); err != nil {
				return nil, err
			}
			if a.auditUser == s.User {
				delete(a.unsettled, in.ID)
			}
		}
		return nil, e
	}
	return a.projectSubmission(s, path, &record, res)
}
func header(c control.Child, kind string) devicekeys.Header {
	h := devicekeys.Header{Sender: c.Sender, SenderDevice: c.SenderDevice, Recipient: c.Owner, RecipientDevice: c.Device, Operation: c.ID, Resource: c.Resource, Action: c.Action, Kind: kind, ExpiresAt: c.ExpiresAt}
	if kind == "result" {
		h.Sender, h.Recipient = h.Recipient, h.Sender
		h.SenderDevice, h.RecipientDevice = h.RecipientDevice, h.SenderDevice
	}
	return h
}
func (a *Agent) projectSubmission(s identity.Session, path string, record *sendRecord, sub control.Submission) (any, error) {
	sent := record.Wire
	updated := *record
	updated.Audit = slices.Clone(record.Audit)
	var changed bool
	if sub.ID != sent.ID || len(sub.Children) != len(sent.Children) {
		return nil, errors.New("receipt recipient set changed")
	}
	expected := make(map[string]control.Addressed, len(sent.Children))
	for _, target := range sent.Children {
		expected[target.ID] = target
	}
	out := []map[string]any{}
	for _, c := range sub.Children {
		target, found := expected[c.ID]
		if !found || c.Parent != sub.ID || c.Sender != s.User || c.SenderDevice != s.Device ||
			c.Device != target.Device || c.Resource != target.Resource || c.Action != target.Action ||
			!c.ExpiresAt.Equal(target.ExpiresAt) || !bytes.Equal(c.Envelope, target.Envelope) {
			return nil, errors.New("receipt does not match the original submission")
		}
		delete(expected, c.ID)
		a.mu.Lock()
		peer, pinned := a.policy.Pins[c.Device]
		a.mu.Unlock()
		if !pinned || peer.User != c.Owner {
			return nil, errors.New("receipt sender differs from the pinned device")
		}
		row := map[string]any{"id": c.ID, "peer": c.Owner, "resource": c.Resource, "action": c.Action, "status": c.Status}
		challenge, hasChallenge := record.BuildChallenges[c.ID]
		now := time.Now().UTC()
		if c.Action == "app.build" && hasChallenge && !now.Before(challenge.ExpiresAt()) && len(c.Result) == 0 &&
			(c.Status == "pending" || c.Status == "processing" || c.Status == "expired") {
			// A claimed request can remain at the relay during a disconnect.
			// This is local timeout evidence, not a signed peer outcome.
			row["status"], row["buildEvidence"] = "expired", "expired"
		}
		if c.Action == "app.build" && c.Status == "completed" {
			row["buildEvidence"] = "invalid"
		}
		var value json.RawMessage
		if len(c.Result) > 0 {
			r, e := a.keys.Open(peer, header(c, "result"), c.Result)
			if e != nil {
				return nil, e
			}
			var signed struct {
				Status string          `json:"status"`
				Value  json.RawMessage `json:"value"`
			}
			if e = json.Unmarshal(r, &signed); e != nil || signed.Status != c.Status {
				return nil, errors.New("receipt status does not match signed outcome")
			}
			value = signed.Value
			if c.Action == "app.build" && c.Status == "completed" {
				proof := challenge.ProofState(value, now)
				row["buildEvidence"] = proof
				switch proof {
				case "verified":
					row["result"] = value
				case "invalid":
					value = nil
				}
			} else {
				row["result"] = value
			}
		}
		if updated.updateAudit(c, value) {
			changed = true
		}
		out = append(out, row)
	}
	if changed {
		if err := save(path, &updated); err != nil {
			return nil, err
		}
		*record = updated
	}
	if a.auditUser == s.User {
		if record.pendingAudit() {
			a.unsettled[sub.ID] = true
		} else {
			delete(a.unsettled, sub.ID)
		}
	}
	return map[string]any{"id": sub.ID, "children": out}, nil
}
func (a *Agent) receipt(ctx context.Context, s identity.Session, id string) (any, error) {
	a.sendMu.Lock()
	defer a.sendMu.Unlock()
	path := filepath.Join(a.cfg.Dir, key(s.User), "submissions", key(id)+".json")
	data, e := os.ReadFile(path)
	if errors.Is(e, os.ErrNotExist) {
		return nil, errors.New("unknown coordinator submission")
	}
	if e != nil {
		return nil, e
	}
	var record sendRecord
	if e = json.Unmarshal(data, &record); e != nil {
		return nil, e
	}
	return a.refreshSubmission(ctx, s, path, &record)
}

// Callers hold sendMu so an older receipt cannot replace a newer audit outcome.
func (a *Agent) refreshSubmission(ctx context.Context, s identity.Session, path string, record *sendRecord) (any, error) {
	part, e := segment(record.Wire.ID)
	if e != nil {
		return nil, e
	}
	var res control.Submission
	if e = a.remote(ctx, s, "GET", "/v1/submissions/"+part, nil, &res); e != nil {
		return nil, e
	}
	return a.projectSubmission(s, path, record, res)
}
func wait(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}
func (a *Agent) receiveLoop() {
	for a.ctx.Err() == nil {
		s, e := a.getSession(a.ctx)
		if e != nil {
			if !wait(a.ctx, time.Second) {
				return
			}
			continue
		}
		var l control.Lease
		e = a.remote(a.ctx, s, "POST", "/v1/session", nil, &l)
		if e == nil {
			e = a.remote(a.ctx, s, "PUT", "/v1/session", proof(l), &l)
		}
		if e == nil {
			e = a.connected(a.ctx, s, l)
		}
		a.mu.Lock()
		if a.creds.Session.User == s.User {
			a.lease = control.Lease{}
			if e != nil {
				a.problem = e.Error()
			}
		}
		a.mu.Unlock()
		if !wait(a.ctx, time.Second) {
			return
		}
	}
}
func (a *Agent) connected(parent context.Context, who identity.Session, l control.Lease) error {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	a.mu.Lock()
	if a.creds.Session.User != who.User {
		a.mu.Unlock()
		return errors.New("session changed")
	}
	a.lease = l
	a.sessionStop = cancel
	a.problem = ""
	a.mu.Unlock()
	go a.syncCoordinatorInboxes(ctx, who, l)
	go a.syncWorkspaceHandoffs(ctx, who, l)
	go func() {
		defer cancel()
		for wait(ctx, 15*time.Second) {
			s, e := a.getSession(ctx)
			if e != nil || s.User != who.User {
				return
			}
			var next control.Lease
			if a.remote(ctx, s, "PUT", "/v1/session", proof(l), &next) != nil {
				return
			}
			a.mu.Lock()
			if a.lease.Session == l.Session {
				a.lease = next
			}
			a.mu.Unlock()
		}
	}()
	path := "/v1/inbox?wait=10&generation=" + strconv.FormatInt(l.Generation, 10) + "&session=" + url.QueryEscape(l.Session)
	for ctx.Err() == nil {
		s, e := a.getSession(ctx)
		if e != nil || s.User != who.User {
			return errors.New("device session changed")
		}
		if e = a.flushReceipts(ctx, s, l); e != nil {
			return e
		}
		var inbox struct{ Children []control.Child }
		poll := path
		a.mu.Lock()
		offersWorkspace := slices.ContainsFunc(a.policy.Resources, func(resource actions.Resource) bool { return resource.Workspace != "" })
		a.mu.Unlock()
		if offersWorkspace {
			poll += "&workspace=1"
		}
		if e = a.remote(ctx, s, "GET", poll, nil, &inbox); e != nil {
			return e
		}
		for _, c := range inbox.Children {
			if e = a.deliver(ctx, s, l, c); e != nil {
				return e
			}
		}
	}
	return ctx.Err()
}

type ack struct {
	ID     string
	Status string
	Result json.RawMessage
}

func (a *Agent) ackDir(user string) string {
	return filepath.Join(a.cfg.Dir, key(user), "pending-receipts")
}
func (a *Agent) flushReceipts(ctx context.Context, s identity.Session, l control.Lease) error {
	a.receiptMu.Lock()
	defer a.receiptMu.Unlock()
	dir := a.ackDir(s.User)
	entries, e := os.ReadDir(dir)
	if errors.Is(e, os.ErrNotExist) {
		return nil
	}
	if e != nil {
		return e
	}
	for _, entry := range entries {
		if filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		b, e := os.ReadFile(path)
		if e != nil {
			return e
		}
		var r ack
		if e = json.Unmarshal(b, &r); e != nil {
			return e
		}
		id, e := segment(r.ID)
		if e != nil {
			return e
		}
		msg := proof(l)
		msg["status"] = r.Status
		msg["result"] = r.Result
		if e = a.remote(ctx, s, "PUT", "/v1/children/"+id+"/receipt", msg, nil); e != nil {
			return e
		}
		if e = os.Remove(path); e != nil {
			return e
		}
	}
	return nil
}
func (a *Agent) deliver(ctx context.Context, s identity.Session, l control.Lease, c control.Child) error {
	id, e := segment(c.ID)
	if e != nil || c.Owner != s.User || c.Device != s.Device {
		return errors.New("inbox operation addressed to different device")
	}
	peer, e := a.pin(ctx, s, c.Sender, c.SenderDevice)
	if e != nil {
		var failure identity.HTTPError
		if errors.As(e, &failure) && failure.Status == http.StatusNotFound {
			// A stale inbox snapshot can outlive a revoked device or friendship.
			// Their pending children are closed by policy without consuming a use.
			return nil
		}
		return e
	}
	payload, verify := a.keys.Open(peer, header(c, "request"), c.Envelope)
	var claim struct {
		Claimed bool
		Child   struct{ GrantGroup string }
	}
	if e = a.remote(ctx, s, "POST", "/v1/children/"+id+"/claim", proof(l), &claim); e != nil {
		return e
	}
	if !claim.Claimed {
		return nil
	}
	c.GrantGroup = claim.Child.GrantGroup
	p := claimedRequest{child: c, payload: payload, peer: peer, arrived: time.Now().UTC()}
	if verify == nil && c.Action == "app.build" {
		challenge, err := actions.ParseDesktopBuildChallenge(payload)
		if err != nil {
			return a.finish(ctx, s, l, p, nil, actions.FailureCode(err), "")
		}
		if !challenge.FreshAt(p.arrived) || !p.arrived.Before(challenge.ExpiresAt()) {
			return a.finish(ctx, s, l, p, nil, actions.FailureCode(actions.ErrBuildRequestExpired), "")
		}
		p.buildExpires = challenge.ExpiresAt()
	}
	workspace := c.Action == "agent.handoff" && slices.ContainsFunc(a.localConfig(s).Resources, func(r actions.Resource) bool {
		return r.ID == c.Resource && r.Workspace != ""
	})
	if verify == nil && !workspace && a.needsApproval(c) {
		req := actions.Request{ID: c.ID, Peer: c.Sender, Group: c.GrantGroup, Resource: c.Resource, Action: c.Action, Payload: payload}
		if errors.Is(actions.CheckBudget(a.localConfig(s), req), actions.ErrBudgetExhausted) {
			return a.finish(ctx, s, l, p, nil, "budget_exhausted", "")
		}
		a.queueApproval(p)
		return nil
	}
	return a.finish(ctx, s, l, p, verify, "", "")
}

// finish runs a claimed request (unless denial is set), seals the result and
// queues its receipt.
func (a *Agent) finish(ctx context.Context, s identity.Session, l control.Lease, p claimedRequest, verify error, denial, reason string) error {
	c := p.child
	actionErr := actions.ErrInvalid
	var result json.RawMessage
	var e error
	if verify == nil && denial == "" {
		deadline := c.ExpiresAt
		if !p.buildExpires.IsZero() && p.buildExpires.Before(deadline) {
			deadline = p.buildExpires
		}
		task, cancel := context.WithDeadline(ctx, deadline)
		result, actionErr = actions.Execute(task, a.localConfig(s), actions.Request{ID: c.ID, Peer: c.Sender, Group: c.GrantGroup, Resource: c.Resource, Action: c.Action, Payload: p.payload, Deadline: c.ExpiresAt})
		cancel()
	}
	status := "completed"
	if denial == "" && actionErr != nil {
		denial, reason = actions.FailureCode(actionErr), actions.FailureReason(actionErr)
	}
	if denial != "" {
		status = "declined"
		if errors.Is(actionErr, actions.ErrUncertain) {
			status = "uncertain"
		}
		failure := map[string]string{"code": denial}
		if reason != "" {
			failure["reason"] = reason
		}
		result, e = json.Marshal(failure)
		if e != nil {
			return e
		}
	} else if len(result) == 0 {
		result = json.RawMessage("null")
	}
	entry := AuditEntry{Recipient: s.User, Unverified: verify != nil, Request: c.ID, Peer: c.Sender, Resource: c.Resource, Action: c.Action, Started: p.arrived, Ended: time.Now().UTC(),
		Outcome: auditOutcome(status, result), Tokens: actions.ResultTokens(result), Summary: summarize(result)}
	if e := a.record(entry); e != nil {
		return e
	}
	signed, e := json.Marshal(map[string]any{"status": status, "value": result})
	if e != nil {
		return e
	}
	sealed, e := a.keys.Seal(p.peer, header(c, "result"), signed)
	if e != nil {
		return e
	}
	dir := a.ackDir(s.User)
	if e = privateDir(dir); e != nil {
		return e
	}
	if e = save(filepath.Join(dir, key(c.ID)+".json"), ack{c.ID, status, sealed}); e != nil {
		return e
	}
	return a.flushReceipts(ctx, s, l)
}

func (a *Agent) syncWorkspaceHandoffs(ctx context.Context, who identity.Session, lease control.Lease) {
	for ctx.Err() == nil {
		session, err := a.getSession(ctx)
		if err != nil || session.User != who.User || session.Device != who.Device {
			return
		}
		actions.ProcessWorkspaceHandoffs(ctx, a.localConfig(session), func(ctx context.Context, id string) (bool, error) {
			var admission struct{ Ready, Allowed bool }
			err := a.remote(ctx, session, "POST", "/v1/children/"+url.PathEscape(id)+"/workspace-admission", proof(lease), &admission)
			if err == nil && !admission.Ready {
				err = errors.New("workspace delivery receipt is not ready")
			}
			return admission.Allowed, err
		})
		if !wait(ctx, 500*time.Millisecond) {
			return
		}
	}
}

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
	Digest string
	Wire   outbound
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
		expiry := time.Now().UTC().Add(15 * time.Minute).Truncate(time.Microsecond)
		for _, t := range in.Targets {
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
			h := devicekeys.Header{Sender: s.User, SenderDevice: s.Device, Recipient: r.Owner, RecipientDevice: r.Device, Operation: id, Resource: r.ID, Action: t.Action, Kind: "request", ExpiresAt: expiry}
			env, e := a.keys.Seal(p, h, t.Payload)
			if e != nil {
				return nil, e
			}
			record.Wire.Children = append(record.Wire.Children, control.Addressed{ID: id, Device: r.Device, Resource: r.ID, Action: t.Action, ExpiresAt: expiry, Envelope: env})
		}
		if e = save(path, record); e != nil {
			return nil, e
		}
	default:
		return nil, e
	}
	var res control.Submission
	if e = a.remote(ctx, s, "POST", "/v1/submissions", record.Wire, &res); e != nil {
		return nil, e
	}
	return a.projectSubmission(ctx, s, record.Wire, res)
}
func header(c control.Child, kind string) devicekeys.Header {
	h := devicekeys.Header{Sender: c.Sender, SenderDevice: c.SenderDevice, Recipient: c.Owner, RecipientDevice: c.Device, Operation: c.ID, Resource: c.Resource, Action: c.Action, Kind: kind, ExpiresAt: c.ExpiresAt}
	if kind == "result" {
		h.Sender, h.Recipient = h.Recipient, h.Sender
		h.SenderDevice, h.RecipientDevice = h.RecipientDevice, h.SenderDevice
	}
	return h
}
func (a *Agent) projectSubmission(ctx context.Context, s identity.Session, sent outbound, sub control.Submission) (any, error) {
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
		row := map[string]any{"id": c.ID, "resource": c.Resource, "action": c.Action, "status": c.Status}
		if len(c.Result) > 0 {
			a.mu.Lock()
			peer, pinned := a.policy.Pins[c.Device]
			a.mu.Unlock()
			if !pinned || peer.User != c.Owner {
				return nil, errors.New("receipt sender differs from the pinned device")
			}
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
			row["result"] = signed.Value
		}
		out = append(out, row)
	}
	return map[string]any{"id": sub.ID, "children": out}, nil
}
func (a *Agent) receipt(ctx context.Context, s identity.Session, id string) (any, error) {
	part, e := segment(id)
	if e != nil {
		return nil, e
	}
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
	var res control.Submission
	if e = a.remote(ctx, s, "GET", "/v1/submissions/"+part, nil, &res); e != nil {
		return nil, e
	}
	return a.projectSubmission(ctx, s, record.Wire, res)
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
		if e = a.remote(ctx, s, "GET", path, nil, &inbox); e != nil {
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
	var claim struct{ Claimed bool }
	if e = a.remote(ctx, s, "POST", "/v1/children/"+id+"/claim", proof(l), &claim); e != nil {
		return e
	}
	if !claim.Claimed {
		return nil
	}
	actionErr := actions.ErrInvalid
	var result json.RawMessage
	if verify == nil {
		task, cancel := context.WithDeadline(ctx, c.ExpiresAt)
		result, actionErr = actions.Execute(task, a.localConfig(s), actions.Request{ID: id, Peer: c.Sender, Resource: c.Resource, Action: c.Action, Payload: payload})
		cancel()
	}
	status := "completed"
	if actionErr != nil {
		status = "declined"
		if errors.Is(actionErr, actions.ErrUncertain) {
			status = "uncertain"
		}
		result, e = json.Marshal(map[string]string{"code": actions.FailureCode(actionErr)})
		if e != nil {
			return e
		}
	} else if len(result) == 0 {
		result = json.RawMessage("null")
	}
	signed, e := json.Marshal(map[string]any{"status": status, "value": result})
	if e != nil {
		return e
	}
	sealed, e := a.keys.Seal(peer, header(c, "result"), signed)
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

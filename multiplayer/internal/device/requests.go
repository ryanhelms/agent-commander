package device

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"agentcommander.network/pilot/internal/actions"
	"agentcommander.network/pilot/internal/identity"
)

// SentRequest is a request this device sent from the tray.
type SentRequest struct {
	ID       string    `json:"id"`
	Child    string    `json:"child"`
	Resource string    `json:"resource"`
	Action   string    `json:"action"`
	Title    string    `json:"title"`
	At       time.Time `json:"at"`
	Run      string    `json:"run,omitempty"` // target of an agent.status or agent.result follow-up
	// Children lists every recipient of a fan-out, so each child's result and
	// thread stay reachable after a restart.
	Children []SentChild `json:"children,omitempty"`
}

// SentChild is one recipient of a fan-out.
type SentChild struct {
	ID       string `json:"id"`
	Resource string `json:"resource"`
}

// allRows returns every child row of a receipt, with result also under value.
func allRows(res any) []map[string]any {
	b, _ := json.Marshal(res)
	var rows []map[string]any
	if json.Unmarshal(b, &rows) != nil {
		var obj struct{ Children []map[string]any }
		_ = json.Unmarshal(b, &obj)
		rows = obj.Children
	}
	for _, row := range rows {
		if result, ok := row["result"]; ok {
			row["value"] = result
		}
	}
	return rows
}

func (a *Agent) sentPath() string { return filepath.Join(a.cfg.Dir, "sent.jsonl") }

func (a *Agent) sentLog(user string) []SentRequest {
	f, e := os.Open(a.sentPath())
	if e != nil {
		return nil
	}
	defer f.Close()
	var out []SentRequest
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var r SentRequest
		if json.Unmarshal(sc.Bytes(), &r) != nil {
			continue
		}
		// The tray's historical index is server-wide. The frozen submission
		// under the signed-in user's directory identifies their requests.
		if _, err := os.Stat(filepath.Join(a.cfg.Dir, key(user), "submissions", key(r.ID)+".json")); err == nil {
			out = append(out, r)
		}
	}
	return out
}

func (a *Agent) logSent(r SentRequest) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	f, e := os.OpenFile(a.sentPath(), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if e != nil {
		return e
	}
	defer f.Close()
	b, _ := json.Marshal(r)
	_, e = f.Write(append(b, '\n'))
	return e
}

// sendOne submits one request and waits briefly for its result.
func (a *Agent) sendOne(ctx context.Context, s identity.Session, resource, action string, payload json.RawMessage, wait time.Duration) (string, map[string]any, error) {
	id := newID()
	if _, e := a.submit(ctx, s, Submit{ID: id, Targets: []Target{{Resource: resource, Action: action, Payload: payload}}}); e != nil {
		return id, nil, e
	}
	deadline := time.Now().Add(wait)
	for {
		res, e := a.receipt(ctx, s, id)
		if e != nil {
			return id, nil, e
		}
		row := firstRow(res)
		status, _ := row["status"].(string)
		waiting := status == "" || status == "pending" || status == "queued" || status == "claimed" || status == "processing"
		if !waiting || time.Now().After(deadline) {
			return id, row, nil
		}
		if !waitCtx(ctx, 500*time.Millisecond) {
			return id, row, ctx.Err()
		}
	}
}

func waitCtx(ctx context.Context, d time.Duration) bool { return wait(ctx, d) }

func firstRow(res any) map[string]any {
	b, _ := json.Marshal(res)
	var rows []map[string]any
	if json.Unmarshal(b, &rows) != nil {
		var obj struct{ Children []map[string]any }
		_ = json.Unmarshal(b, &obj)
		rows = obj.Children
	}
	if len(rows) == 0 {
		return map[string]any{}
	}
	row := rows[0]
	if result, ok := row["result"]; ok {
		row["value"] = result
	}
	return row
}

func (a *Agent) requesterVerb(ctx context.Context, s identity.Session, verb string, in input) (any, error) {
	switch verb {
	case "send":
		if len(in.Payload) == 0 || !json.Valid(in.Payload) || in.Resource == "" || in.Capability == "" {
			return nil, errors.New("send needs a resource, capability and JSON payload")
		}
		id, row, e := a.sendOne(ctx, s, in.Resource, in.Capability, in.Payload, 8*time.Second)
		if e != nil {
			return nil, e
		}
		title := in.Name
		if title == "" && in.Capability == "agent.handoff" {
			var task struct{ Title string }
			if json.Unmarshal(in.Payload, &task) == nil {
				title = task.Title
			}
		}
		if title == "" {
			title = in.Capability
		}
		child, _ := row["id"].(string)
		record := SentRequest{ID: id, Child: child, Resource: in.Resource, Action: in.Capability, Title: title, At: time.Now().UTC()}
		if in.Capability == "agent.status" || in.Capability == "agent.result" {
			var target struct{ Run string }
			if json.Unmarshal(in.Payload, &target) == nil {
				record.Run = target.Run
			}
		}
		if e = a.logSent(record); e != nil {
			return nil, e
		}
		row["request"] = id
		return row, nil
	case "sent", "handoffs":
		log := a.sentLog(s.User)
		slices.Reverse(log)
		out := []map[string]any{}
		var handles map[string]string
		for _, r := range log {
			if verb == "handoffs" && r.Action != "agent.handoff" {
				continue
			}
			row := map[string]any{"request": r.ID, "child": r.Child, "resource": r.Resource, "action": r.Action, "title": r.Title, "at": r.At}
			var fr map[string]any
			if res, e := a.receipt(ctx, s, r.ID); e == nil {
				fr = firstRow(res)
				row["status"], row["value"] = fr["status"], fr["value"]
				if evidence, ok := fr["buildEvidence"]; ok {
					row["buildEvidence"] = evidence
				}
				if len(r.Children) > 0 {
					if handles == nil {
						handles = a.friendHandles(ctx, s)
					}
					children := allRows(res)
					for _, c := range children {
						peer, _ := c["peer"].(string)
						c["handle"] = handles[peer]
					}
					row["children"] = children
				}
			}
			if verb == "handoffs" {
				if handles == nil {
					handles = a.friendHandles(ctx, s)
				}
				peer, _ := fr["peer"].(string)
				row["id"], row["server"], row["friend"], row["handle"] = r.ID, a.cfg.ServerID, handles[peer], handles[peer]
				row["state"], row["updatedAt"] = "unknown", r.At
				if status, ok := fr["status"].(string); ok {
					row["state"] = status
				}
				value, _ := fr["value"].(map[string]any)
				if run, _ := value["run"].(string); run != "" {
					row["state"] = "started"
					if latest, at := a.handoffUpdate(ctx, s, log, peer, r.Resource, run, false); latest != nil {
						value, row["updatedAt"] = latest, at
					}
				}
				if state, _ := value["state"].(string); state != "" {
					row["state"] = state
				}
				if at, _ := value["updatedAt"].(string); at != "" {
					row["updatedAt"] = at
				}
			}
			out = append(out, row)
			if len(out) == 50 {
				break
			}
		}
		return map[string]any{verb: out}, nil
	case "threads":
		return a.threads(ctx, s), nil
	case "thread", "comment":
		if !idPattern.MatchString(in.Request) {
			return nil, errors.New("name a request")
		}
		// A request this device sent: the thread lives on the owner's device.
		log := a.sentLog(s.User)
		if i := slices.IndexFunc(log, func(r SentRequest) bool {
			return r.ID == in.Request || r.Child == in.Request || slices.ContainsFunc(r.Children, func(c SentChild) bool { return c.ID == in.Request })
		}); i >= 0 {
			r := log[i]
			if j := slices.IndexFunc(r.Children, func(c SentChild) bool { return c.ID == in.Request }); j >= 0 {
				r.Child, r.Resource = r.Children[j].ID, r.Children[j].Resource
			}
			action, body := "thread.read", map[string]string{"request": r.Child}
			if verb == "comment" {
				action, body["text"] = "thread.comment", in.Text
			}
			payload, _ := json.Marshal(body)
			_, row, e := a.sendOne(ctx, s, r.Resource, action, payload, 10*time.Second)
			if e != nil {
				return nil, e
			}
			return row["value"], nil
		}
		// A request this device received: read or write the local thread.
		cfg := a.localConfig(s)
		if verb == "comment" {
			if !a.receivedRequest(s.User, "", "", in.Request) {
				return nil, errors.New("this device neither sent nor received that request")
			}
			a.mu.Lock()
			author := a.handle
			a.mu.Unlock()
			return actions.AddComment(cfg, in.Request, actions.Comment{Author: author, AuthorKind: "person", Text: in.Text})
		}
		return actions.ReadThread(cfg, in.Request)
	case "apply-artifact":
		return a.applyArtifact(ctx, s, in)
	}
	return nil, errors.New("unknown operation")
}

// handoffUpdate reads the newest signed status or result for this owner's run.
// Old sent logs have no run ID, so match those using the verified receipt.
func (a *Agent) handoffUpdate(ctx context.Context, s identity.Session, newestFirst []SentRequest, peer, resource, run string, resultOnly bool) (map[string]any, time.Time) {
	for _, r := range newestFirst {
		if r.Resource != resource || (r.Run != "" && r.Run != run) {
			continue
		}
		if r.Action != "agent.result" && (resultOnly || r.Action != "agent.status") {
			continue
		}
		res, err := a.receipt(ctx, s, r.ID)
		if err != nil {
			continue
		}
		row := firstRow(res)
		value, _ := row["value"].(map[string]any)
		if row["peer"] == peer && row["status"] == "completed" && value["run"] == run {
			return value, r.At
		}
	}
	return nil, time.Time{}
}

// applyArtifact applies a selected artifact into the requester's chosen checkout.
func (a *Agent) applyArtifact(ctx context.Context, s identity.Session, in input) (any, error) {
	if !filepath.IsAbs(in.Checkout) {
		return nil, errors.New("name the absolute path of a local checkout")
	}
	request := in.Handoff
	if request == "" {
		request = in.Request
	}
	res, e := a.receipt(ctx, s, request)
	if e != nil {
		return nil, e
	}
	var value struct {
		Artifacts []struct{ Kind, Name, Content, URL string }
	}
	row := firstRow(res)
	result, _ := row["value"].(map[string]any)
	if row["status"] != "completed" || (row["action"] != "agent.handoff" && row["action"] != "agent.result") {
		return nil, errors.New("name a completed handoff or agent.result request")
	}
	if row["action"] == "agent.handoff" {
		log := a.sentLog(s.User)
		slices.Reverse(log)
		peer, _ := row["peer"].(string)
		resource, _ := row["resource"].(string)
		run, _ := result["run"].(string)
		if run != "" {
			result, _ = a.handoffUpdate(ctx, s, log, peer, resource, run, true)
		}
	}
	b, _ := json.Marshal(result)
	if json.Unmarshal(b, &value) != nil || in.Artifact < 0 || in.Artifact >= len(value.Artifacts) {
		return nil, errors.New("no such artifact; read the result with agent.result first")
	}
	art := value.Artifacts[in.Artifact]
	switch art.Kind {
	case "patch":
		cmd := exec.CommandContext(ctx, "git", "-C", in.Checkout, "apply", "--index", "-")
		cmd.Stdin = strings.NewReader(art.Content)
		if out, e := cmd.CombinedOutput(); e != nil {
			return nil, errors.New("git apply failed: " + strings.TrimSpace(string(out)))
		}
		return map[string]string{"applied": art.Name}, nil
	case "report", "file":
		name := filepath.Base(art.Name)
		if name == "." || name == ".." || name == "/" || name == "" {
			name = "handoff-result.md"
		}
		path := filepath.Join(in.Checkout, name)
		for {
			f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0644)
			if errors.Is(err, os.ErrExist) {
				path = filepath.Join(in.Checkout, name+"."+newID()[:8])
				continue
			}
			if err != nil {
				return nil, err
			}
			_, err = f.WriteString(art.Content)
			if closeErr := f.Close(); err == nil {
				err = closeErr
			}
			if err != nil {
				_ = os.Remove(path)
				return nil, err
			}
			return map[string]string{"saved": path}, nil
		}
	case "branch":
		return nil, errors.New("fetch the branch " + art.Name + " from the owner's repository into your checkout")
	}
	return nil, errors.New("this artifact kind cannot be applied locally")
}

// threads lists every thread the signed-in user takes part in: requests this
// device sent and requests it received, newest first. It reads only local
// state, plus one friend lookup for the received rows' handles.
func (a *Agent) threads(ctx context.Context, s identity.Session) map[string]any {
	type row struct {
		at  time.Time
		out map[string]any
	}
	var rows []row
	for _, r := range a.sentLog(s.User) {
		if actions.IsFollowUp(r.Action) {
			continue
		}
		out := map[string]any{"request": r.ID, "resource": r.Resource, "action": r.Action, "title": r.Title,
			"at": r.At, "direction": "sent", "peer": "", "handle": ""}
		if len(r.Children) > 0 {
			children := make([]map[string]string, 0, len(r.Children))
			for _, c := range r.Children {
				children = append(children, map[string]string{"request": c.ID, "resource": c.Resource})
			}
			out["children"] = children
		}
		rows = append(rows, row{r.At, out})
	}
	type received struct {
		peer, resource, action string
		at                     time.Time
	}
	got := map[string]received{}
	keep := func(id string, r received) {
		if old, ok := got[id]; !ok || r.at.After(old.at) {
			got[id] = r
		}
	}
	a.mu.Lock()
	for id, p := range a.pending {
		if p.child.Owner == s.User && !actions.IsFollowUp(p.child.Action) {
			keep(id, received{p.child.Sender, p.child.Resource, p.child.Action, p.arrived})
		}
	}
	a.mu.Unlock()
	cfg := a.localConfig(s)
	_ = a.walkOwnerAudit(func(e AuditEntry) bool {
		if e.Unverified || e.Request == "" || actions.IsFollowUp(e.Action) {
			return true
		}
		// The same recipient rules as receivedRequest: older rows without a
		// recipient count when the receipt is in this user's state directory.
		if e.Recipient != s.User && (e.Recipient != "" || !actions.HasRequestReceipt(cfg, e.Peer, e.Resource, e.Request)) {
			return true
		}
		at := e.Started
		if at.IsZero() {
			at = e.Ended
		}
		keep(e.Request, received{e.Peer, e.Resource, e.Action, at})
		return true
	})
	if len(got) > 0 {
		handles := a.friendHandles(ctx, s)
		for id, r := range got {
			out := map[string]any{"request": id, "resource": r.resource, "action": r.action, "title": r.action,
				"at": r.at, "direction": "received", "peer": r.peer, "handle": handles[r.peer], "comments": 0}
			if thread, e := actions.ReadThread(cfg, id); e == nil {
				if comments, _ := thread["comments"].([]actions.Comment); len(comments) > 0 {
					out["comments"] = len(comments)
					last := comments[0].At
					for _, c := range comments[1:] {
						if c.At.After(last) {
							last = c.At
						}
					}
					out["lastCommentAt"] = last
				}
			}
			rows = append(rows, row{r.at, out})
		}
	}
	slices.SortStableFunc(rows, func(x, y row) int { return y.at.Compare(x.at) })
	out := []map[string]any{}
	seen := map[string]bool{}
	for _, r := range rows {
		id, _ := r.out["request"].(string)
		if seen[id] {
			continue
		}
		seen[id] = true
		out = append(out, r.out)
		if len(out) == 50 {
			break
		}
	}
	return map[string]any{"threads": out}
}

func (a *Agent) receivedRequest(user, peer, resource, id string) bool {
	matches := func(sender, target, action string) bool {
		return (peer == "" || sender == peer) && (resource == "" || target == resource) && !actions.IsFollowUp(action)
	}
	a.mu.Lock()
	p, pending := a.pending[id]
	a.mu.Unlock()
	if pending && p.child.Owner == user && matches(p.child.Sender, p.child.Resource, p.child.Action) {
		return true
	}
	found := false
	_ = a.walkOwnerAudit(func(entry AuditEntry) bool {
		if entry.Unverified || entry.Request != id || !matches(entry.Peer, entry.Resource, entry.Action) {
			return true
		}
		found = entry.Recipient == user
		if !found && entry.Recipient == "" {
			// Older audit rows omit the recipient. The executed action's receipt
			// is in that user's state directory, even on a shared server.
			cfg := a.localConfig(identity.Session{User: user})
			found = actions.HasRequestReceipt(cfg, entry.Peer, entry.Resource, id)
		}
		return !found
	})
	return found
}

func (a *Agent) walkOwnerAudit(visit func(AuditEntry) bool) error {
	f, err := os.Open(a.auditPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		var e AuditEntry
		if json.Unmarshal(sc.Bytes(), &e) == nil && !visit(e) {
			break
		}
	}
	return sc.Err()
}

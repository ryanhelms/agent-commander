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
}

func (a *Agent) sentPath() string { return filepath.Join(a.cfg.Dir, "sent.jsonl") }

func (a *Agent) sentLog() []SentRequest {
	f, e := os.Open(a.sentPath())
	if e != nil {
		return nil
	}
	defer f.Close()
	var out []SentRequest
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var r SentRequest
		if json.Unmarshal(sc.Bytes(), &r) == nil {
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
		if st, _ := row["status"].(string); st != "" && st != "pending" && st != "queued" && st != "claimed" || time.Now().After(deadline) {
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
	if json.Unmarshal(b, &rows) == nil && len(rows) > 0 {
		return rows[0]
	}
	var obj struct{ Children []map[string]any }
	if json.Unmarshal(b, &obj) == nil && len(obj.Children) > 0 {
		return obj.Children[0]
	}
	return map[string]any{}
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
		if title == "" {
			title = in.Capability
		}
		child, _ := row["id"].(string)
		if e = a.logSent(SentRequest{ID: id, Child: child, Resource: in.Resource, Action: in.Capability, Title: title, At: time.Now().UTC()}); e != nil {
			return nil, e
		}
		row["request"] = id
		return row, nil
	case "sent", "handoffs":
		log := a.sentLog()
		slices.Reverse(log)
		out := []map[string]any{}
		for _, r := range log {
			if verb == "handoffs" && r.Action != "agent.handoff" {
				continue
			}
			row := map[string]any{"request": r.ID, "child": r.Child, "resource": r.Resource, "action": r.Action, "title": r.Title, "at": r.At}
			if res, e := a.receipt(ctx, s, r.ID); e == nil {
				fr := firstRow(res)
				row["status"], row["value"] = fr["status"], fr["value"]
			}
			out = append(out, row)
			if len(out) == 50 {
				break
			}
		}
		return map[string]any{verb: out}, nil
	case "thread", "comment":
		if !idPattern.MatchString(in.Request) {
			return nil, errors.New("name a request")
		}
		// A request this device sent: the thread lives on the owner's device.
		if i := slices.IndexFunc(a.sentLog(), func(r SentRequest) bool { return r.ID == in.Request || r.Child == in.Request }); i >= 0 {
			r := a.sentLog()[i]
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
			return actions.AddComment(cfg, in.Request, actions.Comment{Author: a.handle, AuthorKind: "person", Text: in.Text})
		}
		return actions.ReadThread(cfg, in.Request)
	case "apply-artifact":
		return a.applyArtifact(ctx, s, in)
	}
	return nil, errors.New("unknown operation")
}

// applyArtifact applies a hand-off's patch artifact into a local checkout.
func (a *Agent) applyArtifact(ctx context.Context, s identity.Session, in input) (any, error) {
	if !filepath.IsAbs(in.Checkout) {
		return nil, errors.New("name the absolute path of a local checkout")
	}
	res, e := a.receipt(ctx, s, in.Request)
	if e != nil {
		return nil, e
	}
	var value struct {
		Artifacts []struct{ Kind, Name, Content, URL string }
	}
	b, _ := json.Marshal(firstRow(res)["value"])
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
		if name == "." || name == "/" || name == "" {
			name = "handoff-result.md"
		}
		path := filepath.Join(in.Checkout, name)
		if e := os.WriteFile(path, []byte(art.Content), 0644); e != nil {
			return nil, e
		}
		return map[string]string{"saved": path}, nil
	}
	return nil, errors.New("this artifact kind is not applied automatically; fetch the branch from the owner's repository")
}

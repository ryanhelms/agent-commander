package actions

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

// ContextItem is one file, diff or log sent with a prompt or hand-off.
type ContextItem struct {
	Name    string `json:"name"`
	Content string `json:"content"`
}

func validContext(items []ContextItem) bool {
	total := 0
	for _, c := range items {
		if strings.TrimSpace(c.Name) == "" {
			return false
		}
		total += len(c.Content)
	}
	return len(items) <= 16 && total <= 96<<10
}

func renderContext(items []ContextItem) string {
	var b strings.Builder
	for _, c := range items {
		b.WriteString("\n\n--- context: " + c.Name + " ---\n" + c.Content)
	}
	return b.String()
}

type commanderRun struct {
	ID      string `json:"id"`
	Path    string `json:"path"`
	Client  string `json:"client"`
	Title   string `json:"title"`
	Branch  string `json:"branch"`
	Status  string `json:"status"`
	Workers []struct {
		ID     string `json:"id"`
		Name   string `json:"name"`
		State  string `json:"state"`
		Result string `json:"result"`
	} `json:"workers"`
}

func readRun(ctx context.Context, client *http.Client, id string) (commanderRun, error) {
	var run commanderRun
	if e := readWorkerJSON(ctx, client, "http://commander/v1/runs/"+url.PathEscape(id), &run); e != nil {
		return run, e
	}
	if run.ID != id {
		return run, ErrUnavailable
	}
	return run, nil
}

// handoffs records which runs each peer created, so a peer can read only its own.
func handoffPath(cfg Config, peer string) string {
	return filepath.Join(cfg.StateDir, "handoffs", hash([]byte(peer))+".json")
}

func handoffRuns(cfg Config, peer string) []string {
	var runs []string
	if b, e := os.ReadFile(handoffPath(cfg, peer)); e == nil {
		_ = json.Unmarshal(b, &runs)
	}
	return runs
}

func handoffHandler(ctx context.Context, cfg Config, r Resource, req Request, id string, recoverOnly bool) (json.RawMessage, error) {
	if !identifier.MatchString(r.Target) {
		return nil, ErrInvalid
	}
	client, e := commanderClient(cfg.CommanderSocket)
	if e != nil {
		return nil, e
	}
	defer client.CloseIdleConnections()
	switch req.Action {
	case "agent.handoff":
		return handoff(ctx, cfg, client, r, req, id)
	case "agent.status", "agent.result":
		var in struct {
			Run string `json:"run"`
		}
		if strict(req.Payload, &in) != nil || !identifier.MatchString(in.Run) || !slices.Contains(handoffRuns(cfg, req.Peer), in.Run) {
			return nil, ErrDenied
		}
		run, e := readRun(ctx, client, in.Run)
		if e != nil {
			return nil, e
		}
		summary := ""
		var report []string
		for _, w := range run.Workers {
			if w.Result != "" {
				summary = w.Result
				report = append(report, "## "+w.Name+"\n\n"+w.Result)
			}
		}
		if len(summary) > 600 {
			summary = summary[:600] + "…"
		}
		out := map[string]any{"run": run.ID, "state": run.Status, "title": run.Title, "summary": summary, "updatedAt": time.Now().UTC()}
		if req.Action == "agent.result" {
			artifacts := []map[string]string{}
			if len(report) > 0 {
				artifacts = append(artifacts, map[string]string{"kind": "report", "name": "Result", "content": strings.Join(report, "\n\n")})
			}
			if run.Branch != "" {
				artifacts = append(artifacts, map[string]string{"kind": "branch", "name": run.Branch})
			}
			out["artifacts"] = artifacts
		}
		return answer(out)
	}
	return nil, ErrInvalid
}

func handoff(ctx context.Context, cfg Config, client *http.Client, r Resource, req Request, id string) (json.RawMessage, error) {
	var in struct {
		Title   string        `json:"title"`
		Task    string        `json:"task"`
		Context []ContextItem `json:"context"`
	}
	if strict(req.Payload, &in) != nil || strings.TrimSpace(in.Task) == "" || strings.TrimSpace(in.Title) == "" || !validContext(in.Context) {
		return nil, ErrInvalid
	}
	info, e := workerInfo(ctx, client, r.Target)
	if e != nil {
		return nil, e
	}
	source, e := readRun(ctx, client, info.RunID)
	if e != nil {
		return nil, e
	}
	body, _ := json.Marshal(map[string]any{
		"path": source.Path, "client": source.Client, "title": in.Title,
		"task": "[Handed off by " + req.Peer + ", shared operation " + id + "]\n" + in.Task + renderContext(in.Context),
	})
	post, _ := http.NewRequestWithContext(ctx, "POST", "http://commander/v1/runs", bytes.NewReader(body))
	post.Header.Set("Content-Type", "application/json")
	post.Header.Set("Idempotency-Key", "handoff-"+id)
	res, e := client.Do(post)
	if e != nil {
		return nil, ErrUncertain
	}
	defer res.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(res.Body, 64<<10))
	if res.StatusCode/100 != 2 {
		return nil, ErrUnavailable
	}
	var run commanderRun
	if json.Unmarshal(data, &run) != nil || !identifier.MatchString(run.ID) {
		return nil, ErrUncertain
	}
	runs := handoffRuns(cfg, req.Peer)
	if !slices.Contains(runs, run.ID) {
		runs = append(runs, run.ID)
		if e := privateDir(filepath.Dir(handoffPath(cfg, req.Peer))); e != nil {
			return nil, ErrUnavailable
		}
		if e := save(handoffPath(cfg, req.Peer), runs); e != nil {
			return nil, ErrUnavailable
		}
	}
	return answer(map[string]string{"run": run.ID, "title": in.Title, "state": run.Status})
}

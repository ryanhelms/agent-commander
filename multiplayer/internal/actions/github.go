package actions

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

func safeToken(token string) bool {
	return token != "" && len(token) <= 4096 && !strings.ContainsAny(token, "\r\n\x00")
}

type issueView struct {
	Number      int             `json:"number"`
	Title       string          `json:"title"`
	State       string          `json:"state"`
	Body        string          `json:"body,omitempty"`
	PullRequest json.RawMessage `json:"pull_request,omitempty"`
}

func (i issueView) bounded() bool {
	return i.Number > 0 && len(i.Title) <= 1024 && len(i.Body) <= 32<<10 && len(i.PullRequest) == 0
}

func issueAction(ctx context.Context, cfg Config, r Resource, action string, payload []byte) (json.RawMessage, error) {
	if _, e := verifyRepo(ctx, r); e != nil {
		return nil, e
	}
	var in struct {
		Number int    `json:"number"`
		Body   string `json:"body,omitempty"`
	}
	if strict(payload, &in) != nil || in.Number < 0 || in.Number > 2147483647 {
		return nil, ErrInvalid
	}
	if action != "issue.read" && in.Number == 0 {
		return nil, ErrInvalid
	}
	if action != "issue.comment" && in.Body != "" || action == "issue.comment" && (strings.TrimSpace(in.Body) == "" || len(in.Body) > 16<<10) {
		return nil, ErrInvalid
	}
	if cfg.GitHubToken == nil {
		return nil, ErrUnavailable
	}
	token, e := cfg.GitHubToken(ctx, r.ID, action)
	if e != nil || !safeToken(token) {
		return nil, ErrUnavailable
	}
	base := "https://api.github.com"
	if cfg.testGitHub != "" {
		base = cfg.testGitHub
	}
	endpoint := base + "/repos/" + r.Repository + "/issues"
	if in.Number > 0 {
		endpoint += fmt.Sprintf("/%d", in.Number)
	} else {
		endpoint += "?state=open&per_page=20"
	}
	client := http.Client{Transport: &http.Transport{Proxy: nil, DisableKeepAlives: true}, Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	call := func(method, target string, body any) ([]byte, error) {
		var input []byte
		if body != nil {
			input, _ = json.Marshal(body)
		}
		req, e := http.NewRequestWithContext(ctx, method, target, bytes.NewReader(input))
		if e != nil {
			return nil, ErrInvalid
		}
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Accept", "application/vnd.github+json")
		req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		res, e := client.Do(req)
		if e != nil {
			if method != http.MethodGet {
				return nil, ErrUncertain
			}
			return nil, ErrUnavailable
		}
		defer res.Body.Close()
		if res.StatusCode < 200 || res.StatusCode >= 300 {
			if method != "GET" && res.StatusCode >= 500 {
				return nil, ErrUncertain
			}
			return nil, ErrDenied
		}
		raw, e := io.ReadAll(io.LimitReader(res.Body, (1<<20)+1))
		if e != nil || len(raw) > 1<<20 {
			if method != "GET" {
				return nil, ErrUncertain
			}
			return nil, ErrUnavailable
		}
		return raw, nil
	}
	raw, e := call(http.MethodGet, endpoint, nil)
	if e != nil {
		return nil, e
	}
	if in.Number == 0 {
		var issues []issueView
		if e := json.Unmarshal(raw, &issues); e != nil {
			return nil, ErrUnavailable
		}
		public := make([]issueView, 0)
		for _, i := range issues {
			if i.Number > 0 && len(i.PullRequest) == 0 {
				i.Body = ""
				if !i.bounded() {
					return nil, ErrUnavailable
				}
				public = append(public, i)
			}
			if len(public) >= 20 {
				break
			}
		}
		return answer(map[string]any{"status": "completed", "issues": public})
	}
	var issue issueView
	if json.Unmarshal(raw, &issue) != nil || issue.Number != in.Number || !issue.bounded() {
		return nil, ErrInvalid
	}
	switch action {
	case "issue.read":
		return answer(map[string]any{"status": "completed", "issue": issue})
	case "issue.comment":
		raw, e := call(http.MethodPost, endpoint+"/comments", map[string]string{"body": in.Body})
		if e != nil {
			return nil, e
		}
		var comment struct {
			ID int64 `json:"id"`
		}
		if json.Unmarshal(raw, &comment) != nil || comment.ID <= 0 {
			return nil, ErrUncertain
		}
		return answer(map[string]any{"status": "completed", "number": in.Number, "commentId": comment.ID})
	case "issue.close":
		if issue.State != "closed" {
			raw, e := call(http.MethodPatch, endpoint, map[string]string{"state": "closed"})
			if e != nil {
				return nil, e
			}
			var changed issueView
			if json.Unmarshal(raw, &changed) != nil || changed.Number != in.Number || changed.State != "closed" {
				return nil, ErrUncertain
			}
		}
		return answer(map[string]any{"status": "completed", "number": in.Number, "state": "closed"})
	}
	return nil, ErrInvalid
}

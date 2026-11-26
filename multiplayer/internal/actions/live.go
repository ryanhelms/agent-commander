package actions

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
)

func watchHandler(ctx context.Context, cfg Config, r Resource, req Request, _ string, _ bool) (json.RawMessage, error) {
	var in struct {
		After string `json:"after"`
	}
	if strict(req.Payload, &in) != nil || !identifier.MatchString(r.Target) {
		return nil, ErrInvalid
	}
	client, e := commanderClient(cfg.CommanderSocket)
	if e != nil {
		return nil, e
	}
	defer client.CloseIdleConnections()
	info, e := workerInfo(ctx, client, r.Target)
	if e != nil {
		return nil, e
	}
	q := url.Values{"source": {"live"}, "limit": {"32"}}
	if in.After != "" {
		q.Set("cursor", in.After)
	}
	hreq, _ := http.NewRequestWithContext(ctx, "GET", "http://commander/v1/workers/"+url.PathEscape(r.Target)+"/history?"+q.Encode(), nil)
	res, e := client.Do(hreq)
	if e != nil {
		return nil, ErrUnavailable
	}
	defer res.Body.Close()
	page, _ := io.ReadAll(io.LimitReader(res.Body, 64<<10+1))
	if res.StatusCode != http.StatusOK || len(page) > 64<<10 || !json.Valid(page) {
		return answer(map[string]any{"state": info.RunStatus, "page": nil, "available": false})
	}
	return answer(map[string]any{"state": info.RunStatus, "page": json.RawMessage(page), "available": true})
}

const reviewPrompt = `Review the change below as a careful senior engineer. Reply with ONLY a JSON object:
{"summary": "<two sentences>", "findings": [{"file": "<path>", "line": <number or 0>, "severity": "important" or "nit", "text": "<the problem and the fix>"}]}
Report real defects first; omit praise.`

func reviewHandler(ctx context.Context, cfg Config, r Resource, req Request, id string, recoverOnly bool) (json.RawMessage, error) {
	var in struct {
		Title        string `json:"title"`
		Diff         string `json:"diff"`
		PR           string `json:"pr"`
		Instructions string `json:"instructions"`
	}
	if strict(req.Payload, &in) != nil || (in.Diff == "" && in.PR == "") {
		return nil, ErrInvalid
	}
	text := reviewPrompt + "\n\nTitle: " + in.Title
	if in.Instructions != "" {
		text += "\nReviewer instructions: " + in.Instructions
	}
	var ctxItems []ContextItem
	if in.PR != "" {
		text += "\nPull request: " + in.PR
	}
	if in.Diff != "" {
		ctxItems = append(ctxItems, ContextItem{Name: "change.diff", Content: in.Diff})
	}
	payload, _ := json.Marshal(map[string]any{"text": text, "context": ctxItems})
	if len(text) > 15<<10 {
		return nil, ErrInvalid
	}
	raw, e := ask(ctx, cfg, r, id, payload, recoverOnly)
	if e != nil {
		return nil, e
	}
	var answered struct {
		Text   string `json:"text"`
		Tokens *int   `json:"tokens"`
	}
	_ = json.Unmarshal(raw, &answered)
	result := parseReview(answered.Text)
	if answered.Tokens != nil {
		result["tokens"] = *answered.Tokens
	}
	return answer(result)
}

// ReviewFinding is one finding in a review result.
type ReviewFinding struct {
	File     string `json:"file"`
	Line     int    `json:"line"`
	Severity string `json:"severity"`
	Text     string `json:"text"`
}

func parseReview(text string) map[string]any {
	var out struct {
		Summary  string          `json:"summary"`
		Findings []ReviewFinding `json:"findings"`
	}
	body := text
	if i, j := strings.Index(text, "{"), strings.LastIndex(text, "}"); i >= 0 && j > i {
		body = text[i : j+1]
	}
	if json.Unmarshal([]byte(body), &out) != nil || out.Summary == "" {
		return map[string]any{"summary": text, "findings": []ReviewFinding{}}
	}
	if out.Findings == nil {
		out.Findings = []ReviewFinding{}
	}
	return map[string]any{"summary": out.Summary, "findings": out.Findings}
}

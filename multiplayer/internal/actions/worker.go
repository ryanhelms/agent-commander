package actions

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"
	"time"

	"agentcommander.network/pilot/internal/sharing"
)

type localWorker struct {
	WorkerID   string `json:"workerId"`
	Role       string `json:"role"`
	RunID      string `json:"runId"`
	RunStatus  string `json:"runStatus"`
	Generation int    `json:"generation"`
	Client     string `json:"client"`
	Harness    string `json:"harness"`
	Model      string `json:"model"`
}

func commanderClient(socket string) (*http.Client, error) {
	if !filepath.IsAbs(socket) {
		return nil, ErrUnavailable
	}
	transport := &http.Transport{DisableKeepAlives: true, DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{Timeout: 3 * time.Second}).DialContext(ctx, "unix", socket)
	}}
	return &http.Client{Transport: transport, Timeout: 2 * time.Minute, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, nil
}

func workerURL(id string) string { return "http://commander/v1/ag-ui/workers/" + url.PathEscape(id) }

func readWorkerJSON(ctx context.Context, client *http.Client, addr string, v any) error {
	req, e := http.NewRequestWithContext(ctx, http.MethodGet, addr, nil)
	if e != nil {
		return ErrInvalid
	}
	res, e := client.Do(req)
	if e != nil {
		return ErrUnavailable
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return ErrUnavailable
	}
	data, e := io.ReadAll(io.LimitReader(res.Body, (64<<10)+1))
	if e != nil || len(data) > 64<<10 || json.Unmarshal(data, v) != nil {
		return ErrUnavailable
	}
	return nil
}

func workerInfo(ctx context.Context, client *http.Client, target string) (localWorker, error) {
	var info localWorker
	if e := readWorkerJSON(ctx, client, workerURL(target), &info); e != nil {
		return info, e
	}
	if info.WorkerID != target || (info.Role != "worker" && info.Role != "coordinator") {
		return info, ErrDenied
	}
	return info, nil
}

// ACP prompt results can report a total or only the individual token counts.
type turnTokens struct {
	TotalTokens, InputTokens, OutputTokens, ThoughtTokens, CachedReadTokens, CachedWriteTokens *int
}

func (u *turnTokens) count() *int {
	if u == nil {
		return nil
	}
	if u.TotalTokens != nil {
		if *u.TotalTokens < 0 {
			return nil
		}
		return u.TotalTokens
	}
	total, reported := 0, false
	for _, n := range []*int{u.InputTokens, u.OutputTokens, u.ThoughtTokens, u.CachedReadTokens, u.CachedWriteTokens} {
		if n != nil {
			if *n < 0 || *n > math.MaxInt-total {
				return nil
			}
			reported = true
			total += *n
		}
	}
	if !reported {
		return nil
	}
	return &total
}

// PrepareLocalResource resolves the exact target on the owner's Commander socket.
// Workers accept supervised turns, coordinators receive addressed inbox messages.
func PrepareLocalResource(ctx context.Context, socket string, resource Resource) (Resource, error) {
	r, e := PrepareResource(ctx, resource)
	if e != nil || r.Kind != "agent" {
		return r, e
	}
	client, e := commanderClient(socket)
	if e != nil {
		return r, e
	}
	defer client.CloseIdleConnections()
	info, e := workerInfo(ctx, client, r.Target)
	if e != nil {
		return r, e
	}
	r.Coordinator, r.Run = info.Role == "coordinator", info.RunID
	if r.Coordinator && (!identifier.MatchString(r.Run) || info.RunStatus != "running") {
		return r, ErrDenied
	}
	if info.Harness == "" {
		info.Harness = info.Client
	}
	harness := strings.ToLower(strings.TrimSpace(info.Harness))
	switch harness {
	case "claude code":
		harness = "claude"
	case "claude", "codex", "":
	default:
		harness = "other"
	}
	if harness != "" || info.Model != "" {
		r.Capabilities = r.Capabilities.WithDefaults(&sharing.Capabilities{Harness: harness, Model: info.Model})
	}
	return r, nil
}

// ask uses the owner socket's operation-scoped receipt and output stream. A fresh
// marker distinguishes this command's submitted turn from earlier console history.
func ask(ctx context.Context, cfg Config, r Resource, id string, raw []byte, recoverOnly bool) (json.RawMessage, error) {
	var input struct {
		Text    string        `json:"text"`
		Context []ContextItem `json:"context"`
	}
	if strict(raw, &input) != nil || strings.TrimSpace(input.Text) == "" || len(input.Text) > 15<<10 || !identifier.MatchString(r.Target) || !validContext(input.Context) {
		return nil, ErrInvalid
	}
	client, e := commanderClient(cfg.CommanderSocket)
	if e != nil {
		return nil, e
	}
	defer client.CloseIdleConnections()
	base := workerURL(r.Target)
	prompt := "[Shared operation " + id + "]\n" + input.Text + renderContext(input.Context)
	var operation string
	var request *http.Request
	if recoverOnly {
		var receipt struct {
			RunID       string `json:"runId"`
			OperationID string `json:"operationId"`
		}
		if e := readWorkerJSON(ctx, client, base+"/operations?runId="+id, &receipt); e != nil || receipt.RunID != id || !identifier.MatchString(receipt.OperationID) {
			return nil, ErrUncertain
		}
		operation = receipt.OperationID
		request, _ = http.NewRequestWithContext(ctx, "GET", base+"/operations/"+url.PathEscape(operation)+"?runId="+id, nil)
	} else {
		info, e := workerInfo(ctx, client, r.Target)
		if e != nil {
			return nil, e
		}
		if info.Role != "worker" || info.Generation <= 0 || (r.Run != "" && r.Run != info.RunID) {
			return nil, ErrDenied
		}
		payload, _ := json.Marshal(map[string]any{"threadId": r.Target, "runId": id, "forwardedProps": map[string]int{"generation": info.Generation}, "messages": []any{map[string]string{"id": id, "role": "user", "content": prompt}}})
		request, _ = http.NewRequestWithContext(ctx, "POST", base+"/run", bytes.NewReader(payload))
		request.Header.Set("Content-Type", "application/json")
	}
	request.Header.Set("Accept", "text/event-stream")
	res, e := client.Do(request)
	if e != nil {
		return nil, ErrUncertain
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		if res.StatusCode >= 500 || recoverOnly {
			return nil, ErrUncertain
		}
		return nil, ErrDenied
	}
	lines := bufio.NewScanner(io.LimitReader(res.Body, 8<<20))
	lines.Buffer(make([]byte, 4096), 512<<10)
	var text, state string
	var tokens *int
	for lines.Scan() {
		line := lines.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		var event struct {
			Type     string `json:"type"`
			RunID    string `json:"runId"`
			Snapshot struct {
				WorkerID    string `json:"workerId"`
				OperationID string `json:"operationId"`
				Status      string `json:"operationStatus"`
			} `json:"snapshot"`
			Messages []struct {
				Role     string `json:"role"`
				Content  string `json:"content"`
				Metadata struct {
					ACP struct {
						Source, Kind, TurnID string
						TurnTokens           *turnTokens
					}
				}
			} `json:"messages"`
		}
		if json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &event) != nil {
			continue
		}
		switch event.Type {
		case "STATE_SNAPSHOT":
			if event.Snapshot.WorkerID != r.Target || !identifier.MatchString(event.Snapshot.OperationID) || operation != "" && event.Snapshot.OperationID != operation {
				return nil, ErrUncertain
			}
			operation = event.Snapshot.OperationID
			state = event.Snapshot.Status
		case "MESSAGES_SNAPSHOT":
			text = ""
			ours := false
			for _, m := range event.Messages {
				switch m.Role {
				case "user":
					ours = m.Content == prompt
				case "assistant":
					if ours && len(m.Content) <= 32<<10 && m.Content != "" {
						text = m.Content
					}
				}
				acp := m.Metadata.ACP
				if acp.Source == "live" && acp.Kind == "acp.prompt_result" &&
					((acp.TurnID != "" && acp.TurnID == operation) || (acp.TurnID == "" && ours)) {
					if n := acp.TurnTokens.count(); n != nil {
						tokens = n
					}
				}
			}
		case "RUN_FINISHED":
			if operation == "" || event.RunID != id {
				return nil, ErrUncertain
			}
			if state != "completed" {
				return nil, ErrInvalid
			}
			result := map[string]any{"status": "completed", "operationId": operation, "text": text, "resultAvailable": text != ""}
			if tokens != nil {
				result["tokens"] = *tokens
			}
			return answer(result)
		case "RUN_ERROR":
			if state == "delivery_unknown" || state == "unavailable" {
				return nil, ErrUncertain
			}
			return nil, ErrInvalid
		}
	}
	return nil, ErrUncertain
}

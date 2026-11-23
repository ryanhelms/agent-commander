// Package mcpbridge exposes actor-scoped service operations as MCP tools.
package mcpbridge

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"time"

	"agentcommander/internal/localapi"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type statusInput struct {
	Seconds int `json:"wait_seconds,omitempty" jsonschema:"wait up to 30 seconds for a meaningful run change; zero returns immediately"`
}
type delegate struct {
	Name   string `json:"name"`
	Task   string `json:"task"`
	Client string `json:"client,omitempty" jsonschema:"choose an available client for this worker; omit to inherit the run's client"`
	Host   string `json:"host,omitempty" jsonschema:"configured SSH host alias; omit for this Mac"`
	Kind   string `json:"kind,omitempty" jsonschema:"research, review, or coding; coding uses an isolated Git worktree"`
	Key    string `json:"idempotency_key,omitempty" jsonschema:"reuse this key when retrying the same delegation"`
}
type ask struct {
	Question string `json:"question"`
	Key      string `json:"idempotency_key,omitempty" jsonschema:"reuse this key when retrying the same question"`
}
type waitInput struct {
	Request string `json:"request_id"`
	Seconds int    `json:"timeout_seconds,omitempty" jsonschema:"maximum wait up to 45 seconds"`
}
type reply struct {
	Request string `json:"request_id"`
	Answer  string `json:"answer"`
}
type reconcile struct {
	Request string `json:"request_id"`
}
type finding struct {
	Result   string `json:"result"`
	Revision string `json:"revision,omitempty" jsonschema:"committed revision from the assigned coding worktree"`
	Tests    []struct {
		Command string `json:"command"`
		Outcome string `json:"outcome"`
	} `json:"tests,omitempty"`
}

type codingCommit struct {
	Files   []string `json:"files"`
	Message string   `json:"message"`
}

type integrate struct {
	Workers []string `json:"worker_ids"`
	Key     string   `json:"idempotency_key"`
}

type workerTarget struct {
	Worker string `json:"worker_id"`
}

type followUp struct {
	Worker string `json:"worker_id"`
	Text   string `json:"text"`
	Key    string `json:"idempotency_key,omitempty" jsonschema:"reuse this key when retrying the same follow-up"`
}

func register[T any](s *mcp.Server, name, desc string, handle func(context.Context, T) (json.RawMessage, error)) {
	mcp.AddTool(s, &mcp.Tool{Name: name, Description: desc}, func(ctx context.Context, _ *mcp.CallToolRequest, in T) (*mcp.CallToolResult, any, error) {
		data, err := handle(ctx, in)
		if err != nil {
			return nil, nil, err
		}
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(data)}}}, nil, nil
	})
}

func Run(ctx context.Context, c *localapi.Client) error {
	actor, err := localapi.Segment(os.Getenv("AGENT_COMMANDER_WORKER_ID"))
	if err != nil {
		return errors.New("start MCP from a Commander-managed session with a worker identity")
	}
	run, err := localapi.Segment(os.Getenv("AGENT_COMMANDER_RUN_ID"))
	if err != nil || os.Getenv("AGENT_COMMANDER_TOKEN") == "" {
		return errors.New("missing Commander run identity or scoped credential")
	}
	runPath := "/v1/runs/" + run
	workerPath := "/v1/workers/" + actor
	s := mcp.NewServer(&mcp.Implementation{Name: "agent-commander", Version: "0.1.0"}, nil)
	register(s, "commander_delegate", "Launch a managed worker under your assignment in this run.", func(ctx context.Context, in delegate) (json.RawMessage, error) {
		return c.Do(ctx, "POST", runPath+"/workers", map[string]string{"parent_id": actor, "name": in.Name, "task": in.Task, "client": in.Client, "host": in.Host, "kind": in.Kind, "idempotency_key": in.Key})
	})
	register(s, "commander_ask", "Escalate a question and obtain its request ID. Use commander_wait for the answer.", func(ctx context.Context, in ask) (json.RawMessage, error) {
		return c.Do(ctx, "POST", workerPath+"/questions", in)
	})
	register(s, "commander_wait", "Wait for a reply to your question. Call again when it is pending.", func(ctx context.Context, in waitInput) (json.RawMessage, error) {
		id, err := localapi.Segment(in.Request)
		if err != nil {
			return nil, err
		}
		seconds := in.Seconds
		if seconds <= 0 {
			seconds = 15
		}
		if seconds > 45 {
			seconds = 45
		}
		deadline := time.NewTimer(time.Duration(seconds) * time.Second)
		defer deadline.Stop()
		ticker := time.NewTicker(450 * time.Millisecond)
		defer ticker.Stop()
		persistent := os.Getenv("AGENT_COMMANDER_PERSISTENT_SSH_WAIT") == "1"
		var last json.RawMessage
		for {
			b, err := c.Do(ctx, "GET", workerPath+"/questions/"+id, nil)
			if err != nil {
				var transport *url.Error
				if !persistent || !errors.As(err, &transport) {
					return nil, err
				}
			} else {
				last = b
				var q struct {
					Status string `json:"status"`
				}
				if decodeErr := json.Unmarshal(b, &q); decodeErr != nil {
					return nil, decodeErr
				}
				if q.Status != "pending" {
					return b, nil
				}
			}
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-deadline.C:
				if last != nil {
					return last, nil
				}
				return nil, err
			case <-ticker.C:
			}
		}
	})
	register(s, "commander_reply", "Answer a specific question from a worker you control.", func(ctx context.Context, in reply) (json.RawMessage, error) {
		id, err := localapi.Segment(in.Request)
		if err != nil {
			return nil, err
		}
		return c.Do(ctx, "POST", "/v1/requests/"+id+"/reply", map[string]string{"answer": in.Answer})
	})
	register(s, "commander_reconcile_reply", "Check the original native history for an ambiguous SSH reply. Does not resend the answer.", func(ctx context.Context, in reconcile) (json.RawMessage, error) {
		id, err := localapi.Segment(in.Request)
		if err != nil {
			return nil, err
		}
		return c.Do(ctx, "POST", "/v1/requests/"+id+"/reconcile", struct{}{})
	})
	register(s, "commander_result", "Report findings and test results to your coordinator.", func(ctx context.Context, in finding) (json.RawMessage, error) {
		return c.Do(ctx, "POST", workerPath+"/result", in)
	})
	register(s, "commander_commit", "Commit selected changed files in your assigned coding worktree.", func(ctx context.Context, in codingCommit) (json.RawMessage, error) {
		return c.Do(ctx, "POST", workerPath+"/coding/commit", in)
	})
	register(s, "commander_integrate", "Prepare selected coding handoffs, run the configured combined tests, and advance the coordinator branch when safe.", func(ctx context.Context, in integrate) (json.RawMessage, error) {
		return c.Do(ctx, "POST", runPath+"/integrations", in)
	})
	register(s, "commander_send", "Queue a follow-up for a managed worker you control. It runs when the worker is ready for a new turn.", func(ctx context.Context, in followUp) (json.RawMessage, error) {
		id, err := localapi.Segment(in.Worker)
		if err != nil {
			return nil, err
		}
		return c.Do(ctx, "POST", "/v1/workers/"+id+"/messages", map[string]string{"text": in.Text, "idempotency_key": in.Key})
	})
	register(s, "commander_interrupt", "Interrupt a worker's current turn and keep its conversation available for follow-up.", workerCommand(c, "interrupt"))
	register(s, "commander_stop_worker", "Stop one managed worker you control without stopping the run.", workerCommand(c, "stop"))
	register(s, "commander_status", "Read worker assignments, findings and questions. While waiting on workers, set wait_seconds to 30 to return on a status change or timeout.", func(ctx context.Context, in statusInput) (json.RawMessage, error) {
		return runStatus(ctx, c, runPath, in.Seconds)
	})
	return s.Run(ctx, &mcp.StdioTransport{})
}

func workerCommand(c *localapi.Client, action string) func(context.Context, workerTarget) (json.RawMessage, error) {
	return func(ctx context.Context, in workerTarget) (json.RawMessage, error) {
		id, err := localapi.Segment(in.Worker)
		if err != nil {
			return nil, err
		}
		return c.Do(ctx, "POST", "/v1/workers/"+id+"/"+action, struct{}{})
	}
}

// Keep this projection small and stable while workers print output. Console
// subscriptions continue to use the full API response.
func projectStatus(full json.RawMessage) (json.RawMessage, error) {
	var status struct {
		ID            string            `json:"id"`
		Project       string            `json:"project"`
		Path          string            `json:"path"`
		Task          string            `json:"task"`
		Client        string            `json:"client"`
		CoordinatorID string            `json:"coordinator_id"`
		Status        string            `json:"status"`
		Integrations  []json.RawMessage `json:"integrations,omitempty"`
		Workers       []struct {
			ID         string          `json:"id"`
			ParentID   string          `json:"parent_id,omitempty"`
			Role       string          `json:"role"`
			Name       string          `json:"name"`
			Task       string          `json:"task"`
			State      string          `json:"state"`
			Host       string          `json:"host,omitempty"`
			Connection string          `json:"connection,omitempty"`
			Worktree   string          `json:"worktree,omitempty"`
			Result     string          `json:"result,omitempty"`
			Error      string          `json:"error,omitempty"`
			Handoff    json.RawMessage `json:"handoff,omitempty"`
		} `json:"workers"`
		Requests []struct {
			ID       string `json:"id"`
			WorkerID string `json:"worker_id"`
			Question string `json:"question"`
			Status   string `json:"status"`
			Answer   string `json:"answer,omitempty"`
			Delivery string `json:"delivery,omitempty"`
		} `json:"requests"`
	}
	if err := json.Unmarshal(full, &status); err != nil {
		return nil, err
	}
	return json.Marshal(status)
}

func runStatus(ctx context.Context, c *localapi.Client, path string, seconds int) (json.RawMessage, error) {
	fetch := func(ctx context.Context) (json.RawMessage, error) {
		full, err := c.Do(ctx, "GET", path, nil)
		if err != nil {
			return nil, err
		}
		return projectStatus(full)
	}
	first, err := fetch(ctx)
	if err != nil || seconds <= 0 {
		return first, err
	}
	waitCtx, cancel := context.WithTimeout(ctx, time.Duration(min(seconds, 30))*time.Second)
	defer cancel()
	poll := time.NewTicker(700 * time.Millisecond)
	defer poll.Stop()
	for {
		select {
		case <-waitCtx.Done():
			return first, ctx.Err()
		case <-poll.C:
			next, err := fetch(waitCtx)
			if waitCtx.Err() != nil {
				return first, ctx.Err()
			}
			if err != nil || !bytes.Equal(next, first) {
				return next, err
			}
		}
	}
}

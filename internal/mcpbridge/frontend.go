package mcpbridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"agentcommander/internal/localapi"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type frontendArguments struct {
	Name      string         `json:"name" jsonschema:"exact name returned by commander_frontend_tools"`
	Arguments map[string]any `json:"arguments" jsonschema:"arguments that match the selected tool's parameter schema"`
}

type frontendCallStatus struct {
	ID     string `json:"id"`
	Result *struct {
		Content string `json:"content"`
		Error   string `json:"error"`
	} `json:"result"`
}

func registerFrontendTools(ctx context.Context, s *mcp.Server, c *localapi.Client, workerPath string) {
	path := workerPath + "/frontend-tools"
	register(s, "commander_frontend_tools", "List tools offered by the app for the current Commander follow-up, including argument schemas. Use this when the developer requests an app tool.", func(ctx context.Context, _ struct{}) (json.RawMessage, error) {
		return c.Do(ctx, "GET", path, nil)
	})
	mcp.AddTool(s, &mcp.Tool{
		Name: "commander_call_frontend", Description: "Invoke a tool offered for this follow-up and wait for the app's result. Use the exact name and validated arguments from commander_frontend_tools.",
	}, func(ctx context.Context, request *mcp.CallToolRequest, _ frontendArguments) (*mcp.CallToolResult, any, error) {
		if err := ctx.Err(); err != nil {
			return nil, nil, err
		}
		ctx, cancel := context.WithTimeout(ctx, 65*time.Second)
		defer cancel()
		// Once creation starts, recover its service-generated ID even if the
		// caller cancels before the create response arrives.
		createCtx, stopCreate := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
		// Keep the validated wire arguments. The typed MCP decoder uses float64
		// for numbers in arbitrary maps and can round an exact integer.
		raw, err := c.Do(createCtx, "POST", path+"/calls", request.Params.Arguments)
		stopCreate()
		if err != nil {
			var refusal *localapi.ResponseError
			if errors.As(err, &refusal) {
				return nil, nil, err
			}
			return nil, nil, fmt.Errorf("frontend call delivery is unconfirmed: %w", err)
		}
		var call frontendCallStatus
		if err := json.Unmarshal(raw, &call); err != nil {
			return nil, nil, err
		}
		id, err := localapi.Segment(call.ID)
		if err != nil {
			return nil, nil, err
		}
		callPath := path + "/calls/" + id
		defer func() {
			// The stdio MCP transport reports peer loss with its read error
			// as the cause. Only an actual cancellation retires the call.
			if context.Cause(ctx) == context.Canceled {
				retire, done := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
				defer done()
				_, _ = c.Do(retire, "POST", callPath+"/cancel", nil)
			}
		}()
		ticker := time.NewTicker(350 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return nil, nil, ctx.Err()
			case <-ticker.C:
			}
			raw, err = c.Do(ctx, "GET", callPath, nil)
			if err != nil {
				return nil, nil, fmt.Errorf("frontend call %s result delivery is unconfirmed: %w", id, err)
			}
			if err := json.Unmarshal(raw, &call); err != nil {
				return nil, nil, err
			}
			if call.Result == nil {
				continue
			}
			content := []mcp.Content{&mcp.TextContent{Text: call.Result.Content}}
			if call.Result.Error != "" {
				content = append(content, &mcp.TextContent{Text: call.Result.Error})
			}
			return &mcp.CallToolResult{Content: content, IsError: call.Result.Error != ""}, nil, nil
		}
	})
	ready, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	// Older services and coordinator sessions can use the other MCP tools.
	_, _ = c.Do(ready, "POST", path+"/ready", struct{}{})
}

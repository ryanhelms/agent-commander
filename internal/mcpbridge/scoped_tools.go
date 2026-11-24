package mcpbridge

import (
	"context"
	"encoding/json"
	"net/http"

	"agentcommander/internal/localapi"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func registerScopedTools(s *mcp.Server, c *localapi.Client, path string) {
	register(s, "commander_list_tools", "List versioned extension tools granted to this coordinator's project.", func(ctx context.Context, _ struct{}) (json.RawMessage, error) {
		return c.Do(ctx, http.MethodGet, path, nil)
	})
	s.AddTool(&mcp.Tool{
		Name:        "commander_call_tool",
		Description: "Call a granted extension by its listed ID and version, with arguments matching its listed input schema.",
		InputSchema: json.RawMessage(`{"type":"object","required":["id","version","arguments"],"additionalProperties":false,"properties":{"id":{"type":"string"},"version":{"type":"integer","minimum":1},"arguments":{"type":"object"}}}`),
	}, func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		// Preserve literal JSON for the service's schema validation and argument decoding.
		data, err := c.Do(ctx, http.MethodPost, path+"/calls", req.Params.Arguments)
		result := &mcp.CallToolResult{}
		if err != nil {
			result.SetError(err)
		} else {
			result.Content = []mcp.Content{&mcp.TextContent{Text: string(data)}}
		}
		return result, nil
	})
}

package mcpbridge

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"

	"agentcommander/internal/localapi"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type networkTarget struct {
	Resource string         `json:"resource" jsonschema:"resource ID returned by discovery"`
	Action   string         `json:"action" jsonschema:"exact action permitted on the resource"`
	Payload  map[string]any `json:"payload" jsonschema:"arguments matching actionContracts[action].payloadSchema returned by discovery"`
}
type networkSubmit struct {
	ID      string          `json:"id" jsonschema:"stable operation ID used for retries of the same intent and for receipt lookup"`
	Targets []networkTarget `json:"targets" jsonschema:"one entry per intended resource and action"`
}
type networkReceipt struct {
	ID string `json:"id" jsonschema:"original operation ID"`
}
type networkInbox struct {
	AfterMessageID string `json:"afterMessageId,omitempty" jsonschema:"last inbox message ID processed; omit to read the retained window"`
	WaitSeconds    int    `json:"waitSeconds,omitempty" jsonschema:"wait up to 10 seconds for a message; omit for an immediate snapshot"`
}
type networkThread struct {
	Request string `json:"request" jsonschema:"request ID for the thread"`
	Text    string `json:"text,omitempty" jsonschema:"comment to add to the thread"`
}

type networkBoard struct {
	Op        string `json:"op,omitempty" jsonschema:"list (default), claim, release, complete or comment"`
	Workspace string `json:"workspace,omitempty" jsonschema:"workspace ID; omit with op list to list workspaces and claims"`
	Card      string `json:"card,omitempty" jsonschema:"card ID for claim, release, complete or comment"`
	Result    string `json:"result,omitempty" jsonschema:"result summary when completing a card"`
	Text      string `json:"text,omitempty" jsonschema:"comment text"`
}

func registerNetworkTools(s *mcp.Server, run, actor, token, path string) error {
	if path == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		path = filepath.Join(home, ".agent-commander", "network.sock")
	}
	c := localapi.New(path, token)
	register(s, "commander_network_inbox", "Read or wait for private messages addressed to this active coordinator. Reuse the last message ID to receive subsequent messages. A peer can reply with agent.message when the owner has shared this coordinator and granted that action.", func(ctx context.Context, in networkInbox) (json.RawMessage, error) {
		return c.Coordinator(ctx, "inbox", run, actor, in)
	})
	register(s, "commander_network_discover", "List granted peer resources and actions, with descriptions and JSON Schema payloads in actionContracts. Select the action from the chosen resource's actions list.", func(ctx context.Context, in struct{}) (json.RawMessage, error) {
		return c.Coordinator(ctx, "discover", run, actor, in)
	})
	register(s, "commander_network_submit", "Send one authorized operation to one or more shared resources. Reuse the same ID to reconcile an uncertain reply.", func(ctx context.Context, in networkSubmit) (json.RawMessage, error) {
		return c.Coordinator(ctx, "submit", run, actor, in)
	})
	register(s, "commander_network_receipt", "Read per-recipient outcomes and results for an operation previously submitted by this coordinator.", func(ctx context.Context, in networkReceipt) (json.RawMessage, error) {
		return c.Coordinator(ctx, "receipt", run, actor, in)
	})
	const limits = " Agents cannot accept friends or create or change grants."
	device := newDeviceCoordinator(path, token, run, actor)
	register(s, "commander_network_online", "List contacts with their presence and shared resources."+limits, func(ctx context.Context, in struct{}) (json.RawMessage, error) {
		return device.post(ctx, "online", json.RawMessage(`{}`))
	})
	mcp.AddTool(s, &mcp.Tool{Name: "commander_network_thread", Description: "Read a request's thread. Include text to add a comment." + limits}, func(ctx context.Context, req *mcp.CallToolRequest, _ networkThread) (*mcp.CallToolResult, any, error) {
		// Forward the validated arguments so an explicitly supplied empty text survives.
		return textResult(device.post(ctx, "thread", req.Params.Arguments))
	})
	register(s, "commander_network_board", "List shared workspaces, their claims and task-board cards, and claim, release, complete or comment on cards in workspaces your owner belongs to."+limits, func(ctx context.Context, in networkBoard) (json.RawMessage, error) {
		b, _ := json.Marshal(in)
		return device.post(ctx, "board", b)
	})
	return nil
}

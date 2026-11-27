package mcpbridge

import (
	"context"
	"os"

	"agentcommander/internal/localapi"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// ToolNames lists the tools Commander registers for a managed session in role,
// so the harness permission policy can be checked against them.
func ToolNames(ctx context.Context, role string) ([]string, error) {
	// Listing calls no service, so the identity and sockets are placeholders.
	server, err := buildServer(ctx, localapi.New(os.DevNull, "catalog"), map[string]string{
		"AGENT_COMMANDER_WORKER_ID": "catalog", "AGENT_COMMANDER_RUN_ID": "catalog",
		"AGENT_COMMANDER_TOKEN": "catalog", "AGENT_COMMANDER_ROLE": role,
		"COMMANDER_NETWORK_SOCKET": os.DevNull,
	}, nil)
	if err != nil {
		return nil, err
	}
	serverSide, clientSide := mcp.NewInMemoryTransports()
	session, err := server.Connect(ctx, serverSide, nil)
	if err != nil {
		return nil, err
	}
	defer session.Close()
	client, err := mcp.NewClient(&mcp.Implementation{Name: "catalog", Version: "0.1.0"}, nil).Connect(ctx, clientSide, nil)
	if err != nil {
		return nil, err
	}
	defer client.Close()
	var names []string
	for tool, err := range client.Tools(ctx, nil) {
		if err != nil {
			return nil, err
		}
		names = append(names, tool.Name)
	}
	return names, nil
}

package provider

import (
	"context"
	"strings"
	"sync"

	"agent-acp.local/sdks/go/runtime"
	"agentcommander/internal/mcpbridge"
)

func configureACPToolTransport(ctx context.Context, j job, config *runtime.Config, a *api) {
	if !j.MCPOverACP || j.SSH != nil || j.BuiltinInstance != "" || j.Codex != nil {
		return
	}
	_, _, policy := agentPolicy(j)
	var allowed []string
	for name := range strings.SplitSeq(policy, ",") {
		if name, ok := strings.CutPrefix(name, "mcp__commander__"); ok {
			allowed = append(allowed, name)
		}
	}
	for i := range config.MCPServers {
		server := &config.MCPServers[i]
		if server.Name != "commander" || server.Command != j.Executable ||
			len(server.Args) != 1 || server.Args[0] != "mcp" {
			continue
		}
		// Do not start even an in-process server until the adapter actually
		// selects and uses the draft transport.
		handler := sync.OnceValues(func() (func(context.Context, runtime.MCPACPRequest) (runtime.MCPACPResponse, error), error) {
			return mcpbridge.NewACPHandler(ctx, a.client, server.Env, allowed)
		})
		server.CallACP = func(callCtx context.Context, request runtime.MCPACPRequest) (runtime.MCPACPResponse, error) {
			call, err := handler()
			if err != nil {
				return runtime.MCPACPResponse{}, err
			}
			return call(callCtx, request)
		}
	}
}

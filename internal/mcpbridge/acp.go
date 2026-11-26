package mcpbridge

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"

	"agent-acp.local/sdks/go/runtime"
	"agentcommander/internal/localapi"
	"github.com/modelcontextprotocol/go-sdk/jsonrpc"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const mcpOutcomeLimit = 1 << 20

// NewACPHandler uses the existing Commander tool server over the stateless MCP
// revision in the ACP draft. The handler is purely in-process.
func NewACPHandler(ctx context.Context, c *localapi.Client, env map[string]string, allowed []string) (func(context.Context, runtime.MCPACPRequest) (runtime.MCPACPResponse, error), error) {
	server, err := buildServer(ctx, c, env, &mcp.ServerOptions{
		SupportedProtocolVersions: []string{runtime.ACPMCPProtocolVersion},
	})
	if err != nil {
		return nil, err
	}
	server.AddReceivingMiddleware(func(next mcp.MethodHandler) mcp.MethodHandler {
		return func(ctx context.Context, method string, req mcp.Request) (mcp.Result, error) {
			if call, ok := req.(*mcp.CallToolRequest); ok && !slices.Contains(allowed, call.Params.Name) {
				return nil, &jsonrpc.Error{Code: jsonrpc.CodeInvalidParams, Message: "tool is outside the Commander assignment scope"}
			}
			result, err := next(ctx, method, req)
			if list, ok := result.(*mcp.ListToolsResult); ok && list != nil {
				list.Tools = slices.DeleteFunc(slices.Clone(list.Tools), func(tool *mcp.Tool) bool {
					return !slices.Contains(allowed, tool.Name)
				})
			}
			return result, err
		}
	})
	handler := mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server {
		return server
	}, &mcp.StreamableHTTPOptions{Stateless: true, PropagateRequestCancellation: true})
	return func(ctx context.Context, req runtime.MCPACPRequest) (runtime.MCPACPResponse, error) {
		return callStatelessMCP(ctx, handler, req)
	}, nil
}

func callStatelessMCP(ctx context.Context, handler http.Handler, req runtime.MCPACPRequest) (runtime.MCPACPResponse, error) {
	// The commander offering publishes tools. Detached subscriptions and the
	// legacy initialize handshake are outside this backend's MCP capabilities.
	switch req.Method {
	case "server/discover", "tools/list", "tools/call", "ping":
	default:
		return mcpError(-32601, "method is unavailable on the Commander MCP server", nil), nil
	}
	var inner struct {
		Name string `json:"name"`
		Meta struct {
			Version      string          `json:"io.modelcontextprotocol/protocolVersion"`
			Capabilities json.RawMessage `json:"io.modelcontextprotocol/clientCapabilities"`
			Info         struct {
				Name, Version string
			} `json:"io.modelcontextprotocol/clientInfo"`
		} `json:"_meta"`
	}
	if err := json.Unmarshal(req.Params, &inner); err != nil || inner.Meta.Version == "" ||
		inner.Meta.Info.Name == "" || inner.Meta.Info.Version == "" ||
		len(inner.Meta.Capabilities) == 0 || inner.Meta.Capabilities[0] != '{' ||
		req.Method == "tools/call" && inner.Name == "" {
		return mcpError(-32602, "required MCP request metadata or tool name is missing", nil), nil
	}
	if inner.Meta.Version != runtime.ACPMCPProtocolVersion {
		return mcpError(-32022, "unsupported MCP protocol version", map[string]any{
			"requested": inner.Meta.Version, "supported": []string{runtime.ACPMCPProtocolVersion},
		}), nil
	}
	wire, err := json.Marshal(struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      string          `json:"id"`
		Method  string          `json:"method"`
		Params  json.RawMessage `json:"params"`
	}{"2.0", req.RequestID, req.Method, req.Params})
	if err != nil {
		return runtime.MCPACPResponse{}, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://localhost/mcp", bytes.NewReader(wire))
	if err != nil {
		return runtime.MCPACPResponse{}, err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json, text/event-stream")
	request.Header.Set("MCP-Protocol-Version", runtime.ACPMCPProtocolVersion)
	request.Header.Set("Mcp-Method", req.Method)
	if inner.Name != "" {
		request.Header.Set("Mcp-Name", inner.Name)
	}
	w := &statelessMCPWriter{headers: make(http.Header), request: req, ctx: ctx}
	handler.ServeHTTP(w, request)
	if err := ctx.Err(); err != nil {
		return runtime.MCPACPResponse{}, err
	}
	if !w.failed && w.headers.Get("Content-Type") == "application/json" {
		w.readMessage(w.body)
	}
	if w.failed || !w.done || w.code != http.StatusOK && len(w.outcome.Error) == 0 {
		return runtime.MCPACPResponse{}, errors.New("stateless MCP backend returned no matching response")
	}
	return w.outcome, nil
}

func mcpError(code int, message string, data any) runtime.MCPACPResponse {
	raw, _ := json.Marshal(struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
		Data    any    `json:"data,omitempty"`
	}{code, message, data})
	return runtime.MCPACPResponse{Error: raw}
}

// statelessMCPWriter relays request-specific SSE notifications immediately
// and retains just one bounded response.
type statelessMCPWriter struct {
	headers      http.Header
	ctx          context.Context
	request      runtime.MCPACPRequest
	outcome      runtime.MCPACPResponse
	body         []byte
	code         int
	failed, done bool
}

func (w *statelessMCPWriter) Header() http.Header { return w.headers }
func (w *statelessMCPWriter) WriteHeader(code int) {
	if w.code == 0 {
		w.code = code
	}
}
func (w *statelessMCPWriter) Flush() {}

func (w *statelessMCPWriter) Write(data []byte) (int, error) {
	w.WriteHeader(http.StatusOK)
	if len(w.body)+len(data) > mcpOutcomeLimit {
		w.failed = true
		return 0, errors.New("stateless MCP response exceeds the binding limit")
	}
	w.body = append(w.body, data...)
	if w.headers.Get("Content-Type") == "text/event-stream" {
		for {
			frame, tail, complete := bytes.Cut(w.body, []byte("\n\n"))
			if !complete {
				break
			}
			for line := range bytes.SplitSeq(frame, []byte("\n")) {
				if value, ok := bytes.CutPrefix(line, []byte("data:")); ok {
					w.readMessage(bytes.TrimSpace(value))
				}
			}
			w.body = tail
		}
	}
	return len(data), nil
}

func (w *statelessMCPWriter) readMessage(raw []byte) {
	var message struct {
		ID     string          `json:"id"`
		Method string          `json:"method"`
		Params json.RawMessage `json:"params"`
		runtime.MCPACPResponse
	}
	if err := json.Unmarshal(raw, &message); err != nil || w.done {
		w.failed = true
		return
	}
	if message.Method != "" && message.ID == "" {
		if w.request.Notify != nil && w.request.Notify(w.ctx, message.Method, message.Params) != nil {
			w.failed = true
		}
		return
	}
	if message.ID != w.request.RequestID || (len(message.Result) == 0) == (len(message.Error) == 0) {
		w.failed = true
		return
	}
	w.outcome, w.done = message.MCPACPResponse, true
}

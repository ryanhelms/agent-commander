package plugins

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"

	"agentcommander/internal/toolregistry"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Meta keys Commander attaches to every tools/call it sends a plugin.
const (
	MetaScope    = "agentcommander/scope"
	MetaSettings = "agentcommander/settings"
)

const maxResultBytes = 1 << 20

// Host owns the supervised processes of every installed plugin for one service.
type Host struct {
	stateDir    string
	tools       []toolregistry.Tool
	supervisors []*supervisor
	// Problems lists plugins that are installed but refused, such as one whose
	// files changed since install. Their tools stay registered so existing
	// grants still load, and every call reports them unavailable.
	Problems  []error
	closeOnce sync.Once
}

// Load reads installed.json and prepares a registry tool for every
// contributed tool. Processes start only when a granted tool is bound.
func Load(stateDir string) (*Host, error) {
	installed, err := List(stateDir)
	if err != nil {
		return nil, err
	}
	host := &Host{stateDir: stateDir}
	for _, record := range installed {
		var refused error
		if err := record.check(stateDir); err != nil {
			refused = fmt.Errorf("plugin %s %s refused: %w", record.ID, record.Version, err)
			host.Problems = append(host.Problems, refused)
		}
		record := record
		sup := newSupervisor(record.launch(stateDir), func() error { return record.check(stateDir) })
		host.supervisors = append(host.supervisors, sup)
		for _, tool := range record.Tools {
			host.tools = append(host.tools, host.registryTool(record, tool, sup, refused))
		}
	}
	return host, nil
}

// Tools returns registry tools to pass to toolregistry.Load.
func (h *Host) Tools() []toolregistry.Tool {
	if h == nil {
		return nil
	}
	return h.tools
}

// Close stops every plugin process.
func (h *Host) Close() {
	if h == nil {
		return
	}
	h.closeOnce.Do(func() {
		for _, s := range h.supervisors {
			s.close()
		}
	})
}

// check verifies that the installed files still match the pinned digest.
func (r Record) check(stateDir string) error {
	digest, err := Digest(r.Dir(stateDir))
	if err != nil {
		return fmt.Errorf("read installed files: %w", err)
	}
	if digest != r.Digest {
		return errors.New("installed files no longer match the digest pinned at install; reinstall the plugin")
	}
	return nil
}

func (h *Host) registryTool(record Record, tool ToolRecord, sup *supervisor, refused error) toolregistry.Tool {
	return toolregistry.Tool{
		Descriptor: toolregistry.Descriptor{
			ID: tool.ID, Version: tool.Version, Action: toolregistry.Read,
			Description: tool.Description, InputSchema: tool.InputSchema,
		},
		Bind: func(raw json.RawMessage) (toolregistry.Handler, error) {
			if refused != nil {
				return func(context.Context, toolregistry.Scope, map[string]any) (json.RawMessage, error) {
					return nil, toolregistry.ErrUnavailable
				}, nil
			}
			if err := validateSettings(record, raw); err != nil {
				return nil, err
			}
			var settings any
			if len(raw) != 0 {
				if err := json.Unmarshal(raw, &settings); err != nil {
					return nil, err
				}
			}
			sup.warm()
			return func(ctx context.Context, scope toolregistry.Scope, args map[string]any) (json.RawMessage, error) {
				return call(ctx, sup, tool.MCPTool, args, scope, settings)
			}, nil
		},
	}
}

// call is the Adapter from a registry handler to an MCP tools/call.
func call(ctx context.Context, sup *supervisor, name string, args map[string]any, scope toolregistry.Scope, settings any) (json.RawMessage, error) {
	session, generation, err := sup.get(ctx)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, toolregistry.ErrUnavailable
	}
	meta := mcp.Meta{MetaScope: map[string]string{
		"run_id": scope.RunID, "worker_id": scope.WorkerID, "project_path": scope.ProjectPath,
	}}
	if settings != nil {
		meta[MetaSettings] = settings
	}
	result, err := session.CallTool(ctx, &mcp.CallToolParams{Meta: meta, Name: name, Arguments: args})
	if err != nil {
		// A missed deadline or broken pipe leaves the process in an unknown
		// state. Stop it; the next call starts a fresh one.
		sup.discard(generation)
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, toolregistry.ErrUnavailable
	}
	return encodeResult(result)
}

// encodeResult turns an MCP result into the JSON a scoped tool returns.
// Structured content wins; otherwise a single JSON text block passes through
// and any other text is wrapped. A tool error becomes {"error": text} so the
// agent can see why the plugin refused.
func encodeResult(result *mcp.CallToolResult) (json.RawMessage, error) {
	var texts []string
	omitted := 0
	for _, content := range result.Content {
		if text, ok := content.(*mcp.TextContent); ok {
			texts = append(texts, text.Text)
		} else {
			omitted++
		}
	}
	joined := strings.Join(texts, "\n")
	var out []byte
	var err error
	switch {
	case result.IsError:
		out, err = json.Marshal(map[string]string{"error": joined})
	case result.StructuredContent != nil:
		out, err = json.Marshal(result.StructuredContent)
	case len(texts) == 1 && omitted == 0 && json.Valid([]byte(joined)):
		out = []byte(joined)
	default:
		body := map[string]any{"text": joined}
		if omitted > 0 {
			body["omitted_content"] = omitted
		}
		out, err = json.Marshal(body)
	}
	if err != nil {
		return nil, err
	}
	if len(out) > maxResultBytes {
		return nil, errors.New("plugin result exceeds 1 MiB")
	}
	return out, nil
}

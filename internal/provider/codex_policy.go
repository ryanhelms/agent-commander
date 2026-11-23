package provider

import (
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
)

type codexPolicy struct {
	Checkout     string
	Server       mcpServer
	Tools        []string
	Instructions string
}

type codexRPC struct {
	ID     json.RawMessage            `json:"id,omitempty"`
	Method string                     `json:"method,omitempty"`
	Params map[string]json.RawMessage `json:"params,omitempty"`
}

func rpcValue(value any) json.RawMessage {
	raw, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return raw
}

// apply builds a new native request from the supported fields. Configuration
// supplied by the ACP adapter cannot override checkout trust or tool policy.
func (p codexPolicy) apply(r *codexRPC, threadID string) error {
	switch r.Method {
	case "thread/start":
		if threadID != "" {
			return errors.New("the managed Codex connection already owns a thread")
		}
		return p.sessionRequest(r, false)
	case "thread/resume":
		if err := requireCodexThread(r, threadID); err != nil {
			return err
		}
		return p.sessionRequest(r, true)
	case "turn/start":
		if err := requireCodexThread(r, threadID); err != nil {
			return err
		}
		r.Params = codexFields(r.Params, "threadId", "input", "clientUserMessageId", "effort")
		r.Params["approvalPolicy"] = rpcValue("never")
		r.Params["sandboxPolicy"] = rpcValue(map[string]any{"type": "readOnly", "networkAccess": false})
		r.Params["approvalsReviewer"] = rpcValue("user")
		return nil
	case "turn/interrupt", "thread/read", "thread/turns/list", "thread/unsubscribe", "mcpServerStatus/list":
		return requireCodexThread(r, threadID)
	case "initialize", "initialized", "account/read", "model/list", "skills/list",
		"config/read", "configRequirements/read", "experimentalFeature/list", "permissionProfile/list",
		"account/rateLimits/read", "thread/loaded/list":
		return nil
	default:
		return fmt.Errorf("native method %q is outside the managed Codex session policy", r.Method)
	}
}

func (p codexPolicy) sessionRequest(r *codexRPC, resume bool) error {
	var cwd string
	if raw := r.Params["cwd"]; len(raw) != 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &cwd); err != nil || !filepath.IsAbs(cwd) {
			return errors.New("Codex requested an invalid checkout")
		}
		resolved, err := filepath.EvalSymlinks(cwd)
		if err != nil || resolved != p.Checkout {
			return errors.New("Codex requested a different checkout")
		}
	}
	fields := []string{"model"}
	if resume {
		fields = append(fields, "threadId", "excludeTurns")
	}
	r.Params = codexFields(r.Params, fields...)
	r.Params["cwd"] = rpcValue(p.Checkout)
	r.Params["approvalPolicy"] = rpcValue("never")
	r.Params["approvalsReviewer"] = rpcValue("user")
	r.Params["sandbox"] = rpcValue("read-only")
	r.Params["developerInstructions"] = rpcValue(p.Instructions)
	env := p.Server.Env
	if env == nil {
		env = map[string]string{}
	}
	toolPolicy := make(map[string]map[string]string, len(p.Tools))
	for _, name := range p.Tools {
		toolPolicy[name] = map[string]string{"approval_mode": "approve"}
	}
	r.Params["config"] = rpcValue(map[string]any{
		"projects": map[string]any{p.Checkout: map[string]string{"trust_level": "untrusted"}},
		"features": map[string]bool{
			"plugins": false, "apps": false, "multi_agent": false, "shell_tool": false,
			"goals": false, "view_image": false, "image_generation": false,
			"request_permissions_tool": false, "skill_mcp_dependency_install": false,
		},
		"web_search": "disabled",
		"hooks":      map[string]any{},
		"mcp_servers": map[string]any{"commander": map[string]any{
			"command": p.Server.Command, "args": p.Server.Args, "env": env,
			"enabled_tools": p.Tools, "required": true, "tools": toolPolicy,
		}},
	})
	return nil
}

func codexFields(in map[string]json.RawMessage, names ...string) map[string]json.RawMessage {
	out := make(map[string]json.RawMessage, len(names))
	for _, name := range names {
		if value, ok := in[name]; ok {
			out[name] = value
		}
	}
	return out
}

func requireCodexThread(r *codexRPC, threadID string) error {
	var target string
	if threadID == "" || json.Unmarshal(r.Params["threadId"], &target) != nil || target != threadID {
		return errors.New("native operation addresses a different Codex thread")
	}
	return nil
}

package provider

import (
	"slices"
	"strings"
	"testing"

	"agentcommander/internal/mcpbridge"
	"agentcommander/internal/worktrees"
)

// Claude CLI, Claude ACP, Codex and MCP-over-ACP all take their Commander tools
// from agentPolicy and deny the rest. Every registered tool must therefore be
// allowed, or withheld here on purpose.
func TestManagedPolicyCoversRegisteredTools(t *testing.T) {
	supervision := []string{
		"commander_delegate", "commander_reply", "commander_reconcile_reply", "commander_integrate",
		"commander_send", "commander_interrupt", "commander_stop_worker",
	}
	for _, test := range []struct {
		name     string
		role     string
		coding   bool
		withheld []string
	}{
		// The service offers app tools to workers only.
		{"coordinator", "coordinator", false, []string{"commander_commit", "commander_frontend_tools", "commander_call_frontend"}},
		{"worker", "worker", false, append([]string{"commander_commit"}, supervision...)},
		{"coding worker", "worker", true, supervision},
	} {
		t.Run(test.name, func(t *testing.T) {
			var j job
			j.Worker.Role = test.role
			if test.coding {
				j.Worker.CodingSource = &worktrees.Checkout{}
			}
			_, _, policy := agentPolicy(j)
			var allowed []string
			for entry := range strings.SplitSeq(policy, ",") {
				if name, ok := strings.CutPrefix(entry, "mcp__commander__"); ok {
					allowed = append(allowed, name)
				}
			}
			registered, err := mcpbridge.ToolNames(t.Context(), test.role)
			if err != nil {
				t.Fatal(err)
			}
			for _, name := range registered {
				if slices.Contains(allowed, name) == slices.Contains(test.withheld, name) {
					t.Errorf("%s must be either allowed or withheld, not both or neither", name)
				}
			}
			for _, name := range slices.Concat(allowed, test.withheld) {
				if !slices.Contains(registered, name) {
					t.Errorf("%s is in the policy but Commander does not register it", name)
				}
			}
		})
	}
}

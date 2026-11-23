package provider

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"agentcommander/internal/service"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const devflowTool = "devflow_ui_open"

func devflowArgs() []string { return []string{"mcp", "--ui-only", "--client", "agent-commander"} }

// Only the service selects companion executables. A run's checkout, PATH and
// MCP files cannot supply a program for the coordinator to execute.
func devflowExecutable() string {
	if override := os.Getenv("AGENT_COMMANDER_DEVFLOW"); override != "" {
		if !filepath.IsAbs(override) {
			return ""
		}
		path, _ := exec.LookPath(override)
		return path
	}
	dirs := []string{"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"}
	if home, err := os.UserHomeDir(); err == nil && filepath.IsAbs(home) {
		dirs = append([]string{filepath.Join(home, ".local", "bin")}, dirs...)
	}
	for _, dir := range dirs {
		if path, err := exec.LookPath(filepath.Join(dir, "devflow")); err == nil {
			return path
		}
	}
	return ""
}

// A missing or older Devflow installation leaves a regular planning run
// available. Test the actual MCP surface in its target checkout.
func coordinatorDevflow(ctx context.Context, worker service.LaunchSpec) string {
	if worker.Role != "coordinator" || os.Getenv("AGENT_COMMANDER_FOCUSED_PROOF") == "1" {
		return ""
	}
	path := devflowExecutable()
	if path == "" {
		return ""
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, devflowArgs()...)
	cmd.Dir = worker.Path
	client := mcp.NewClient(&mcp.Implementation{Name: "agent-commander-discovery", Version: "1"}, nil)
	session, err := client.Connect(ctx, &mcp.CommandTransport{Command: cmd, TerminateDuration: 150 * time.Millisecond}, nil)
	if err != nil {
		return ""
	}
	defer session.Close()
	list, err := session.ListTools(ctx, nil)
	if err != nil || list.NextCursor != "" || len(list.Tools) != 1 || list.Tools[0] == nil || list.Tools[0].Name != devflowTool {
		return ""
	}
	return path
}

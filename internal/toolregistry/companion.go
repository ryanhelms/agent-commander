package toolregistry

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Companion is a trusted, first-party MCP attachment. The restricted probe
// runs before the harness receives the registered tool and live actor binding.
type Companion struct {
	ID                  string
	Version             int
	Server, Tool        string
	ProbeArgs, LiveArgs []string
	Instructions        string
	Unavailable         string
	FindExecutable      func() string
}

// CompanionScope describes the actual launch selected by the provider.
type CompanionScope struct {
	ProjectPath, Role, Host string
	Interactive             bool
}

func (s CompanionScope) Eligible() bool {
	// Old local launch records can omit Host.
	return s.Interactive && s.Role == "coordinator" && (s.Host == "" || s.Host == "localhost")
}

// CompanionBinding is the selection sent in the private launch record. Only
// live connections receive the coordinator's credential from the runner.
type CompanionBinding struct {
	ID           string
	Version      int
	Server, Tool string
	Command      string   `json:",omitempty"`
	Args         []string `json:",omitempty"`
	Instructions string
}

// RegisterCompanion adds a built-in attachment before the registry is shared
// with the launcher and service.
func (r *Registry) RegisterCompanion(c Companion) error {
	if !toolID.MatchString(c.ID) || len(c.ID) > 64 || c.Version < 1 || !companionName(c.Server) ||
		c.Server == "commander" || !companionName(c.Tool) || c.FindExecutable == nil {
		return fmt.Errorf("invalid scoped companion registration %q", c.ID)
	}
	if _, exists := r.registered[c.ID]; exists || slices.ContainsFunc(r.companions, func(other Companion) bool {
		return other.ID == c.ID || other.Server == c.Server
	}) {
		return fmt.Errorf("duplicate scoped companion registration %q or server %q", c.ID, c.Server)
	}
	c.ProbeArgs = slices.Clone(c.ProbeArgs)
	c.LiveArgs = slices.Clone(c.LiveArgs)
	r.companions = append(r.companions, c)
	return nil
}

func companionName(name string) bool {
	return name != "" && strings.IndexFunc(name, func(ch rune) bool {
		return (ch < 'a' || ch > 'z') && (ch < '0' || ch > '9') && ch != '_'
	}) == -1
}

func (r *Registry) BindCompanions(ctx context.Context, scope CompanionScope) []CompanionBinding {
	if r == nil || !scope.Eligible() {
		return nil
	}
	bindings := make([]CompanionBinding, 0, len(r.companions))
	for _, companion := range r.companions {
		path := companion.probe(ctx, scope.ProjectPath)
		bindings = append(bindings, companion.Binding(path))
	}
	return bindings
}

// Binding builds the live attachment from a previously verified executable.
// A missing executable carries the fallback instructions.
func (c Companion) Binding(path string) CompanionBinding {
	binding := CompanionBinding{ID: c.ID, Version: c.Version, Server: c.Server, Tool: c.Tool, Instructions: c.Unavailable}
	if filepath.IsAbs(path) {
		binding.Command, binding.Args, binding.Instructions = path, slices.Clone(c.LiveArgs), c.Instructions
	}
	return binding
}

func (c Companion) probe(ctx context.Context, projectPath string) string {
	path := c.FindExecutable()
	if !filepath.IsAbs(path) {
		return ""
	}
	path, err := filepath.EvalSymlinks(path)
	if err != nil {
		return ""
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, c.ProbeArgs...)
	cmd.Dir = projectPath
	cmd.Env = slices.DeleteFunc(os.Environ(), func(entry string) bool {
		key, _, _ := strings.Cut(entry, "=")
		switch key {
		case "AGENT_COMMANDER_TOKEN", "AGENT_COMMANDER_SOCKET", "AGENT_COMMANDER_WORKER_ID", "AGENT_COMMANDER_RUN_ID", "AGENT_COMMANDER_ROLE":
			return true
		default:
			return false
		}
	})
	client := mcp.NewClient(&mcp.Implementation{Name: "agent-commander-discovery", Version: "1"}, nil)
	session, err := client.Connect(ctx, &mcp.CommandTransport{Command: cmd, TerminateDuration: 150 * time.Millisecond}, nil)
	if err != nil {
		return ""
	}
	defer session.Close()
	list, err := session.ListTools(ctx, nil)
	if err != nil || list.NextCursor != "" || len(list.Tools) != 1 || list.Tools[0] == nil || list.Tools[0].Name != c.Tool {
		return ""
	}
	return path
}

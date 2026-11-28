package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"agentcommander/internal/linear"
	"agentcommander/internal/plugins"
)

const pluginUsage = `usage:
  agentctl plugin install DIRECTORY       Install or upgrade a plugin package
  agentctl plugin list                    List installed plugins and their tools
  agentctl plugin grant TOOL@VERSION --project DIRECTORY [--settings JSON]
                                          Allow a plugin tool in one project checkout
  agentctl plugin revoke TOOL [--project DIRECTORY]
                                          Withdraw a tool from one project, or from all
  agentctl plugin remove ID               Uninstall a plugin and withdraw its grants
Grants take effect when the service restarts (make reload SERVICE=1).`

// compiledToolIDs are the scoped tool IDs agentctl registers itself; plugins
// cannot reuse them.
func compiledToolIDs() []string { return []string{linear.IssueReadID} }

func pluginCommand(ctx context.Context, stateDir string, args []string) error {
	if len(args) == 0 {
		return errors.New(pluginUsage)
	}
	out := json.NewEncoder(os.Stdout)
	out.SetIndent("", "  ")
	switch args[0] {
	case "install":
		if len(args) != 2 {
			return errors.New("usage: agentctl plugin install DIRECTORY")
		}
		src, err := filepath.Abs(args[1])
		if err != nil {
			return err
		}
		record, err := plugins.Install(ctx, stateDir, src, plugins.InstallOptions{Reserved: compiledToolIDs()})
		if err != nil {
			return err
		}
		fmt.Fprintf(os.Stderr, "Installed %s %s. Nothing is granted yet; run agentctl plugin grant TOOL@VERSION --project DIRECTORY.\n", record.ID, record.Version)
		return out.Encode(record)
	case "list":
		if len(args) != 1 {
			return errors.New("usage: agentctl plugin list")
		}
		records, err := plugins.List(stateDir)
		if err != nil {
			return err
		}
		host, err := plugins.Load(stateDir)
		if err != nil {
			return err
		}
		defer host.Close()
		type listed struct {
			plugins.Record
			Problem string `json:"problem,omitempty"`
		}
		rows := make([]listed, 0, len(records))
		for _, r := range records {
			row := listed{Record: r}
			for _, problem := range host.Problems {
				if strings.HasPrefix(problem.Error(), "plugin "+r.ID+" ") {
					row.Problem = problem.Error()
				}
			}
			rows = append(rows, row)
		}
		return out.Encode(rows)
	case "grant":
		tool, version, project, settings, err := parseGrantArgs(args[1:])
		if err != nil {
			return err
		}
		if err := plugins.Grant(stateDir, tool, version, project, settings); err != nil {
			return err
		}
		fmt.Fprintf(os.Stderr, "Granted %s@%d to %s. Restart the service to apply it.\n", tool, version, project)
		return nil
	case "revoke":
		if len(args) != 2 && !(len(args) == 4 && args[2] == "--project") {
			return errors.New("usage: agentctl plugin revoke TOOL [--project DIRECTORY]")
		}
		project := ""
		if len(args) == 4 {
			project = args[3]
		}
		return plugins.Revoke(stateDir, args[1], project)
	case "remove":
		if len(args) != 2 {
			return errors.New("usage: agentctl plugin remove ID")
		}
		record, err := plugins.Remove(stateDir, args[1])
		if err != nil {
			return err
		}
		fmt.Fprintf(os.Stderr, "Removed %s %s and withdrew its grants.\n", record.ID, record.Version)
		return nil
	}
	return errors.New(pluginUsage)
}

func parseGrantArgs(args []string) (tool string, version int, project string, settings json.RawMessage, err error) {
	usage := errors.New("usage: agentctl plugin grant TOOL@VERSION --project DIRECTORY [--settings JSON]")
	if len(args) == 0 {
		return "", 0, "", nil, usage
	}
	id, rawVersion, ok := strings.Cut(args[0], "@")
	if !ok {
		return "", 0, "", nil, usage
	}
	version, err = strconv.Atoi(rawVersion)
	if err != nil || version < 1 {
		return "", 0, "", nil, errors.New("tool version must be a positive integer, as in acme.jira.get_issue@1")
	}
	for rest := args[1:]; len(rest) > 0; rest = rest[2:] {
		if len(rest) < 2 {
			return "", 0, "", nil, usage
		}
		switch rest[0] {
		case "--project":
			project = rest[1]
		case "--settings":
			if !json.Valid([]byte(rest[1])) {
				return "", 0, "", nil, errors.New("--settings must be JSON")
			}
			settings = json.RawMessage(rest[1])
		default:
			return "", 0, "", nil, usage
		}
	}
	if project == "" {
		return "", 0, "", nil, usage
	}
	project, err = filepath.Abs(project)
	return id, version, project, settings, err
}

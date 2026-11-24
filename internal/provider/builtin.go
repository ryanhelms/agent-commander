package provider

import (
	"context"
	"errors"
	"fmt"
	"strings"

	model "agent-acp.local/sdks/go/model"
	"agentcommander/harness"
)

func selectedBuiltin(client string) (harness.Adapter, bool, error) {
	id, selected := strings.CutPrefix(strings.ToLower(strings.TrimSpace(client)), "builtin:")
	if !selected {
		return harness.Adapter{}, false, nil
	}
	adapter, ok := harness.Lookup(id)
	if !ok {
		return harness.Adapter{}, true, fmt.Errorf("built-in adapter %q is unavailable in this Commander build", id)
	}
	return adapter, true, nil
}

// The runner and passive reader both resolve the saved version before opening
// any provider resources. Rebuilding Commander must not rebind old sessions.
func boundBuiltin(instance string) (harness.Adapter, error) {
	name, builtin := strings.CutPrefix(instance, "local-builtin:")
	id, _, versioned := strings.Cut(name, "@")
	a, ok := harness.Lookup(id)
	if !builtin || !versioned || !ok || a.Instance() != instance {
		return harness.Adapter{}, fmt.Errorf("original built-in adapter %q is unavailable in this Commander build", instance)
	}
	return a, nil
}

func builtinHistory(adapter harness.Adapter, cwd string) historyReader {
	if adapter.ReadHistory == nil {
		return nil
	}
	return func(ctx context.Context, req *model.ReadHistoryRequest) (*model.ReadHistoryResponse, error) {
		page, err := adapter.ReadHistory(ctx, cwd, req)
		if err != nil {
			return nil, err
		}
		if page == nil || (req.Limit > 0 && uint32(len(page.Observations)) > req.Limit) {
			return nil, errors.New("built-in adapter returned an invalid history page")
		}
		for _, obs := range page.Observations {
			if !sameSession(obs.GetSession(), req.Session) {
				return nil, errors.New("built-in history does not belong to the selected session")
			}
		}
		return page, nil
	}
}

func sameSession(a, b *model.SessionRef) bool {
	return a != nil && b != nil && a.HarnessInstance == b.HarnessInstance && a.SessionId == b.SessionId
}

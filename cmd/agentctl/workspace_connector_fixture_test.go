package main

import (
	"context"
	"encoding/json"
	"errors"
	"sync/atomic"

	"agentcommander/internal/toolregistry"
)

const fixtureWorkspaceReadID = "fixture.workspace.read"

// workspaceReadFixture depends only on the registry's connector contract.
func workspaceReadFixture(calls *atomic.Int32) toolregistry.Tool {
	return toolregistry.Tool{
		Descriptor: toolregistry.Descriptor{
			ID: fixtureWorkspaceReadID, Version: 1, Action: toolregistry.Read,
			Description: "Read the workspace label from the test project grant.",
			InputSchema: json.RawMessage(`{"type":"object","required":["key"],"additionalProperties":false,"properties":{"key":{"type":"string","enum":["label","pending"]}}}`),
		},
		Bind: func(raw json.RawMessage) (toolregistry.Handler, error) {
			var settings struct {
				Label string `json:"label"`
			}
			if err := json.Unmarshal(raw, &settings); err != nil || settings.Label == "" {
				return nil, errors.New("fixture workspace grant requires a label")
			}
			return func(ctx context.Context, _ toolregistry.Scope, args map[string]any) (json.RawMessage, error) {
				calls.Add(1)
				if args["key"] == "pending" {
					<-ctx.Done()
					return nil, ctx.Err()
				}
				return json.Marshal(map[string]string{"label": settings.Label})
			}, nil
		},
	}
}

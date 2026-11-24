// Command listcheck verifies a scoped, empty-workspace listing through the
// installed portable SDK. Its output contains no session metadata.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"runtime/debug"
	"time"

	agentacp "agent-acp.local/sdks/go"
	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) < 2 {
		return errors.New("usage: listcheck EMPTY_DIRECTORY EXECUTABLE [ARG...]")
	}
	items, err := os.ReadDir(args[0])
	if err != nil || len(items) != 0 {
		return errors.New("pass an existing empty working directory")
	}
	const harness = "compatibility-probe"
	rt, err := runtime.New(runtime.Config{HarnessInstance: harness, WorkingDirectory: args[0], Command: args[1], Args: args[2:]})
	if err != nil {
		return err
	}
	defer rt.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	client := agentacp.New(rt)
	req := &model.ListSessionsRequest{HarnessInstance: harness, WorkingDirectory: args[0], Limit: 4}
	seen := make(map[string]bool)
	for {
		page, err := client.ListSessions(ctx, req)
		if err != nil {
			return errors.New("the portable SDK could not complete the scoped listing")
		}
		if len(page.Sessions) != 0 {
			return errors.New("portable SDK returned sessions outside the new empty directory")
		}
		if page.NextCursor == "" {
			break
		}
		if seen[page.NextCursor] {
			return errors.New("the portable SDK repeated a listing cursor")
		}
		seen[page.NextCursor] = true
		req.Cursor = page.NextCursor
	}
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return errors.New("missing Go build metadata")
	}
	type modulePin struct {
		Sum     string `json:"sum"`
		Version string `json:"version"`
	}
	var result struct {
		modulePin
		Transport *modulePin `json:"transport,omitempty"`
	}
	for _, dep := range info.Deps {
		if dep.Path != "agent-acp.local/sdks/go" && dep.Path != "agent-acp.local/transport" {
			continue
		}
		if dep.Replace != nil || dep.Sum == "" {
			return fmt.Errorf("build this probe against the pinned %s archive", dep.Path)
		}
		pin := modulePin{Sum: dep.Sum, Version: dep.Version}
		if dep.Path == "agent-acp.local/sdks/go" {
			result.modulePin = pin
		} else {
			result.Transport = &pin
		}
	}
	if result.Version == "" {
		return errors.New("build this probe against the pinned SDK archive")
	}
	return json.NewEncoder(os.Stdout).Encode(result)
}

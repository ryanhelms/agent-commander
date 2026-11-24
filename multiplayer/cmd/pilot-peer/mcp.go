//go:build pilotfixture

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"slices"
	"strings"
	"time"
)

// Probe the same newline-delimited JSON-RPC transport that a managed harness
// uses. Authorization flows from the local coordinator binding into agentctl.
func probeMCP(parent context.Context, receiptID string, submission json.RawMessage) error {
	ctx, cancel := context.WithTimeout(parent, 35*time.Second)
	defer cancel()
	b, err := os.ReadFile(stateDir + "/actor.json")
	var ids actors
	if err != nil || json.Unmarshal(b, &ids) != nil || ids.Main.Token == "" {
		return errors.New("local coordinator binding unavailable")
	}
	cmd := exec.CommandContext(ctx, "/usr/local/bin/agentctl", "mcp")
	cmd.Env = []string{"PATH=/usr/bin:/bin", "HOME=" + stateDir, "AGENT_COMMANDER_HOME=" + stateDir,
		"AGENT_COMMANDER_SOCKET=" + commanderSocket, "COMMANDER_NETWORK_SOCKET=" + networkSocket,
		"AGENT_COMMANDER_ROLE=coordinator", "AGENT_COMMANDER_RUN_ID=" + ids.Main.Run,
		"AGENT_COMMANDER_WORKER_ID=" + ids.Main.Worker, "AGENT_COMMANDER_TOKEN=" + ids.Main.Token}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err = cmd.Start(); err != nil {
		return err
	}
	defer func() { _ = stdin.Close(); _ = cmd.Wait() }()
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 4096), 4<<20)
	write := json.NewEncoder(stdin)
	nextID := 0
	request := func(method string, params any, out any) error {
		nextID++
		if err := write.Encode(map[string]any{"jsonrpc": "2.0", "method": method, "params": params, "id": nextID}); err != nil {
			return err
		}
		for scanner.Scan() {
			var response struct {
				JSONRPC string
				ID      *int
				Error   *struct{ Code int }
				Result  json.RawMessage
			}
			if json.Unmarshal(scanner.Bytes(), &response) != nil || response.JSONRPC != "2.0" {
				return errors.New("invalid MCP frame")
			}
			if response.ID == nil {
				continue
			} // server notification
			if *response.ID != nextID || response.Error != nil {
				return fmt.Errorf("agentctl rejected MCP operation %s", method)
			}
			return json.Unmarshal(response.Result, out)
		}
		if err := scanner.Err(); err != nil {
			return err
		}
		return errors.New("agentctl closed its MCP stream before replying")
	}
	var init struct{ ProtocolVersion string }
	if err = request("initialize", map[string]any{"protocolVersion": "2025-06-18", "clientInfo": map[string]string{"name": "docker-pilot", "version": "1"}, "capabilities": map[string]any{}}, &init); err != nil {
		return err
	}
	if init.ProtocolVersion != "2025-06-18" {
		return errors.New("unexpected negotiated MCP version")
	}
	if err = write.Encode(map[string]string{"jsonrpc": "2.0", "method": "notifications/initialized"}); err != nil {
		return err
	}
	var list struct{ Tools []struct{ Name string } }
	if err = request("tools/list", struct{}{}, &list); err != nil {
		return err
	}
	names := []string{}
	for _, tool := range list.Tools {
		if strings.HasPrefix(tool.Name, "commander_network_") {
			names = append(names, tool.Name)
		}
	}
	for _, op := range []string{"discover", "inbox", "submit", "receipt"} {
		if !slices.Contains(names, "commander_network_"+op) {
			return fmt.Errorf("coordinator tool %s unavailable", op)
		}
	}
	call := func(op string, args any) (json.RawMessage, error) {
		var result struct {
			IsError bool
			Content []struct{ Type, Text string }
		}
		if err := request("tools/call", map[string]any{"name": "commander_network_" + op, "arguments": args}, &result); err != nil {
			return nil, err
		}
		if result.IsError || len(result.Content) != 1 || result.Content[0].Type != "text" {
			return nil, fmt.Errorf("MCP tool %s did not return a result", op)
		}
		var reply struct {
			OK   bool
			Data json.RawMessage
		}
		if json.Unmarshal([]byte(result.Content[0].Text), &reply) != nil || !reply.OK || len(reply.Data) == 0 {
			return nil, errors.New("peer denied MCP network operation")
		}
		return reply.Data, nil
	}
	discovery, err := call("discover", struct{}{})
	if err != nil {
		return err
	}
	out := map[string]any{"tools": names, "discover": discovery}
	if submission != nil {
		v, err := call("submit", submission)
		if err != nil {
			return err
		}
		out["submission"] = v
	}
	if receiptID != "" {
		v, err := call("receipt", map[string]string{"id": receiptID})
		if err != nil {
			return err
		}
		out["receipt"] = v
	}
	return json.NewEncoder(os.Stdout).Encode(out)
}

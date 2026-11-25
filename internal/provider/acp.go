package provider

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"slices"
	"strings"
	"time"

	agentacp "agent-acp.local/sdks/go"
	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"
	"agentcommander/harness"
	"agentcommander/internal/acpprocessor"
	"agentcommander/internal/localapi"
	"agentcommander/internal/service"
)

var errACPDisconnected = errors.New("live provider connection disconnected")

var errACPObservationGap = errors.New("live provider observations expired")

const managedClaudeModel = "opus"

// The runner owns the session, scopes MCP to this job and passes only the
// native session identity to Commander. Output is a live projection.
func runACP(ctx context.Context, j job, a *api, s *screen) error {
	policyJob := j
	cwd := j.Worker.Path
	var args []string
	var persistent *persistentProxy
	if j.SSH != nil {
		socket, closeForward, err := startWorkerForward(j.Socket, j.Worker.Token)
		if err != nil {
			return fmt.Errorf("start worker API forward: %w", err)
		}
		defer closeForward()
		if j.SSH.Persistent {
			persistent = &persistentProxy{Profile: *j.SSH, Worker: j.Worker.ID, LocalSocket: socket, OwnerSocket: j.Socket}
			if err := persistent.start(ctx); err != nil {
				return err
			}
			defer persistent.stop()
			policyJob.Socket = persistentAPI(j.Worker.ID)
		} else {
			args, policyJob.Socket = j.SSH.sessionArgs(j.Worker, socket)
		}
		policyJob.Executable = j.SSH.Agentctl
		cwd = j.SSH.Checkout
	}
	config, err := planningConfig(policyJob)
	if err != nil {
		return err
	}
	if j.SSH != nil {
		config.HarnessInstance = j.SSH.harnessInstance()
		config.Args = args
	}
	if persistent != nil {
		data, err := json.Marshal(persistent)
		if err != nil {
			return err
		}
		config.Command, config.Args = j.Executable, []string{"persistent-acp", "proxy"}
		if config.Env == nil {
			config.Env = make(map[string]string)
		}
		config.Env[persistentACPConfig] = string(data)
		for i := range config.MCPServers {
			config.MCPServers[i].Env["AGENT_COMMANDER_PERSISTENT_SSH_WAIT"] = "1"
		}
	}
	setACPNodePath(&config, j.NodePath)
	j.ACPBroker.apply(&config, j.Executable)
	stderr := &lineWriter{s: s}
	config.Stderr = stderr
	if err := configureACPProtocol(&config); err != nil {
		return err
	}
	configureACPActivity(&config)
	if resume := j.Worker.Reattach; resume != nil {
		config.ModelOnResume = acpOpenRequest(j, config.HarnessInstance, cwd).GetModel()
		if resume.ProtocolVersion != 0 {
			config.ProtocolVersion = resume.ProtocolVersion
		}
	}
	configureACPElicitation(j, &config, a, s)

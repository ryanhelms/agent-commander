// Package provider runs managed Claude conversations in dedicated tmux panes.
package provider

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"agentcommander/internal/service"
	"agentcommander/internal/toolregistry"
	"agentcommander/internal/worktrees"
)

type Local struct {
	stateDir, socket, executable, label string
	acpProfiles                         map[string]acpProfile
	replaySlot                          chan struct{}
	replayCache                         replayCache
	acpBroker                           *acpBrokerService
	tools                               *toolregistry.Registry
}

type job struct {
	Worker                            service.LaunchSpec
	Socket, Executable, Claude, Label string
		ACPElicitation:  os.Getenv("AGENT_COMMANDER_ACP_ELICITATION") == "1",

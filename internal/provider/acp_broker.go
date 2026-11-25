package provider

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"

	"agent-acp.local/sdks/go/broker"
	"agent-acp.local/sdks/go/runtime"
)

const (
	acpBrokerSocket = "AGENT_COMMANDER_BROKER_SOCKET"
	acpBrokerTicket = "AGENT_COMMANDER_BROKER_TICKET"
)

type acpBrokerService struct {
	owner  *broker.Broker
	socket string
	mode   string
	mu     sync.Mutex
	pins   map[providerFileIdentity]string
}

type acpBrokerLease struct {
	Socket string
	Ticket string
}

// EnableACPBroker starts the owner-side service for an explicit compatibility
// experiment. An empty mode maintains dedicated adapter processes.
func (l *Local) EnableACPBroker(ctx context.Context, mode string) (func(), error) {
	if mode == "" || mode == "off" {
		return func() {}, nil
	}
	if mode != "share" && mode != "prewarm" {
		return nil, errors.New("AGENT_COMMANDER_ACP_BROKER must be off, share or prewarm")
	}
	dir, err := os.MkdirTemp("/tmp", "ac-pool-")
	if err != nil {
		return nil, err
	}
	socket := filepath.Join(dir, "socket")
	owner, err := broker.Listen(ctx, socket)
	if err != nil {
		_ = os.Remove(dir)
		return nil, err
	}
	l.acpBroker = &acpBrokerService{owner: owner, socket: socket, mode: mode, pins: map[providerFileIdentity]string{}}
	return func() {
		owner.Close()
		_ = os.Remove(socket)
		_ = os.Remove(dir)
	}, nil
}

func (s *acpBrokerService) register(j job) (*acpBrokerLease, error) {
	if s == nil || j.Worker.Reattach != nil || j.BuiltinInstance != "" || !j.localACP() {
		return nil, nil
	}
	config, err := planningConfig(j)
	if err != nil {
		return nil, err
	}
	setACPNodePath(&config, j.NodePath)
	orderBrokerMCP(&config)
	digest, err := s.executablePin(config.Command)
	if err != nil {
		return nil, err
	}
	command := exec.Command(config.Command, config.Args...)
	command.Dir = j.Worker.Path
	environment := acpBrokerEnvironment(command.Environ(), config.Env)
	policy, err := acpBrokerPolicy(j, config)
	if err != nil {
		return nil, err
	}
	if s.mode == "prewarm" {
		policy += "\x00" + j.Worker.ID
	}
	version := config.ProtocolVersion
	if version == 0 {
		version = 1
	}
	setup, err := json.Marshal(config.SessionSetupParams(j.Worker.Path, version, config.SystemPromptAppend != ""))
	if err != nil {
		return nil, err
	}
	ticket, err := s.owner.Register(broker.Launch{
		Scope: broker.Scope{
			Command: config.Command, WorkingDirectory: j.Worker.Path, ExecutableSHA256: digest,
			PolicyIdentity: policy, CredentialIdentity: j.ProviderBinding,
			Args: config.Args, Env: environment, ProtocolVersion: version,
		},
		New: setup,
	})
	if err != nil {
		return nil, err
	}
	if s.mode == "prewarm" {
		if err := s.owner.Prewarm(ticket); err != nil {
			return nil, err
		}
	}
	return &acpBrokerLease{Socket: s.socket, Ticket: ticket}, nil
}

func (s *acpBrokerService) executablePin(path string) (string, error) {
	identity, err := providerIdentity(path)
	if err != nil {
		return "", err
	}
	s.mu.Lock()
	digest := s.pins[identity]
	s.mu.Unlock()
	if digest != "" {
		return digest, nil
	}
	executable, err := os.Open(identity.Path)
	if err != nil {
		return "", err
	}
	defer executable.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, executable); err != nil {
		return "", err
	}
	digest = hex.EncodeToString(hash.Sum(nil))
	s.mu.Lock()
	if len(s.pins) >= 64 {
		clear(s.pins)
	}
	s.pins[identity] = digest
	s.mu.Unlock()
	return digest, nil
}

func acpBrokerEnvironment(inherited []string, override map[string]string) []string {
	values := make(map[string]string, len(inherited)+len(override))
	for _, entry := range inherited {
		name, value, ok := strings.Cut(entry, "=")
		if ok && name != "" {
			values[name] = value
		}
	}
	for name, value := range override {
		values[name] = value
	}
	delete(values, "AGENT_COMMANDER_TOKEN")
	delete(values, acpBrokerSocket)
	delete(values, acpBrokerTicket)
	env := make([]string, 0, len(values))
	for name, value := range values {
		env = append(env, name+"="+value)
	}
	sort.Strings(env)
	return env
}

func setACPNodePath(config *runtime.Config, nodePath string) {
	if _, supplied := config.Env["PATH"]; nodePath == "" || supplied {
		return
	}
	if config.Env == nil {
		config.Env = make(map[string]string)
	}
	config.Env["PATH"] = nodePath + string(os.PathListSeparator) + os.Getenv("PATH")
}

func orderBrokerMCP(config *runtime.Config) {
	slices.SortFunc(config.MCPServers, func(left, right runtime.MCPServer) int {
		return strings.Compare(left.Name, right.Name)
	})
}

func acpBrokerPolicy(j job, config runtime.Config) (string, error) {
	type serverPolicy struct {
		Name, Command string
		Args          []string
	}
	servers := make([]serverPolicy, 0, len(config.MCPServers))
	for _, server := range config.MCPServers {
		servers = append(servers, serverPolicy{server.Name, server.Command, server.Args})
	}
	identity, err := json.Marshal(struct {
		Binding, Role, SystemPrompt string
		OncePermissionsOnly         bool
		Setup                       map[string]any
		Servers                     []serverPolicy
	}{j.ProviderBinding, j.Worker.Role, config.SystemPromptAppend, config.OncePermissionsOnly, config.SessionMeta, servers})
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(identity)
	return hex.EncodeToString(digest[:]), nil
}

func (lease *acpBrokerLease) apply(config *runtime.Config, executable string) {
	if lease == nil {
		return
	}
	orderBrokerMCP(config)
	config.Command, config.Args = executable, []string{"acp-broker-proxy"}
	config.Env = map[string]string{acpBrokerSocket: lease.Socket, acpBrokerTicket: lease.Ticket}
}

func RunACPBrokerProxy(ctx context.Context, input io.Reader, output io.Writer) error {
	return broker.Proxy(ctx, os.Getenv(acpBrokerSocket), os.Getenv(acpBrokerTicket), input, output)
}

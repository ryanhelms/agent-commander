package provider

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unicode"

	agentacp "agent-acp.local/sdks/go"
	model "agent-acp.local/sdks/go/model"

	"agentcommander/internal/acpprocessor"
	"agentcommander/internal/service"
)

func (j job) localACP() bool {
	return j.SSH == nil && !j.FocusedProof && (j.Adapter != "" || j.BuiltinInstance != "")
}

type providerFileIdentity struct {
	Path     string
	Device   uint64
	Inode    uint64
	Modified int64
	Size     int64
}

func providerIdentity(path string) (providerFileIdentity, error) {
	canonical, err := filepath.EvalSymlinks(path)
	if err != nil {
		return providerFileIdentity{}, err
	}
	info, err := os.Stat(canonical)
	if err != nil {
		return providerFileIdentity{}, err
	}
	id := providerFileIdentity{Path: canonical}
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		id.Device, id.Inode = uint64(stat.Dev), uint64(stat.Ino)
	}
	if !info.IsDir() {
		id.Modified, id.Size = info.ModTime().UnixNano(), info.Size()
	}
	return id, nil
}

func providerBindingFingerprint(j job) (string, error) {
	workspace, err := providerIdentity(j.Worker.Path)
	if err != nil {
		return "", err
	}
	identity := struct {
		Workspace       providerFileIdentity
		Harness         string
		BuiltinInstance string
		Commands        []providerFileIdentity
		Registered      *acpProfile
		RegisteredEnv   map[string]string
		Codex           *managedCodex
	}{Workspace: workspace, Harness: j.Harness, BuiltinInstance: j.BuiltinInstance,
		Registered: j.RegisteredACP, RegisteredEnv: j.RegisteredEnv, Codex: j.Codex}
	var paths []string
	if j.Adapter != "" {
		paths = append(paths, j.Adapter)
	}
	if j.Codex != nil {
		paths = append(paths, j.Codex.Executable, j.Codex.Profile)
	}
	if j.NodePath != "" && j.Adapter != "" {
		paths = append(paths, filepath.Join(j.NodePath, "node"))
	}
	if j.RegisteredACP != nil {
		for _, arg := range j.RegisteredACP.Args {
			if filepath.IsAbs(arg) {
				if info, err := os.Stat(arg); err == nil && info.Mode().IsRegular() {
					paths = append(paths, arg)
				}
			}
		}
	}
	for _, path := range paths {
		file, err := providerIdentity(path)
		if err != nil {
			return "", err
		}
		identity.Commands = append(identity.Commands, file)
	}
	encoded, err := json.Marshal(identity)
	if err != nil {
		return "", err
	}
	hash := sha256.Sum256(encoded)
	return hex.EncodeToString(hash[:]), nil
}

func verifyProviderBinding(j job, ref service.NativeSession, fingerprint string) error {
	if !j.localACP() || fingerprint == "" || fingerprint != j.ProviderBinding {
		return errors.New("provider executable, profile, or checkout changed since the worker was bound")
	}
	config, err := planningConfig(j)
	if err != nil {
		return err
	}
	if config.HarnessInstance != ref.HarnessInstance || ref.SessionID == "" {
		return errors.New("provider configuration does not match the original session")
	}
	return nil
}

func (l *Local) ListProviderSessions(ctx context.Context, scope service.ProviderSessionScope, cursor string, limit uint32) (service.ProviderSessionPage, error) {
	var out service.ProviderSessionPage
	j, err := l.prepareLaunch(scope.LaunchSpec)
	if err != nil {
		return out, err
	}
	j.ProviderBinding, err = providerBindingFingerprint(j)
	if err != nil {
		return out, err
	}
	if err := verifyProviderBinding(j, scope.Ref, scope.ProviderBinding); err != nil {
		return out, err
	}
	config, err := planningConfig(j)
	if err != nil {
		return out, err
	}
	config.MCPServers, config.SessionMeta = nil, nil
	rt, err := openSessionRuntime(j, config)
	if err != nil {
		return out, err
	}
	defer rt.Close()
	list, err := agentacp.New(rt).ListSessions(ctx, &model.ListSessionsRequest{
		HarnessInstance: scope.Ref.HarnessInstance, WorkingDirectory: scope.Worktree, Cursor: cursor, Limit: limit,
	})
	if err != nil {
		return out, err
	}
	out.Sessions = make([]service.ProviderSessionSummary, 0, len(list.GetSessions()))
	for _, session := range list.GetSessions() {
		ref := session.GetRef()
		id := ref.GetSessionId()
		if ref.GetHarnessInstance() != scope.Ref.HarnessInstance || id == "" || len(id) > 512 || strings.IndexFunc(id, unicode.IsControl) >= 0 {
			continue
		}
		out.Sessions = append(out.Sessions, service.ProviderSessionSummary{SessionID: id, Title: previewPrefix(consoleText(session.GetDisplayName()), 512)})
	}
	if cursor := list.GetNextCursor(); len(cursor) <= acpprocessor.ProviderCursorLimit {
		out.NextCursor = cursor
	}
	return out, nil
}

func (l *Local) ProviderHistoryAvailability(ref service.NativeSession) string {
	if l.RequiresStoppedHistory(ref) {
		return "after_stop"
	}
	harness := ref.HarnessInstance
	switch {
	case harness == service.LocalClaudeHarness, harness == "local-codex",
		strings.HasPrefix(harness, "local-managed-codex-"), strings.HasPrefix(harness, "ssh-") && strings.HasSuffix(harness, "-claude"):
		return "available"
	case strings.HasPrefix(harness, "local-builtin:"):
		if adapter, err := boundBuiltin(harness); err == nil && adapter.ReadHistory != nil {
			return "available"
		}
	case strings.HasPrefix(harness, "local-profile-"):
		id, _, _ := strings.Cut(strings.TrimPrefix(harness, "local-profile-"), ":history-")
		profile := l.acpProfiles[id]
		if profile.History != nil && profile.instance(id) == harness && acpHistoryReaders[profile.History.Format] != nil {
			return "available"
		}
	}
	return "unavailable"
}

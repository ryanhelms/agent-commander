package provider

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"

	model "agent-acp.local/sdks/go/model"
	"google.golang.org/protobuf/encoding/protojson"

	"agentcommander/internal/service"
)

var journalSessionID = regexp.MustCompile(`^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$`)
var claudeProjectSeparator = regexp.MustCompile(`[^a-zA-Z0-9-]`)
var claudeJournalVersion = regexp.MustCompile(`^2\.1\.[0-9]+$`)
var codexJournalVersion = regexp.MustCompile(`^0\.(169|171)\.[0-9]+$`)

type vendorJournal struct {
	harness string
	profile string
}

func (l *Local) ReadNativeJournalPage(ctx context.Context, native service.NativeSession, cwd, cursor string, limit uint32) (json.RawMessage, error) {
	ref := &model.SessionRef{HarnessInstance: native.HarnessInstance, SessionId: native.SessionID}
	var journal vendorJournal
	switch {
	case native.HarnessInstance == "local-claude":
		journal = vendorJournal{"Claude", os.Getenv("CLAUDE_CONFIG_DIR")}
	case native.HarnessInstance == "local-codex":
		journal = vendorJournal{"Codex", os.Getenv("CODEX_HOME")}
	case strings.HasPrefix(native.HarnessInstance, "local-managed-codex-"):
		profile, err := managedCodexProfile()
		if err != nil || (managedCodex{Profile: profile}).instance() != native.HarnessInstance {
			return nil, errors.New("native journal is unavailable for this managed Codex profile")
		}
		journal = vendorJournal{"Codex", profile}
	default:
		return marshalHistoryPage(unavailableJournal(ref, "No supplementary journal reader is configured for this harness"))
	}
	if journal.profile == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		journal.profile = filepath.Join(home, "."+strings.ToLower(journal.harness))
	}
	page, err := journal.read(ctx, ref, cwd, cursor, limit)
	if err != nil {
		return nil, err
	}
	return marshalHistoryPage(page)
}

func marshalHistoryPage(page *model.ReadHistoryResponse) (json.RawMessage, error) {
	return (protojson.MarshalOptions{EmitDefaultValues: true}).Marshal(page)
}

func (j vendorJournal) read(ctx context.Context, ref *model.SessionRef, cwd, cursor string, limit uint32) (*model.ReadHistoryResponse, error) {
	if !journalSessionID.MatchString(ref.GetSessionId()) || !filepath.IsAbs(cwd) || !filepath.IsAbs(j.profile) {
		return nil, errors.New("invalid native journal session binding")
	}
	physical, err := filepath.EvalSymlinks(cwd)
	if errors.Is(err, os.ErrNotExist) {
		physical = filepath.Clean(cwd)
	} else if err != nil {
		return nil, err
	}
	root, err := os.OpenRoot(j.profile)
	if errors.Is(err, os.ErrNotExist) {
		return unavailableJournal(ref, j.harness+" journal is unavailable for the selected session"), nil
	}
	if err != nil {
		return nil, err
	}
	defer root.Close()
	name, err := j.filename(ctx, root, physical, ref.GetSessionId())
	if errors.Is(err, os.ErrNotExist) {
		return unavailableJournal(ref, j.harness+" journal is unavailable for the selected session"), nil
	}
	if err != nil {
		return nil, err
	}
	file, err := root.OpenFile(name, os.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return nil, errors.New("bound native journal must be a regular file")
	}
	input := bufio.NewReaderSize(file, 64<<10)
	var offset int64
	var header []byte
	decode := func(raw []byte) []*model.Observation {
		return claudeJournalRecord(raw, ref.GetSessionId(), physical)
	}
	if j.harness == "Codex" {
		header, offset, err = readJournalLine(ctx, input)
		if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, errJournalIncomplete) {
			return nil, err
		}
		var meta struct {
			Type    string
			Payload struct {
				ID, Cwd string
				Version string `json:"cli_version"`
			}
		}
		if json.Unmarshal(header, &meta) != nil || meta.Type != "session_meta" {
			return unavailableJournal(ref, "Codex journal has an unrecognized session header"), nil
		}
		if meta.Payload.ID != ref.GetSessionId() || meta.Payload.Cwd != physical {
			return nil, errors.New("Codex journal does not match the bound session and checkout")
		}
		if !codexJournalVersion.MatchString(meta.Payload.Version) {
			return unavailableJournal(ref, "Codex journal version has no verified reader"), nil
		}
		decode = func(raw []byte) []*model.Observation {
			return codexJournalRecord(raw, ref.GetSessionId(), physical)
		}
	}
	stat := info.Sys().(*syscall.Stat_t)
	scope := fmt.Sprintf("%x", sha256.Sum256(fmt.Appendf(nil, "%s\x00%s\x00%s\x00%s\x00%s\x00%d:%d\x00%s",
		j.profile, name, physical, ref.GetHarnessInstance(), ref.GetSessionId(), stat.Dev, stat.Ino, header)))
	position := journalCursor{Scope: scope, Offset: offset}
	if cursor != "" {
		raw, err := base64.RawURLEncoding.DecodeString(cursor)
		if err != nil || json.Unmarshal(raw, &position) != nil || position.Scope != scope ||
			position.Offset < offset || position.Offset > info.Size() || position.Part != 0 {
			return nil, errors.New("invalid cursor for the bound native journal")
		}
		if position.Offset != 0 {
			var delimiter [1]byte
			if _, err := file.ReadAt(delimiter[:], position.Offset-1); err != nil || delimiter[0] != '\n' {
				return nil, errors.New("native journal cursor is outside a record boundary")
			}
		}
	}
	if _, err := file.Seek(position.Offset, io.SeekStart); err != nil {
		return nil, err
	}
	input.Reset(file)
	return readJournalPage(ctx, input, ref, position, limit, decode)
}

func (j vendorJournal) filename(ctx context.Context, root *os.Root, cwd, id string) (string, error) {
	if j.harness == "Claude" {
		name := filepath.Join("projects", claudeProjectSeparator.ReplaceAllString(cwd, "-"), id+".jsonl")
		_, err := root.Lstat(name)
		return name, err
	}
	var selected string
	for _, base := range []string{"sessions", "archived_sessions"} {
		err := fs.WalkDir(root.FS(), base, func(name string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if err := ctx.Err(); err != nil {
				return err
			}
			if entry.IsDir() && strings.Count(name, "/") > 3 {
				return fs.SkipDir
			}
			if entry.Type().IsRegular() && strings.HasPrefix(entry.Name(), "rollout-") && strings.HasSuffix(entry.Name(), "-"+id+".jsonl") {
				if selected != "" {
					return errors.New("multiple Codex journals claim the bound session ID")
				}
				selected = name
			}
			return nil
		})
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return "", err
		}
	}
	if selected == "" {
		return "", os.ErrNotExist
	}
	return selected, nil
}

func unavailableJournal(ref *model.SessionRef, reason string) *model.ReadHistoryResponse {
	event := journalGap(reason)
	event.Session = ref
	return &model.ReadHistoryResponse{Observations: []*model.Observation{event}}
}

func sourceJournalRecord(kind string, raw []byte) []*model.Observation {
	event := &model.Observation{Event: &model.Observation_Extension{Extension: &model.Extension{
		Type: kind, MediaType: "application/json", Data: raw,
	}}}
	return []*model.Observation{event}
}

func claudeJournalRecord(raw []byte, session, cwd string) []*model.Observation {
	var row struct {
		Type, Version, Cwd, SessionID string
		IsSidechain                   bool
	}
	if json.Unmarshal(raw, &row) != nil || row.Type == "" {
		return []*model.Observation{journalGap("Claude journal contains an unreadable or oversized record")}
	}
	switch row.Type {
	case "assistant", "user", "system", "attachment", "progress":
		if row.SessionID != session || row.Cwd != cwd || row.IsSidechain {
			return []*model.Observation{journalGap("Claude journal contains a record outside the bound conversation")}
		}
		if !claudeJournalVersion.MatchString(row.Version) {
			return []*model.Observation{journalGap("Claude journal version has no verified reader")}
		}
		return sourceJournalRecord("claude.journal."+row.Type, raw)
	case "session-owner", "queue-operation", "api-request-blob", "atis-latch", "last-prompt", "api-request",
		"data-flow-records", "api-request-shape", "tools-used", "ai-title", "custom-title", "cost-state", "agent-name",
		"file-history-snapshot", "summary":
		// Operational records can refer to settings, account metadata and earlier prompts.
		return nil
	default:
		return []*model.Observation{journalGap("Claude journal contains an unrecognized record type")}
	}
}

func codexJournalRecord(raw []byte, session, cwd string) []*model.Observation {
	var row struct {
		Type    string
		Payload struct{ Type, ID, Cwd string }
	}
	if json.Unmarshal(raw, &row) != nil || row.Type == "" {
		return []*model.Observation{journalGap("Codex journal contains an unreadable or oversized record")}
	}
	switch row.Type {
	case "response_item":
		switch row.Payload.Type {
		case "message", "agent_message", "reasoning", "function_call", "function_call_output",
			"custom_tool_call", "custom_tool_call_output", "local_shell_call", "web_search_call", "image_generation_call":
			return sourceJournalRecord("codex.journal."+row.Type, raw)
		case "additional_tools", "compaction":
			return nil
		}
	case "event_msg":
		switch row.Payload.Type {
		case "item_completed", "token_count", "task_started", "task_complete", "turn_aborted",
			"user_message", "agent_message", "agent_reasoning", "exec_command_begin", "exec_command_end",
			"mcp_tool_call_begin", "mcp_tool_call_end", "patch_apply_begin", "patch_apply_end":
			return sourceJournalRecord("codex.journal."+row.Type, raw)
		case "thread_settings_applied":
			return nil
		}
	case "token_usage_record":
		return sourceJournalRecord("codex.journal."+row.Type, raw)
	case "turn_context", "world_state", "compacted", "inter_agent_communication_metadata":
		// These records store configuration, snapshots and cross-session state.
		return nil
	case "session_meta":
		if row.Payload.ID == session && row.Payload.Cwd == cwd {
			return nil
		}
		return []*model.Observation{journalGap("Codex journal contains a header outside the bound conversation")}
	}
	return []*model.Observation{journalGap("Codex journal contains an unrecognized record type")}
}

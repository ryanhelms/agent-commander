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
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"

	model "agent-acp.local/sdks/go/model"
	"agentcommander/internal/acpprocessor"
	"agentcommander/internal/service"
)

var piSessionID = regexp.MustCompile(`^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$`)

// Pi emits a portable result followed by its original journal message. Link
// the bounded result preview to the complete record, including media.
func linkPiToolResult(event *service.ConsoleEvent, obs *model.Observation) {
	ext := obs.GetExtension()
	if event.Kind != "tool_result" || event.ToolID == "" || event.ACP != nil ||
		obs.Cursor == "" || ext.GetType() != "pi.message" || ext.GetMediaType() != "application/json" {
		return
	}
	var row struct {
		Message struct{ Role, ToolCallID string }
	}
	if json.Unmarshal(ext.Data, &row) != nil || row.Message.Role != "toolResult" || row.Message.ToolCallID != event.ToolID {
		return
	}
	event.ACP = acpprocessor.Reference("provider", obs.Cursor, ext.Type, "")
}

func piHistoryReader(directory, cwd string) historyReader {
	return func(ctx context.Context, request *model.ReadHistoryRequest) (*model.ReadHistoryResponse, error) {
		ref := request.GetSession()
		if ref.GetHarnessInstance() == "" || !piSessionID.MatchString(ref.GetSessionId()) {
			return nil, errors.New("invalid Pi history identity")
		}
		physical, err := filepath.EvalSymlinks(cwd)
		if errors.Is(err, os.ErrNotExist) {
			physical = filepath.Clean(cwd)
		} else if err != nil {
			return nil, err
		}
		file, err := openPiJournal(ctx, directory, physical, ref.SessionId)
		if err != nil {
			return nil, err
		}
		defer file.Close()
		input := bufio.NewReaderSize(file, 64<<10)
		headerLine, headerBytes, err := readJournalLine(ctx, input)
		if err != nil {
			return nil, err
		}
		var header struct {
			Type, ID, Cwd string
			Version       int
		}
		if err := json.Unmarshal(headerLine, &header); err != nil || header.Type != "session" ||
			header.ID != ref.SessionId || header.Cwd != physical {
			return nil, errors.New("Pi journal does not match the bound session and directory")
		}
		if header.Version != 3 {
			gap := journalGap(fmt.Sprintf("Pi journal version %d has no configured reader", header.Version))
			gap.Session = ref
			return &model.ReadHistoryResponse{Observations: []*model.Observation{gap}}, nil
		}
		scope := fmt.Sprintf("%x", sha256.Sum256([]byte(directory+"\x00"+physical+"\x00"+
			ref.HarnessInstance+"\x00"+ref.SessionId+"\x00"+string(headerLine))))
		position := journalCursor{Scope: scope}
		if cursor := request.GetCursor(); cursor != "" {
			raw, err := base64.RawURLEncoding.DecodeString(cursor)
			if err != nil || json.Unmarshal(raw, &position) != nil || position.Scope != scope ||
				position.Part < 0 || position.Offset < 0 || (position.Offset != 0 && position.Offset < headerBytes) {
				return nil, errors.New("invalid cursor for the bound Pi journal")
			}
		}
		if _, err := file.Seek(position.Offset, io.SeekStart); err != nil {
			return nil, err
		}
		input.Reset(file)
		return readJournalPage(ctx, input, ref, position, request.GetLimit(), piObservations)
	}
}

func openPiJournal(ctx context.Context, directory, cwd, session string) (*os.File, error) {
	root, err := os.OpenRoot(directory)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	project := "--" + strings.NewReplacer("/", "-", "\\", "-", ":", "-").Replace(strings.TrimLeft(cwd, "/\\")) + "--"
	folder, err := root.Open(project)
	if err != nil {
		return nil, err
	}
	defer folder.Close()
	var selected string
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		entries, readErr := folder.ReadDir(128)
		for _, entry := range entries {
			if !entry.Type().IsRegular() || !strings.HasSuffix(entry.Name(), "_"+session+".jsonl") {
				continue
			}
			if selected != "" {
				return nil, errors.New("multiple Pi journals claim the bound session ID")
			}
			selected = entry.Name()
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil {
			return nil, readErr
		}
	}
	if selected == "" {
		return nil, os.ErrNotExist
	}
	file, err := root.OpenFile(filepath.Join(project, selected), os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		file.Close()
		return nil, errors.New("bound Pi journal must be a regular file")
	}
	return file, nil
}

func piObservations(raw []byte) []*model.Observation {
	var row struct {
		Type    string
		Message struct {
			Role, ToolName, ToolCallID string
			IsError                    bool
			Content                    json.RawMessage
		}
	}
	if len(raw) == 0 || json.Unmarshal(raw, &row) != nil || row.Type == "" {
		return []*model.Observation{journalGap("Pi journal contains an unreadable, incomplete or oversized record")}
	}
	original := &model.Observation{Event: &model.Observation_Extension{Extension: &model.Extension{
		Type: "pi." + row.Type, MediaType: "application/json", Data: raw,
	}}}
	if row.Type != "message" {
		return []*model.Observation{original}
	}
	type part struct {
		Type, ID, Name, Text string
		Arguments            json.RawMessage
	}
	var parts []part
	var text string
	content := row.Message.Content
	if err := json.Unmarshal(content, &parts); err != nil && json.Unmarshal(content, &text) == nil {
		parts = []part{{Type: "text", Text: text}}
	}
	var observations []*model.Observation
	switch row.Message.Role {
	case "user", "assistant", "system":
		speaker := model.Speaker_SPEAKER_ASSISTANT
		if row.Message.Role == "user" {
			speaker = model.Speaker_SPEAKER_USER
		} else if row.Message.Role == "system" {
			speaker = model.Speaker_SPEAKER_SYSTEM
		}
		for _, p := range parts {
			switch p.Type {
			case "text":
				observations = append(observations, &model.Observation{Event: &model.Observation_Text{
					Text: &model.TextUpdate{Speaker: speaker, Text: p.Text},
				}})
			case "toolCall":
				observations = append(observations, &model.Observation{Event: &model.Observation_Tool{
					Tool: &model.ToolActivity{CallId: p.ID, Name: p.Name, Phase: "pending", Summary: string(p.Arguments)},
				}})
			}
		}
	case "toolResult":
		var content []string
		for _, p := range parts {
			if p.Type == "text" {
				content = append(content, p.Text)
			} else {
				content = append(content, "["+p.Type+" · see retained Pi record]")
			}
		}
		phase := "completed"
		if row.Message.IsError {
			phase = "failed"
		}
		observations = append(observations, &model.Observation{Event: &model.Observation_Tool{Tool: &model.ToolActivity{
			CallId: row.Message.ToolCallID, Name: row.Message.ToolName, Phase: phase, Summary: strings.Join(content, "\n"),
		}}})
	}
	return append(observations, original)
}

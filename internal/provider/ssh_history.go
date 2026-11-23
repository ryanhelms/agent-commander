package provider

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"

	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/nativehistory"
	"google.golang.org/protobuf/encoding/protojson"
)

type sshHistoryQuery struct {
	Checkout, HarnessInstance, SessionID, Cursor string
	Limit                                        uint32
}

func (p sshProfile) readHistory(cwd string) func(context.Context, *model.ReadHistoryRequest) (*model.ReadHistoryResponse, error) {
	return func(ctx context.Context, req *model.ReadHistoryRequest) (*model.ReadHistoryResponse, error) {
		ref := req.GetSession()
		// Keep session handles and history cursors off both shells' command lines.
		command := "PATH=" + quoteShell(path.Dir(p.Adapter)) + ":\"$PATH\" exec " + quoteShell(p.Agentctl) + " runner-history"
		cmd := exec.CommandContext(ctx, "/usr/bin/ssh", p.command(nil, command)...)
		return readHistoryProcess(cmd, cwd, ref, req)
	}
}

func readHistoryProcess(cmd *exec.Cmd, cwd string, ref *model.SessionRef, req *model.ReadHistoryRequest) (*model.ReadHistoryResponse, error) {
	query, err := json.Marshal(sshHistoryQuery{cwd, ref.GetHarnessInstance(), ref.GetSessionId(), req.GetCursor(), req.GetLimit()})
	if err != nil {
		return nil, err
	}
	cmd.Stdin = bytes.NewReader(query)
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	const maxPage = 8 << 20
	raw, readErr := io.ReadAll(io.LimitReader(out, maxPage+1))
	if readErr != nil || len(raw) > maxPage {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return nil, errors.New("history response is unreadable or exceeds the page size limit")
	}
	if err := cmd.Wait(); err != nil {
		return nil, fmt.Errorf("read native history from host process: %w", err)
	}
	page := &model.ReadHistoryResponse{}
	if err := protojson.Unmarshal(raw, page); err != nil {
		return nil, fmt.Errorf("decode native history: %w", err)
	}
	for _, obs := range page.GetObservations() {
		if obs.GetSession().GetHarnessInstance() != ref.GetHarnessInstance() || obs.GetSession().GetSessionId() != ref.GetSessionId() {
			return nil, errors.New("history response belongs to a different session")
		}
	}
	return page, nil
}

// RunSSHHistory is the private host-side reader invoked by the SSH adapter.
func RunSSHHistory(ctx context.Context, input io.Reader, output io.Writer) error {
	const maxQuery = 32 << 10
	raw, err := io.ReadAll(io.LimitReader(input, maxQuery+1))
	if err != nil || len(raw) > maxQuery {
		return errors.New("invalid SSH history request size")
	}
	var q sshHistoryQuery
	if err := json.Unmarshal(raw, &q); err != nil {
		return err
	}
	provider := "claude"
	alias, ok := strings.CutPrefix(q.HarnessInstance, "ssh-")
	alias, suffix := strings.CutSuffix(alias, "-claude")
	validInstance := ok && suffix && sshAlias.MatchString(alias)
	if strings.HasPrefix(q.HarnessInstance, "local-managed-codex-") {
		profile, err := configuredManagedCodex()
		validInstance = err == nil && profile.instance() == q.HarnessInstance && os.Getenv("CODEX_HOME") == profile.Profile
		provider = "codex"
	}
	if !validInstance || !filepath.IsAbs(q.Checkout) || q.SessionID == "" ||
		len(q.SessionID) > 512 || len(q.Cursor) > 8192 || q.Limit > 128 {
		return errors.New("invalid SSH history session reference or page")
	}
	reader := nativehistory.ForHarness(provider, q.Checkout)
	page, err := reader(ctx, &model.ReadHistoryRequest{
		Session: &model.SessionRef{HarnessInstance: q.HarnessInstance, SessionId: q.SessionID},
		Cursor:  q.Cursor, Limit: q.Limit,
	})
	if err != nil {
		return err
	}
	encoded, err := protojson.Marshal(page)
	if err != nil {
		return err
	}
	_, err = output.Write(encoded)
	return err
}

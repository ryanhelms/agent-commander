package actions

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Inbox messages are data read by an already authenticated local coordinator.
// Posting one never writes a terminal, starts a process or acquires input control.
type coordinatorNote struct {
	ID         string    `json:"id"`
	Peer       string    `json:"peer"`
	Resource   string    `json:"resource"`
	ReceivedAt time.Time `json:"receivedAt"`
	Text       string    `json:"text"`
}

type coordinatorMailbox struct {
	Messages  []coordinatorNote `json:"messages"`
	Truncated bool              `json:"truncated"`
}

func activeMailbox(ctx context.Context, cfg Config, r Resource) (string, error) {
	if r.Kind != "agent" || !r.Coordinator || !identifier.MatchString(r.Target) || !identifier.MatchString(r.Run) {
		return "", ErrDenied
	}
	client, e := commanderClient(cfg.CommanderSocket)
	if e != nil {
		return "", e
	}
	defer client.CloseIdleConnections()
	info, e := workerInfo(ctx, client, r.Target)
	if e != nil {
		return "", e
	}
	if info.Role != "coordinator" || info.RunID != r.Run || info.RunStatus != "running" {
		return "", ErrDenied
	}
	dir := filepath.Join(cfg.StateDir, "coordinator-inbox", hash([]byte(r.Target+"\x00"+r.Run)))
	if e := privateDir(dir); e != nil {
		return "", ErrUnavailable
	}
	return filepath.Join(dir, "messages.json"), nil
}

func readMailbox(path string) (coordinatorMailbox, error) {
	var box coordinatorMailbox
	f, e := os.Open(path)
	if errors.Is(e, os.ErrNotExist) {
		box.Messages = []coordinatorNote{}
		return box, nil
	}
	if e != nil {
		return box, ErrUnavailable
	}
	defer f.Close()
	data, e := io.ReadAll(io.LimitReader(f, 256<<10))
	if e != nil || len(data) >= 256<<10 || strict(data, &box) != nil || len(box.Messages) > 32 {
		return box, ErrUnavailable
	}
	return box, nil
}

// CoordinatorInbox must be called after the service verifies the coordinator's
// bearer and returns its run and worker IDs. The active enrollment is checked again.
func CoordinatorInbox(cfg Config, worker, run string) (any, error) {
	for _, r := range cfg.Resources {
		if r.Kind != "agent" || !r.Coordinator || r.Target != worker || r.Run != run {
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		path, e := activeMailbox(ctx, cfg, r)
		if e != nil {
			return nil, e
		}
		return readMailbox(path)
	}
	return nil, ErrDenied
}

func coordinatorMessage(ctx context.Context, cfg Config, r Resource, req Request, id string, recoverOnly bool) (json.RawMessage, error) {
	var in struct {
		Text string `json:"text"`
	}
	if strict(req.Payload, &in) != nil || strings.TrimSpace(in.Text) == "" {
		return nil, ErrInvalid
	}
	encoded, _ := json.Marshal(in.Text)
	if len(encoded) > 4096 {
		return nil, ErrInvalid
	}
	path, e := activeMailbox(ctx, cfg, r)
	if e != nil {
		return nil, e
	}
	lock, e := os.OpenFile(filepath.Join(filepath.Dir(path), ".lock"), os.O_CREATE|os.O_RDWR, 0600)
	if e != nil {
		return nil, ErrUnavailable
	}
	defer lock.Close()
	if e = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); e != nil {
		return nil, ErrUnavailable
	}
	if e = ctx.Err(); e != nil {
		return nil, e
	}
	box, e := readMailbox(path)
	if e != nil {
		return nil, e
	}
	for _, note := range box.Messages {
		if note.ID == id {
			return answer(map[string]string{"status": "completed", "messageId": id})
		}
	}
	if recoverOnly {
		return nil, ErrUncertain
	}
	if len(box.Messages) == 32 {
		box.Messages = box.Messages[1:]
		box.Truncated = true
	}
	box.Messages = append(box.Messages, coordinatorNote{ID: id, Peer: req.Peer, Resource: r.ID, ReceivedAt: time.Now().UTC(), Text: in.Text})
	if e = save(path, box); e != nil {
		return nil, ErrUncertain
	}
	return answer(map[string]string{"status": "completed", "messageId": id})
}

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

type InboxQuery struct {
	AfterMessageID string `json:"afterMessageId,omitempty"`
	WaitSeconds    int    `json:"waitSeconds,omitempty"`
}

const inboxWaitMaxSeconds = 10

var errInboxNotConfigured = errors.New("This coordinator has no inbox. Ask the owner to share this running coordinator as an Agent resource and grant the peer Send the coordinator a note")

func requireActiveCoordinator(ctx context.Context, socket, worker, run string) error {
	if !identifier.MatchString(worker) || !identifier.MatchString(run) {
		return ErrDenied
	}
	client, e := commanderClient(socket)
	if e != nil {
		return e
	}
	defer client.CloseIdleConnections()
	info, e := workerInfo(ctx, client, worker)
	if e != nil {
		return e
	}
	if info.Role != "coordinator" || info.RunID != run || info.RunStatus != "running" {
		return ErrDenied
	}
	return nil
}

func activeMailbox(ctx context.Context, cfg Config, r Resource) (string, error) {
	if r.Kind != "agent" || !r.Coordinator || !identifier.MatchString(r.Target) || !identifier.MatchString(r.Run) {
		return "", ErrDenied
	}
	if e := requireActiveCoordinator(ctx, cfg.CommanderSocket, r.Target, r.Run); e != nil {
		return "", e
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

func coordinatorInboxSnapshot(ctx context.Context, cfg Config, worker, run string) (coordinatorMailbox, error) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	for _, r := range cfg.Resources {
		if r.Kind != "agent" || !r.Coordinator || r.Target != worker || r.Run != run {
			continue
		}
		path, e := activeMailbox(ctx, cfg, r)
		if e != nil {
			return coordinatorMailbox{}, e
		}
		return readMailbox(path)
	}
	if e := requireActiveCoordinator(ctx, cfg.CommanderSocket, worker, run); e != nil {
		return coordinatorMailbox{}, ErrDenied
	}
	return coordinatorMailbox{}, errInboxNotConfigured
}

func (box coordinatorMailbox) after(id string) coordinatorMailbox {
	if id == "" {
		return box
	}
	for i, note := range box.Messages {
		if note.ID == id {
			return coordinatorMailbox{Messages: box.Messages[i+1:]}
		}
	}
	// If the cursor is no longer retained, the entire remaining window is useful.
	box.Truncated = box.Truncated || len(box.Messages) > 0
	return box
}

// CoordinatorInbox keeps an authenticated request open for an optional bounded wait.
// The resource and running coordinator are checked on each mailbox read.
func CoordinatorInbox(ctx context.Context, config func() Config, worker, run string, query InboxQuery) (coordinatorMailbox, error) {
	if query.WaitSeconds < 0 || query.WaitSeconds > inboxWaitMaxSeconds {
		return coordinatorMailbox{}, errors.New("waitSeconds must be between 0 and 10")
	}
	if query.AfterMessageID != "" && !identifier.MatchString(query.AfterMessageID) {
		return coordinatorMailbox{}, errors.New("afterMessageId must be a message ID returned by the inbox")
	}
	if query.WaitSeconds == 0 {
		box, e := coordinatorInboxSnapshot(ctx, config(), worker, run)
		return box.after(query.AfterMessageID), e
	}
	deadline := time.NewTimer(time.Duration(query.WaitSeconds) * time.Second)
	defer deadline.Stop()
	check := time.NewTicker(250 * time.Millisecond)
	defer check.Stop()
	for {
		if e := ctx.Err(); e != nil {
			return coordinatorMailbox{}, e
		}
		box, e := coordinatorInboxSnapshot(ctx, config(), worker, run)
		if cancelled := ctx.Err(); cancelled != nil {
			return coordinatorMailbox{}, cancelled
		}
		if e != nil {
			return coordinatorMailbox{}, e
		}
		box = box.after(query.AfterMessageID)
		if len(box.Messages) > 0 {
			return box, nil
		}
		select {
		case <-ctx.Done():
			return coordinatorMailbox{}, ctx.Err()
		case <-deadline.C:
			return box, nil
		case <-check.C:
		}
	}
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

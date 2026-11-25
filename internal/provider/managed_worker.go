package provider

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"strings"
	"time"

	"agentcommander/internal/service"
)

type controlAnswer struct {
	ID              string `json:"id"`
	ProviderRequest string `json:"provider_request"`
	Choice          string `json:"choice"`
}

type controlFeed struct {
	Revision             string          `json:"revision"`
	Answers              []controlAnswer `json:"answers"`
	Live                 bool            `json:"live"`
	State                string          `json:"state"`
	NextMessageID        string          `json:"next_message_id"`
	InterruptRequested   bool            `json:"interrupt_requested"`
	InterruptID          string          `json:"interrupt_id"`
	Generation           int             `json:"generation"`
	ProviderAvailability string          `json:"provider_availability"`
}

func newSessionID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func runManagedWorker(ctx context.Context, j job, dir string, a *api, s *screen) error {
	path := "/v1/workers/" + j.Worker.ID
	if err := a.request("POST", path+"/control/ready", struct{}{}, nil); err != nil {
		s.line("Worker control unavailable: " + err.Error())
		s.flush()
		_ = a.request("POST", path+"/state", map[string]string{"state": "failed", "error": err.Error()}, nil)
		return err
	}
	sessionID := newSessionID()
	var message service.WorkerFollowUp
	prompt := j.Worker.Task
	for {
		state, turnErr := runManagedTurn(ctx, j, dir, a, s, path, sessionID, prompt, message.ID != "")
		if ctx.Err() != nil {
			return nil
		}
		outcome := map[string]string{"state": state, "message_id": message.ID}
		switch state {
		case "idle":
			s.line("Turn interrupted. This conversation is ready for a follow-up.")
		case "failed":
			outcome["error"] = turnErr.Error()
			s.line("Worker ended: " + turnErr.Error())
		case "completed":
			s.line("Turn complete.")
		}
		s.flush()
		if err := publishWorkerControl(ctx, a, path+"/control/finish", outcome); err != nil {
			return err
		}
		if turnErr != nil && state == "failed" {
			return turnErr
		}

		next, ok := waitForFollowUp(ctx, a, path)
		if !ok {
			return nil
		}
		message, prompt = next.WorkerFollowUp, next.Text
		s.line("You: " + prompt)
		s.event("user", "", "", prompt)
	}
}

func publishWorkerControl(ctx context.Context, a *api, path string, payload any) error {
	var last error
	for range 3 {
		last = a.requestContext(ctx, "POST", path, payload, nil)
		if last == nil || ctx.Err() != nil {
			return last
		}
		if !waitControlTick(ctx) {
			break
		}
	}
	return fmt.Errorf("could not publish worker control update: %w", last)
}

func runManagedTurn(ctx context.Context, j job, dir string, a *api, s *screen, path, sessionID, prompt string, resume bool) (string, error) {
	turn, cancel := context.WithCancel(ctx)
	defer cancel()
	cmd, err := agentCommand(turn, j, dir)
	if err != nil {
		return "failed", err
	}
	if resume {
		cmd.Args = append(cmd.Args, "--resume", sessionID)
	} else {
		cmd.Args = append(cmd.Args, "--session-id", sessionID)
	}
	cmd.Stdin = strings.NewReader(prompt)
	cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
	cmd.WaitDelay = 2 * time.Second
	finished := make(chan error, 1)
	go func() { finished <- runClaude(cmd, s) }()

	controlCtx, stopControl := context.WithCancel(ctx)
	defer stopControl()
	control := a.watchControl(controlCtx, path, "")
	for {
		select {
		case err := <-finished:
			if err != nil {
				return "failed", err
			}
			return "completed", nil
		case <-ctx.Done():
			cancel()
			<-finished
			return "idle", nil
		case feed, ok := <-control:
			if !ok {
				control = nil
			}
			if !feed.InterruptRequested {
				continue
			}
			if a.request("POST", path+"/control/interrupt/claim", map[string]int{"generation": feed.Generation}, nil) != nil {
				continue
			}
			select {
			case err := <-finished:
				if err != nil {
					return "failed", err
				}
				return "completed", nil
			default:
			}
			cancel()
			<-finished
			return "idle", nil
		}
	}
}

func waitForFollowUp(ctx context.Context, a *api, path string) (service.ClaimedWorkerFollowUp, bool) {
	watchCtx, stop := context.WithCancel(ctx)
	defer stop()
	for feed := range a.watchControl(watchCtx, path, "") {
		if !feed.Live {
			break
		}
		if feed.State == "unknown" {
			_ = a.requestContext(ctx, "POST", path+"/control/ready", map[string]bool{"idle": true}, nil)
		}
		if feed.NextMessageID != "" {
			// Retry the same claim only before any provider process starts.
			claim := path + "/messages/" + feed.NextMessageID + "/claim"
			for range 3 {
				if ctx.Err() != nil {
					return service.ClaimedWorkerFollowUp{}, false
				}
				var m service.ClaimedWorkerFollowUp
				if err := a.requestContext(ctx, "POST", claim, struct{}{}, &m); err == nil {
					return m, true
				}
				if !waitControlTick(ctx) {
					return service.ClaimedWorkerFollowUp{}, false
				}
			}
		}
	}
	return service.ClaimedWorkerFollowUp{}, false
}

func (a *api) watchControl(ctx context.Context, path, turn string) <-chan controlFeed {
	updates := make(chan controlFeed)
	go func() {
		defer close(updates)
		var revision string
		for ctx.Err() == nil {
			query := url.Values{"wait_seconds": {"25"}}
			if turn != "" {
				query.Set("turn", turn)
			}
			if revision != "" {
				query.Set("after", revision)
			}
			data, err := a.client.WaitWorkerControl(ctx, path+"/control?"+query.Encode())
			var feed controlFeed
			if err != nil || json.Unmarshal(data, &feed) != nil {
				if !waitControlTick(ctx) {
					return
				}
				continue
			}
			select {
			case updates <- feed:
			case <-ctx.Done():
				return
			}
			revision = feed.Revision
			if revision == "" && !waitControlTick(ctx) {
				return
			}
		}
	}()
	return updates
}

func waitControlTick(ctx context.Context) bool {
	timer := time.NewTimer(350 * time.Millisecond)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

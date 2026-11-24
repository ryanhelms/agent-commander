package provider

import (
	"context"
	"crypto/rand"
	"fmt"
	"os"
	"strings"
	"time"

	"agentcommander/internal/service"
)

type controlFeed struct {
	Live               bool   `json:"live"`
	State              string `json:"state"`
	NextMessageID      string `json:"next_message_id"`
	InterruptRequested bool   `json:"interrupt_requested"`
	Generation         int    `json:"generation"`
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
		if err := publishTurnOutcome(ctx, a, path+"/control/finish", outcome); err != nil {
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

func publishTurnOutcome(ctx context.Context, a *api, path string, outcome map[string]string) error {
	var last error
	for range 3 {
		last = a.request("POST", path, outcome, nil)
		if last == nil || ctx.Err() != nil {
			return last
		}
		if !waitControlTick(ctx) {
			break
		}
	}
	return fmt.Errorf("could not publish completed worker turn: %w", last)
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

	tick := time.NewTicker(350 * time.Millisecond)
	defer tick.Stop()
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
		case <-tick.C:
			var feed controlFeed
			if a.request("GET", path+"/control", nil, &feed) != nil || !feed.InterruptRequested {
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
	for ctx.Err() == nil {
		var feed controlFeed
		if a.requestContext(ctx, "GET", path+"/control", nil, &feed) == nil {
			if !feed.Live {
				return service.ClaimedWorkerFollowUp{}, false
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
		if !waitControlTick(ctx) {
			break
		}
	}
	return service.ClaimedWorkerFollowUp{}, false
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

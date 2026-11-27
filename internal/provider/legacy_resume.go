package provider

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	"agentcommander/internal/localapi"
	"agentcommander/internal/service"
)

func legacyCoordinatorJob(j job) bool {
	return j.Worker.Role == "coordinator" && j.SSH == nil && !j.FocusedProof && j.Claude != ""
}

func legacyCoordinatorFingerprint(checkout, executable string) (string, error) {
	cwd, err := providerIdentity(checkout)
	if err != nil {
		return "", err
	}
	command, err := providerIdentity(executable)
	if err != nil {
		return "", err
	}
	profile := os.Getenv("CLAUDE_CONFIG_DIR")
	if profile == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		profile = filepath.Join(home, ".claude")
	}
	data, err := json.Marshal(struct {
		Workspace, Executable providerFileIdentity
		Profile               string
	}{cwd, command, filepath.Clean(profile)})
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:]), nil
}

func bindLegacyCoordinator(j job, s *screen) func(streamEvent) error {
	return func(frame streamEvent) error {
		if frame.Type != "system" || frame.Subtype != "init" || !journalSessionID.MatchString(frame.Session) {
			return nil
		}
		owner := &api{localapi.New(j.Socket, "")}
		binding := struct {
			service.NativeSession
			ProviderBinding  string                      `json:"provider_binding"`
			PeerCapabilities service.SessionCapabilities `json:"peer_capabilities"`
		}{service.NativeSession{HarnessInstance: service.LegacyClaudeHarness, SessionID: frame.Session},
			j.ProviderBinding, service.SessionCapabilities{CanResume: true, CanInterrupt: true}}
		if err := owner.request("POST", "/v1/workers/"+j.Worker.ID+"/native-session", binding, nil); err != nil {
			// This is optional metadata for an ordinary launch. The provider
			// journal can still prove identity during a later inspection.
			s.line("Could not save the Claude session binding.")
		}
		return nil
	}
}

func verifyResumedClaude(sessionID string) func(streamEvent) error {
	confirmed := false
	return func(frame streamEvent) error {
		if frame.Session != "" && frame.Session != sessionID {
			return errors.New("Claude reported a different session during native resume")
		}
		if frame.Type == "system" && frame.Subtype == "init" && frame.Session == sessionID {
			confirmed = true
		}
		if !confirmed && (frame.Type == "assistant" || frame.Type == "stream_event" || frame.Type == "result" && !frame.IsError) {
			return errors.New("Claude returned conversation output before confirming the original session ID")
		}
		return nil
	}
}

func resumeLegacyCoordinator(ctx context.Context, j job, dir string, a *api, s *screen) error {
	reservation := j.Worker.Reattach
	if err := initializeLegacyResume(ctx, j, dir, reservation.Ref.SessionID); err != nil {
		return err
	}
	registration := struct {
		service.ReattachSpec
		SessionCapabilities service.SessionCapabilities `json:"session_capabilities"`
	}{*reservation, service.SessionCapabilities{CanResume: true, CanInterrupt: true}}
	path := "/v1/workers/" + j.Worker.ID
	if err := publishWorkerControl(ctx, a, path+"/control/reattached", registration); err != nil {
		return err
	}
	s.line("Reattached to the original Claude CLI session.")
	return managedClaudeTurns(ctx, j, dir, a, s)
}

// Claude print mode accepts an initialization control frame independently of
// conversation messages. Closing stdin after that frame lets the native CLI
// validate --resume without replaying the assignment or submitting a turn.
func initializeLegacyResume(ctx context.Context, j job, dir, sessionID string) error {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	cmd, err := agentCommand(ctx, j, dir)
	if err != nil {
		return err
	}
	const requestID = "commander-native-resume"
	cmd.Args = append(cmd.Args, "--resume", sessionID, "--input-format", "stream-json")
	cmd.Stdin = strings.NewReader(`{"type":"control_request","request_id":"` + requestID + `","request":{"subtype":"initialize"}}` + "\n")
	out, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	scan := bufio.NewScanner(out)
	scan.Buffer(make([]byte, 32<<10), 4<<20)
	confirmed, wrongSession := false, false
	for scan.Scan() {
		var frame struct {
			streamEvent
			Response struct {
				Subtype   string
				RequestID string `json:"request_id"`
			}
		}
		if json.Unmarshal(scan.Bytes(), &frame) != nil || (frame.Session != "" && frame.Session != sessionID) {
			wrongSession = true
			break
		}
		if frame.Type == "control_response" && frame.Response.RequestID == requestID && frame.Response.Subtype == "success" {
			confirmed = true
		}
		if frame.IsError {
			wrongSession = true
			break
		}
	}
	if wrongSession || scan.Err() != nil {
		cancel()
	}
	if err := cmd.Wait(); err != nil || wrongSession || scan.Err() != nil || !confirmed {
		return errors.New("Claude could not initialize the exact saved session with native --resume")
	}
	return nil
}

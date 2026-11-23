package provider

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

const codexBridgeEnv = "AGENT_COMMANDER_CODEX_BRIDGE"

type codexBridgeConfig struct {
	Executable, Profile string
	Policy              codexPolicy
}

func (cfg codexBridgeConfig) validate() error {
	if !filepath.IsAbs(cfg.Executable) || !filepath.IsAbs(cfg.Profile) ||
		!filepath.IsAbs(cfg.Policy.Checkout) || !filepath.IsAbs(cfg.Policy.Server.Command) ||
		len(cfg.Policy.Tools) == 0 {
		return errors.New("managed Codex requires absolute provider, profile, checkout and MCP paths")
	}
	info, err := os.Stat(cfg.Profile)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return errors.New("managed Codex requires a private, dedicated profile directory")
	}
	return nil
}

type codexNativeReader struct {
	mu        sync.Mutex
	threadID  string
	startID   string
	preflight chan error
}

const codexPreflightID = `"commander-config-check"`

// RunCodexBridge is a private CODEX_PATH entry point for the managed ACP
// profile. The normal Codex binary and its user configuration are independent.
func RunCodexBridge(ctx context.Context, input io.Reader, output io.Writer) error {
	var cfg codexBridgeConfig
	if err := json.Unmarshal([]byte(os.Getenv(codexBridgeEnv)), &cfg); err != nil {
		return errors.New("missing managed Codex bridge configuration")
	}
	if err := cfg.validate(); err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	cmd := exec.CommandContext(ctx, cfg.Executable, "app-server", "--listen", "stdio://")
	cmd.Dir = cfg.Profile
	for _, kv := range cmd.Environ() {
		key, _, _ := strings.Cut(kv, "=")
		switch key {
		case codexBridgeEnv, "CODEX_HOME", "CODEX_PATH", "CODEX_CONFIG":
			continue
		}
		cmd.Env = append(cmd.Env, kv)
	}
	cmd.Env = append(cmd.Env, "CODEX_HOME="+cfg.Profile)
	childIn, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	childOut, err := cmd.StdoutPipe()
	if err != nil {
		_ = childIn.Close()
		return err
	}
	if err := cmd.Start(); err != nil {
		_ = childIn.Close()
		_ = childOut.Close()
		return err
	}
	defer func() {
		cancel()
		_ = childIn.Close()
		_ = childOut.Close()
		_ = cmd.Wait()
	}()
	state := &codexNativeReader{preflight: make(chan error, 1)}
	var writeMu sync.Mutex
	write := func(data []byte) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		_, err := output.Write(append(data, '\n'))
		return err
	}
	done := make(chan error, 2)
	go func() {
		done <- state.readNative(childOut, write)
	}()
	go func() {
		done <- state.readAdapter(ctx, input, childIn, cfg.Policy, write)
	}()
	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

func scanCodexLines(in io.Reader, action func([]byte) error) error {
	scan := bufio.NewScanner(in)
	scan.Buffer(make([]byte, 16<<10), 8<<20)
	for scan.Scan() {
		if err := action(scan.Bytes()); err != nil {
			return err
		}
	}
	return scan.Err()
}

func (s *codexNativeReader) readNative(input io.Reader, write func([]byte) error) error {
	return scanCodexLines(input, func(line []byte) error {
		var msg struct {
			ID     json.RawMessage
			Method string
			Error  json.RawMessage
			Result json.RawMessage
		}
		if err := json.Unmarshal(line, &msg); err != nil {
			return err
		}
		if msg.Method != "" || len(msg.ID) == 0 {
			return write(line)
		}
		if string(msg.ID) == codexPreflightID {
			s.preflight <- validateCodexEffectiveConfig(msg.Result)
			return nil
		}
		s.mu.Lock()
		isStart := s.startID == string(msg.ID)
		s.mu.Unlock()
		var assignedThread string
		if isStart && (len(msg.Error) == 0 || string(msg.Error) == "null") {
			var result struct {
				Thread         struct{ ID string }
				ApprovalPolicy string
				Sandbox        struct{ Type string }
			}
			if err := json.Unmarshal(msg.Result, &result); err != nil || result.Thread.ID == "" ||
				result.ApprovalPolicy != "never" || result.Sandbox.Type != "readOnly" {
				return errors.New("Codex did not attest to the requested session policy")
			}
			assignedThread = result.Thread.ID
		}
		if isStart {
			s.mu.Lock()
			if assignedThread != "" {
				s.threadID = assignedThread
			}
			s.startID = ""
			s.mu.Unlock()
		}
		return write(line)
	})
}

func (s *codexNativeReader) readAdapter(ctx context.Context, input io.Reader, out io.Writer, policy codexPolicy, write func([]byte) error) error {
	encode := json.NewEncoder(out)
	return scanCodexLines(input, func(line []byte) error {
		var r codexRPC
		if err := json.Unmarshal(line, &r); err != nil {
			return err
		}
		// Responses to native callbacks have no method and must retain their body.
		if r.Method == "" {
			_, err := out.Write(append(line, '\n'))
			return err
		}
		s.mu.Lock()
		threadID, starting := s.threadID, s.startID != ""
		s.mu.Unlock()
		reject := func(err error) error {
			if len(r.ID) == 0 {
				return err
			}
			return write(rpcValue(map[string]any{"id": r.ID, "error": map[string]any{"code": -32602, "message": err.Error()}}))
		}
		if string(r.ID) == codexPreflightID || r.Method == "thread/start" && starting {
			return reject(errors.New("native request conflicts with the current managed session"))
		}
		if err := policy.apply(&r, threadID); err != nil {
			return reject(err)
		}
		sessionRequest := r.Method == "thread/start" || r.Method == "thread/resume"
		if sessionRequest || r.Method == "turn/start" {
			// Read effective profile and host configuration outside the checkout
			// before allowing App Server to start MCP processes.
			if err := encode.Encode(codexRPC{ID: json.RawMessage(codexPreflightID), Method: "config/read",
				Params: map[string]json.RawMessage{"includeLayers": rpcValue(false)}}); err != nil {
				return err
			}
			select {
			case err := <-s.preflight:
				if err != nil {
					return reject(err)
				}
			case <-ctx.Done():
				return ctx.Err()
			}
			if sessionRequest {
				s.mu.Lock()
				s.startID = string(r.ID)
				s.mu.Unlock()
			}
		}
		return encode.Encode(r)
	})
}

func validateCodexEffectiveConfig(result json.RawMessage) error {
	var data struct{ Config map[string]json.RawMessage }
	if err := json.Unmarshal(result, &data); err != nil || data.Config == nil {
		return errors.New("unable to validate the managed Codex profile")
	}
	for _, key := range []string{"mcp_servers", "hooks", "plugins", "skills"} {
		raw := strings.TrimSpace(string(data.Config[key]))
		if raw != "" && raw != "null" && raw != "{}" && raw != "[]" {
			return fmt.Errorf("managed Codex profile contains additional %s configuration", key)
		}
	}
	return nil
}

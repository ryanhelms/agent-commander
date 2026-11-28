package provider

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCodexBridgeDrainsSkillsResponseAfterAdapterEOF(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	appServer := filepath.Join(dir, "codex-fixture")
	// The adapter has already written its final request and closed stdin by
	// the time the fixture responds. The server can still reply on stdout.
	script := `#!/bin/sh
read -r request || exit 1
sleep 0.05
printf '%s\n' '{"id":7,"result":{"data":[]}}'
read -r request || true
`
	if err := os.WriteFile(appServer, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv(codexBridgeEnv, string(rpcValue(codexBridgeConfig{
		Executable: appServer,
		Profile:    dir,
		Policy: codexPolicy{
			Checkout: dir,
			Server:   mcpServer{Command: "/bin/false"},
			Tools:    []string{"commander_status"},
		},
	})))
	var adapterOutput bytes.Buffer
	adapterInput := strings.NewReader("{\"id\":7,\"method\":\"skills/list\"}\n")
	if err := RunCodexBridge(t.Context(), adapterInput, &adapterOutput); err != nil {
		t.Fatal(err)
	}
	if got := adapterOutput.String(); got != "{\"id\":7,\"result\":{\"data\":[]}}\n" {
		t.Fatalf("adapter lost its pending skills result: %q", got)
	}
}

func TestCodexBridgeSkillsDrainHonorsNativeFailureAndCancellation(t *testing.T) {
	reader := new(codexNativeReader)
	reader.beginSkillsRequest("7")
	nativeDone := make(chan error, 1)
	nativeDone <- os.ErrClosed
	if err := reader.drainSkills(t.Context(), nativeDone); err != os.ErrClosed {
		t.Fatalf("native failure was lost: %v", err)
	}

	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if err := reader.drainSkills(ctx, nativeDone); err != context.Canceled {
		t.Fatalf("cancellation was lost: %v", err)
	}
}

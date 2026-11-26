package actions

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestHostRunRunsOnlyEnrolledCommands(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "host.json")
	config, err := json.Marshal(map[string][]HostCommand{"commands": {
		{Name: "echo", Args: []string{"/bin/echo", "hello"}, Dir: dir},
		{Name: "append", Args: []string{"/bin/echo", "hello"}, Dir: dir, AllowArgs: true},
	}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, config, 0600); err != nil {
		t.Fatal(err)
	}
	r, err := PrepareResource(t.Context(), Resource{ID: "h", Name: "Mac", Kind: "host", Target: file})
	if err != nil {
		t.Fatal(err)
	}
	cfg := Config{StateDir: dir, Resources: []Resource{r},
		Grants: []Grant{{Peer: "sam", Resource: "h", Action: "host.run", ExpiresAt: time.Now().Add(time.Hour), MaxUses: 5}}}

	for _, tc := range []struct{ id, payload, output string }{
		{"fixed", `{"command":"echo"}`, "hello\n"},
		{"appended", `{"command":"append","args":["world"]}`, "hello world\n"},
	} {
		out, err := action(t, cfg, tc.id, "sam", "h", "host.run", json.RawMessage(tc.payload))
		if err != nil || out["output"] != tc.output || out["exitCode"] != float64(0) {
			t.Fatalf("%s: got %+v, %v", tc.id, out, err)
		}
	}

	for _, tc := range []struct{ id, payload, reason string }{
		{"extra", `{"command":"echo","args":["x"]}`, "echo does not accept extra arguments"},
		{"unknown", `{"command":"other"}`, "other is not an enrolled command"},
	} {
		t.Run(tc.id, func(t *testing.T) {
			for attempt := 1; attempt <= 2; attempt++ {
				_, err := action(t, cfg, tc.id, "sam", "h", "host.run", json.RawMessage(tc.payload))
				if err == nil || err.Error() != tc.reason || FailureCode(err) != "invalid_request" || FailureReason(err) != tc.reason {
					t.Fatalf("attempt %d: got %v, code %q, reason %q", attempt, err, FailureCode(err), FailureReason(err))
				}
			}
		})
	}
	_, err = action(t, cfg, "no-grant", "guest", "h", "host.run", json.RawMessage(`{"command":"other"}`))
	if err != ErrDenied || FailureCode(err) != "access_denied" || FailureReason(err) != "" {
		t.Fatalf("request without a grant: got %v, code %q, reason %q", err, FailureCode(err), FailureReason(err))
	}
}

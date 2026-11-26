package actions

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestHostRunRunsOnlyEnrolledCommands(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "host.json")
	os.WriteFile(file, []byte(`{"commands":[{"name":"echo","args":["/bin/echo","hello"],"dir":"`+dir+`"}]}`), 0600)
	r, err := PrepareResource(context.Background(), Resource{ID: "h", Name: "Mac", Kind: "host", Target: file})
	if err != nil {
		t.Fatal(err)
	}
	cfg := Config{StateDir: filepath.Join(dir, "state"), Resources: []Resource{r},
		Grants: []Grant{{Peer: "sam", Resource: "h", Action: "host.run", ExpiresAt: time.Now().Add(time.Hour), MaxUses: 5}}}
	os.MkdirAll(cfg.StateDir, 0700)
	out, err := Execute(context.Background(), cfg, Request{ID: "r1", Peer: "sam", Resource: "h", Action: "host.run", Payload: json.RawMessage(`{"command":"echo"}`)})
	if err != nil || !strings.Contains(string(out), "hello") {
		t.Fatalf("run: %s %v", out, err)
	}
	if _, err = Execute(context.Background(), cfg, Request{ID: "r2", Peer: "sam", Resource: "h", Action: "host.run", Payload: json.RawMessage(`{"command":"echo","args":["x"]}`)}); err == nil {
		t.Fatal("extra args accepted without allowArgs")
	}
	if _, err = Execute(context.Background(), cfg, Request{ID: "r3", Peer: "sam", Resource: "h", Action: "host.run", Payload: json.RawMessage(`{"command":"rm"}`)}); err == nil {
		t.Fatal("unenrolled command ran")
	}
}

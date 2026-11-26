package device

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"agentcommander.network/pilot/internal/control"
)

func TestReviewPost(t *testing.T) {
	dir := t.TempDir()
	argsFile := filepath.Join(dir, "args")
	const stub = "#!/bin/sh\nprintf '%s\\0' \"$@\" >> \"$GH_ARGS\"\n"
	if err := os.WriteFile(filepath.Join(dir, "gh"), []byte(stub), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	t.Setenv("GH_ARGS", argsFile)

	resources := []control.Resource{{ID: "reviewer", Actions: []string{"review.request"}}}
	a := newRequester(t, resources, false, func(control.Child, json.RawMessage) any {
		return json.RawMessage(`{"summary":"Two changes needed.","findings":[
			{"file":"queue.go","line":17,"severity":"important","text":"Handle the write error."},
			{"file":"docs/usage.md","line":0,"severity":"nit","text":"Update the example."}]}`)
	})
	h := a.Handler()
	raw, why := call(t, h, "send", input{Resource: "reviewer", Capability: "review.request", Payload: json.RawMessage(`{"diff":"+added"}`)})
	var sent struct{ Request, Status string }
	if why != "" || json.Unmarshal(raw, &sent) != nil || sent.Request == "" || sent.Status != "completed" {
		t.Fatalf("send review: %s %s", raw, why)
	}
	const pr = "https://github.example/team/project/pull/7"
	if _, why := call(t, h, "review-post", input{Request: sent.Request, PR: "http://github.example/team/project/pull/7"}); why == "" {
		t.Fatal("review-post accepted an HTTP URL")
	}
	if _, err := os.Stat(argsFile); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("unexpected gh invocation before posting to the HTTPS PR: stat error %v", err)
	}

	raw, why = call(t, h, "review-post", input{Request: sent.Request, PR: pr})
	var posted struct{ Posted string }
	if why != "" || json.Unmarshal(raw, &posted) != nil || posted.Posted != pr {
		t.Fatalf("review-post: %s %s", raw, why)
	}
	data, err := os.ReadFile(argsFile)
	if err != nil {
		t.Fatal(err)
	}
	const body = "Two changes needed.\n\n- **important** `queue.go:17`: Handle the write error.\n- **nit** `docs/usage.md`: Update the example."
	want := []string{"pr", "review", pr, "--comment", "--body", body}
	if args := strings.Split(strings.TrimSuffix(string(data), "\x00"), "\x00"); !slices.Equal(args, want) {
		t.Errorf("gh arguments = %q, want %q", args, want)
	}
}

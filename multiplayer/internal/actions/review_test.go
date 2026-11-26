package actions

import (
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestReviewRequest(t *testing.T) {
	const diff = "@@ -1 +1 @@\n-close()\n+return nil"
	const pr = "https://example.invalid/project/pull/7"
	const plain = "I could not read the pull request.\nPlease send a diff."
	for _, tt := range []struct {
		name, source, change string
		response, summary    string
		findings             []any
	}{
		{
			name: "diff with structured answer", source: "diff", change: diff,
			response: `{"summary":"Handle the error.","findings":[{"file":"main.go","line":12,"severity":"important","text":"Return the close error."}]}`,
			summary:  "Handle the error.",
			findings: []any{map[string]any{"file": "main.go", "line": float64(12), "severity": "important", "text": "Return the close error."}},
		},
		{
			name: "PR with plain answer", source: "pr", change: pr,
			response: plain, summary: plain, findings: []any{},
		},
	} {
		t.Run(tt.name, func(t *testing.T) {
			worker := startAskWorker(t, tt.response)
			worker.ready.Store(true)
			cfg := Config{
				StateDir: t.TempDir(), CommanderSocket: worker.socket,
				Resources: []Resource{{ID: "coach", Kind: "agent", Target: "worker"}},
				Grants:    []Grant{{Peer: "sam", Resource: "coach", Action: "review.request", ExpiresAt: time.Now().Add(time.Hour)}},
			}
			payload := map[string]string{"title": "Close the writer", "instructions": "Check error propagation", tt.source: tt.change}
			got, err := action(t, cfg, "with-change", "sam", "coach", "review.request", payload)
			if err != nil {
				t.Fatal(err)
			}
			if got["summary"] != tt.summary || !reflect.DeepEqual(got["findings"], tt.findings) || got["tokens"] != float64(7) {
				t.Fatalf("review result: %+v", got)
			}
			prompt, _ := worker.savedText.Load().(string)
			for _, part := range []string{reviewPrompt, payload["title"], payload["instructions"], tt.change} {
				if !strings.Contains(prompt, part) {
					t.Errorf("worker prompt missing %q: %q", part, prompt)
				}
			}
		})
	}
}

func TestReviewHandlerRequiresDiffOrPR(t *testing.T) {
	req := Request{Payload: json.RawMessage(`{"title":"Close the writer","instructions":"Check errors"}`)}
	_, err := reviewHandler(t.Context(), Config{}, Resource{Target: "worker"}, req, "no-change", false)
	if !errors.Is(err, ErrInvalid) {
		t.Fatalf("review without a diff or PR: got %v, want ErrInvalid", err)
	}
}

func TestParseReviewPreservesInvalidJSONAnswer(t *testing.T) {
	const response = `{"summary":"First pass","findings":[{"file":"main.go","line":8,"severity":"nit","text":"Rename local."}]}
I also found a second issue.`
	got := parseReview(response)
	if got["summary"] != response || !reflect.DeepEqual(got["findings"], []ReviewFinding{}) {
		t.Fatalf("review of mixed JSON and prose discarded part of the answer: %+v", got)
	}
}

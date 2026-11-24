package provider

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"unicode/utf8"

	"agentcommander/internal/localapi"
	"agentcommander/internal/service"
)

func TestScreenBurstAndRetryPreserveOrder(t *testing.T) {
	// A short socket path also fits the Darwin sockaddr_un limit.
	dir, err := os.MkdirTemp("", "ac-output-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	socket := filepath.Join(dir, "s")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var received []outputBatch
	var first []byte
	var retried bool
	var reads int
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer worker-token" {
			t.Error("missing worker authorization")
		}
		if r.Method == http.MethodGet {
			mu.Lock()
			defer mu.Unlock()
			reads++
			io.WriteString(w, `{"stream_id":"previous-runner"}`)
			return
		}
		data, err := io.ReadAll(r.Body)
		var batch outputBatch
		if err != nil || len(data) > 1<<20 || json.Unmarshal(data, &batch) != nil ||
			len(batch.Events) > 24 || batch.StreamID == "" {
			t.Error("invalid output request")
			http.Error(w, "invalid batch", http.StatusBadRequest)
			return
		}
		mu.Lock()
		defer mu.Unlock()
		switch {
		case first == nil:
			if batch.ReplacesStreamID == nil || *batch.ReplacesStreamID != "previous-runner" {
				t.Error("first output batch did not bind its predecessor")
			}
			first = data
			received = append(received, batch)
			// Commit, then lose the acknowledgment. A retry identifies
			// and reproduces exactly the same committed payload.
			http.Error(w, "acknowledgment unavailable", http.StatusServiceUnavailable)
			return
		case !retried:
			if !bytes.Equal(first, data) {
				t.Error("retry changed the batch or its sequence")
			}
			retried = true
		default:
			if batch.ReplacesStreamID != nil {
				t.Error("noninitial batch attempted to replace a stream")
			}
			received = append(received, batch)
		}
		io.WriteString(w, "{}")
	})}
	go server.Serve(listener)
	defer server.Close()
	s := openScreen(context.Background(), &api{localapi.New(socket, "worker-token")}, "worker")
	const count = 311
	for i := 0; i < count; i++ {
		s.event("text", "", "", fmt.Sprint(i))
	}
	s.flush()
	// A caller can now record the operation end. Every preceding event
	// must already have reached the sink when this barrier returns.
	mu.Lock()
	seen := 0
	for i, batch := range received {
		if batch.Batch != uint64(i+1) || batch.StreamID != received[0].StreamID {
			t.Errorf("incorrect batch order at %d", i)
		}
		for _, event := range batch.Events {
			if event.Kind != "text" || event.Text != fmt.Sprint(seen) {
				t.Errorf("event %d = %+v", seen, event)
			}
			seen++
		}
	}
	if !retried || seen != count || reads != 1 {
		t.Errorf("preflights=%d retry=%t delivered=%d, want one read and %d events", reads, retried, seen, count)
	}
	mu.Unlock()
	s.close()
}

func TestScreenToolPreviewFitsServiceLimits(t *testing.T) {
	source := service.ConsoleEvent{Kind: "tool_call", ToolID: strings.Repeat("a", 257),
		Name: strings.Repeat("λ", 129), Phase: strings.Repeat("中", 24),
		Text: strings.Repeat("中", maxConsoleEventBytes)}
	preview := previewConsoleEvent(source)
	if len(preview.ToolID) > 256 || len(preview.Name) > 256 || len(preview.Phase) > 64 ||
		len(preview.Text) > 17<<10 || !utf8.ValidString(preview.Phase+preview.Name+preview.Text) {
		t.Fatal("console preview exceeds a wire limit or splits a code point")
	}
	if preview.ToolID != previewConsoleEvent(source).ToolID {
		t.Fatal("tool call and update must get the same identity")
	}
	source.ToolID = preview.ToolID
	if preview.ToolID == previewConsoleEvent(source).ToolID {
		t.Fatal("a literal ID using the reserved prefix collided with a long ID")
	}
}

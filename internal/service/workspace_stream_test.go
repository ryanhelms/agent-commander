package service

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// Hold one subscriber at an actual delta write instead of assuming an
// unread client socket has exhausted its TCP buffers.
type heldWorkspaceWriter struct {
	http.ResponseWriter
	ctx          context.Context
	marker       []byte
	writeStarted chan struct{}
	releaseWrite <-chan struct{}
}

func (w *heldWorkspaceWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (w *heldWorkspaceWriter) Write(data []byte) (int, error) {
	if w.writeStarted != nil && bytes.Contains(data, w.marker) {
		close(w.writeStarted)
		w.writeStarted = nil
		select {
		case <-w.releaseWrite:
		case <-w.ctx.Done():
			return 0, w.ctx.Err()
		}
	}
	return w.ResponseWriter.Write(data)
}

func TestWorkspaceSlowSocketRecoversPendingApproval(t *testing.T) {
	f := newFixture(t)
	writer, approval := f.run(), f.run()
	const heldMarker = "hold-this-workspace-delta"
	const subscriberHeader = "X-Workspace-Test-Subscriber"
	writeStarted, releaseWrite := make(chan struct{}), make(chan struct{})
	release := sync.OnceFunc(func() { close(releaseWrite) })
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get(subscriberHeader) == "slow" {
			w = &heldWorkspaceWriter{
				ResponseWriter: w, ctx: r.Context(), marker: []byte(heldMarker),
				writeStarted: writeStarted, releaseWrite: releaseWrite,
			}
		}
		f.api.ServeHTTP(w, r)
	}))
	defer server.Close()
	defer release()

	client := server.Client()
	client.Timeout = 12 * time.Second
	const route = "/v1/ag-ui/events?projection=incremental"
	open := func(name string) (*http.Response, *bufio.Scanner) {
		t.Helper()
		request, err := http.NewRequestWithContext(t.Context(), http.MethodGet, server.URL+route, nil)
		if err != nil {
			t.Fatal(err)
		}
		request.Header.Set(subscriberHeader, name)
		response, err := client.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		if response.StatusCode != http.StatusOK {
			response.Body.Close()
			t.Fatalf("workspace stream returned %s", response.Status)
		}
		scanner := bufio.NewScanner(response.Body)
		scanner.Buffer(make([]byte, 4096), 4<<20)
		return response, scanner
	}
	next := func(scanner *bufio.Scanner) string {
		t.Helper()
		for scanner.Scan() {
			if payload, ok := strings.CutPrefix(scanner.Text(), "data: "); ok {
				return payload
			}
		}
		t.Fatalf("workspace stream ended before the expected event: %v", scanner.Err())
		return ""
	}

	var question Question
	payload := f.call("POST", "/v1/workers/"+approval.ID+"/questions", approval.Token,
		map[string]any{"question": "Confirm slow workspace test?", "choices": []QuestionChoice{
			{ID: "allow_once", Label: "Allow once"}, {ID: "reject", Label: "Reject"},
		}}, 201, "")
	if err := json.Unmarshal(payload, &question); err != nil || question.ID == "" {
		t.Fatalf("could not create addressed approval: %s (%v)", payload, err)
	}
	assertPending := func(snapshot string) string {
		t.Helper()
		var event struct {
			Type     string
			Snapshot struct {
				Runs []struct {
					Requests []Question
					Workers  []struct {
						ID           string
						OutputChunks []string
					}
				}
			}
		}
		if err := json.Unmarshal([]byte(snapshot), &event); err != nil || event.Type != "STATE_SNAPSHOT" {
			t.Fatalf("expected a workspace snapshot (%v, %d bytes)", err, len(snapshot))
		}
		pending := false
		var output string
		for _, run := range event.Snapshot.Runs {
			for _, request := range run.Requests {
				if request.ID == question.ID && request.WorkerID == approval.ID && request.Status == "pending" {
					pending = true
				}
			}
			for _, worker := range run.Workers {
				if worker.ID == writer.ID {
					output = strings.Join(worker.OutputChunks, "")
				}
			}
		}
		if !pending {
			t.Fatal("workspace snapshot lost the addressed pending approval")
		}
		return output
	}
	slow, delayed := open("slow")
	defer slow.Body.Close()
	assertPending(next(delayed))
	fast, current := open("fast")
	defer fast.Body.Close()
	assertPending(next(current))

	outputPath := "/v1/workers/" + writer.ID + "/output"
	publish := func(marker string) {
		t.Helper()
		f.call("POST", outputPath, writer.Token, map[string]string{"text": marker + "\n"}, 200, "")
	}
	assertDelta := func(reader *bufio.Scanner, marker string) {
		t.Helper()
		raw := next(reader)
		var event aguiStateEvent
		if err := json.Unmarshal([]byte(raw), &event); err != nil || event.Type != "STATE_DELTA" {
			t.Fatalf("expected a workspace delta for %s (%v, %d bytes)", marker, err, len(raw))
		}
		var output strings.Builder
		for _, patch := range event.Delta {
			if chunk, ok := patch.Value.(string); ok && strings.Contains(patch.Path, "/outputChunks/") {
				output.WriteString(chunk)
			}
		}
		if !strings.HasSuffix(output.String(), marker+"\n") {
			t.Fatalf("workspace delta missed the output marker %s", marker)
		}
	}

	publish(heldMarker)
	select {
	case <-writeStarted:
	case <-time.After(5 * time.Second):
		t.Fatal("slow subscriber did not reach the held workspace write")
	}
	assertDelta(current, heldMarker)

	// Deliver more than the retained 64 revisions to the fast subscriber
	// while the slow subscriber is still writing its first delta.
	const revisions = 96
	lastMarker := fmt.Sprintf("burst-%03d", revisions)
	for i := 1; i <= revisions; i++ {
		marker := fmt.Sprintf("burst-%03d", i)
		publish(marker)
		assertDelta(current, marker)
	}

	release()
	assertDelta(delayed, heldMarker)
	recovery := next(delayed)
	output := assertPending(recovery)
	if !strings.Contains(recovery, `"reason":"workspace_delta_expired"`) || !strings.HasSuffix(output, lastMarker+"\n") {
		t.Fatalf("slow subscriber did not recover the latest expired revision (payload %d bytes)", len(recovery))
	}

	f.call("POST", "/v1/requests/"+question.ID+"/reply", "", map[string]string{"answer": "allow_once"}, 200, "slow-approval")
	for _, reader := range []*bufio.Scanner{delayed, current} {
		event := next(reader)
		if !strings.Contains(event, `"type":"STATE_DELTA"`) || !strings.Contains(event, `"status":"answered"`) ||
			!strings.Contains(event, `"answer":"allow_once"`) {
			t.Fatalf("workspace reader missed the approval resolution (payload %d bytes)", len(event))
		}
	}
}

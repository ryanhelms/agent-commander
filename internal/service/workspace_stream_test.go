package service

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// A small send buffer lets the test exhaust the slow socket without depending
// on the host's default TCP buffer size.
type smallSendBuffer struct{ *net.TCPListener }

func (l smallSendBuffer) Accept() (net.Conn, error) {
	conn, err := l.AcceptTCP()
	if err != nil {
		return nil, err
	}
	if err := conn.SetWriteBuffer(4096); err != nil {
		conn.Close()
		return nil, err
	}
	return conn, nil
}

func TestWorkspaceSlowSocketRecoversPendingApproval(t *testing.T) {
	f := newFixture(t)
	writer, approval := f.run(), f.run()
	server := httptest.NewUnstartedServer(f.api)
	server.Listener = smallSendBuffer{server.Listener.(*net.TCPListener)}
	server.Start()
	defer server.Close()

	transport := &http.Transport{DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		dialer := &net.Dialer{}
		conn, err := dialer.DialContext(ctx, network, address)
		if err != nil {
			return nil, err
		}
		if err := conn.(*net.TCPConn).SetReadBuffer(4096); err != nil {
			conn.Close()
			return nil, err
		}
		return conn, nil
	}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 12 * time.Second}
	const route = "/v1/ag-ui/events?projection=incremental"
	open := func() (*http.Response, *bufio.Scanner) {
		t.Helper()
		response, err := client.Get(server.URL + route)
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
	assertPending := func(snapshot string) {
		t.Helper()
		var event struct {
			Type     string
			Snapshot struct {
				Runs []Run
			}
		}
		if err := json.Unmarshal([]byte(snapshot), &event); err != nil || event.Type != "STATE_SNAPSHOT" {
			t.Fatalf("expected a workspace snapshot (%v, %d bytes)", err, len(snapshot))
		}
		for _, run := range event.Snapshot.Runs {
			for _, request := range run.Requests {
				if request.ID == question.ID && request.WorkerID == approval.ID && request.Status == "pending" {
					return
				}
			}
		}
		t.Fatal("workspace snapshot lost the addressed pending approval")
	}
	slow, delayed := open()
	defer slow.Body.Close()
	assertPending(next(delayed))

	// Leave the socket unread while publishing more than one history window.
	outputPath := "/v1/workers/" + writer.ID + "/output"
	burst := strings.Repeat("f", 16<<10)
	const revisions = 96
	lastMarker := fmt.Sprintf("burst-%03d", revisions)
	for i := 1; i <= revisions; i++ {
		f.call("POST", outputPath, writer.Token, map[string]string{"text": fmt.Sprintf("burst-%03d\n%s\n", i, burst)}, 200, "")
	}
	fast, current := open()
	defer fast.Body.Close()
	snapshot := next(current)
	assertPending(snapshot)
	if !strings.Contains(snapshot, lastMarker) {
		t.Fatal("fresh workspace subscriber did not receive the latest output")
	}
	recovered, reachedLatest := false, false
	for !recovered || !reachedLatest {
		event := next(delayed)
		if strings.Contains(event, `"reason":"workspace_delta_expired"`) {
			assertPending(event)
			recovered = true
		}
		reachedLatest = reachedLatest || strings.Contains(event, lastMarker)
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

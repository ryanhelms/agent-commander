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
	"testing"
	"time"

	model "agent-acp.local/sdks/go/model"
	"google.golang.org/protobuf/encoding/protojson"
)

func TestLiveSourceStreamResumesAtItsLastCommittedPage(t *testing.T) {
	f := newFixture(t)
	owner, other := f.run(), f.run()
	path := "/v1/workers/" + owner.ID + "/live-source"
	ref := NativeSession{HarnessInstance: "fixture", SessionID: "origin"}
	f.call("POST", "/v1/workers/"+owner.ID+"/native-session", "", ref, 200, "")
	f.call("POST", "/v1/workers/"+other.ID+"/native-session", "", NativeSession{
		HarnessInstance: "fixture", SessionID: "second",
	}, 200, "")
	f.call("GET", path+"/events", owner.Token, nil, 403, "")
	server := httptest.NewServer(f.api)
	defer server.Close()
	publish := func(first, count int) {
		t.Helper()
		batch := make([]LiveSourceUpdate, 0, LiveSourceBatchRecords)
		for n := first; n < first+count; n++ {
			batch = append(batch, LiveSourceUpdate{
				Session: ref, Cursor: fmt.Sprint(n), TurnID: "turn",
				Body: fmt.Appendf(nil, `{"privateValue":%d}`, n),
			})
			if len(batch) == cap(batch) || n+1 == first+count {
				f.call("POST", path+"/batch", owner.Token, batch, 200, "")
				batch = batch[:0]
			}
		}
	}
	connect := func(after string) (*bufio.Scanner, func()) {
		t.Helper()
		ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
		req, err := http.NewRequestWithContext(ctx, "GET", server.URL+path+"/events", nil)
		if err != nil {
			t.Fatal(err)
		}
		if after != "" {
			req.Header.Set("Last-Event-ID", after)
		}
		response, err := server.Client().Do(req)
		if err != nil || response.StatusCode != 200 || response.Header.Get("Content-Type") != "text/event-stream" {
			t.Fatalf("could not open scoped source stream: %+v, %v", response, err)
		}
		scanner := bufio.NewScanner(response.Body)
		scanner.Buffer(make([]byte, 4096), 8<<20)
		return scanner, func() { cancel(); response.Body.Close() }
	}
	next := func(scanner *bufio.Scanner) (string, *model.ReadHistoryResponse) {
		t.Helper()
		var id string
		for scanner.Scan() {
			line := scanner.Bytes()
			if cursor, ok := bytes.CutPrefix(line, []byte("id: ")); ok {
				id = string(cursor)
			}
			if data, ok := bytes.CutPrefix(line, []byte("data: ")); ok {
				var page model.ReadHistoryResponse
				if err := protojson.Unmarshal(data, &page); err != nil {
					t.Fatal(err)
				}
				return id, &page
			}
		}
		t.Fatalf("source stream finished before a page: %v", scanner.Err())
		return "", nil
	}
	check := func(obs *model.Observation, i int) {
		t.Helper()
		if obs.GetCursor() != fmt.Sprint(i) || obs.GetTurnId() != "turn" ||
			obs.GetSession().GetSessionId() != ref.SessionID ||
			string(obs.GetExtension().GetData()) != fmt.Sprintf(`{"privateValue":%d}`, i) {
			t.Fatalf("source record %d changed or arrived out of order: %v", i, obs)
		}
	}

	first, stop := connect("")
	defer stop()
	publish(1, 2)
	var checkpoint string
	for expected := 1; expected <= 2; {
		id, page := next(first)
		for _, record := range page.Observations {
			check(record, expected)
			expected++
		}
		checkpoint = id
	}
	stop()
	if !strings.HasPrefix(checkpoint, owner.ID+".") {
		t.Fatal("stream did not checkpoint the final retained page")
	}
	f.call("GET", "/v1/workers/"+other.ID+"/live-source/events?after="+checkpoint, "", nil, 400, "")

	second, stopSecond := connect(checkpoint)
	defer stopSecond()
	publish(3, 1)
	checkpoint, page := next(second)
	if len(page.Observations) != 1 {
		t.Fatalf("resumed stream repeated acknowledged records: %v", page)
	}
	check(page.Observations[0], 3)
	stopSecond()

	publish(4, LiveSourceWindowRecords+3)
	third, stopThird := connect(checkpoint)
	defer stopThird()
	checkpoint, page = next(third)
	if checkpoint == "" || len(page.Observations) < 2 || page.Observations[0].GetGap() == nil {
		t.Fatalf("expired cursor did not return an explicit recoverable gap: %s %v", checkpoint, page)
	}
	check(page.Observations[1], 7)
}

func TestUncertainACPGapPreservesFollowUpReceipt(t *testing.T) {
	f := newFixture(t)
	coordinator := f.run()
	worker := f.delegate(coordinator, "source-gap")
	path := "/v1/workers/" + worker.ID
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", path+"/control/ready", worker.Token, struct{}{}, 200, "")
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed"}, 200, "")
	var sent WorkerFollowUp
	if err := json.Unmarshal(f.call("POST", path+"/messages", coordinator.Token, map[string]string{
		"text": "run this once",
	}, 202, "with-gap"), &sent); err != nil {
		t.Fatal(err)
	}
	f.call("POST", path+"/messages/"+sent.ID+"/claim", worker.Token, struct{}{}, 200, "")
	var finished Worker
	if err := json.Unmarshal(f.call("POST", path+"/control/finish", worker.Token, map[string]any{
		"state": "failed", "message_id": sent.ID, "delivery_unknown": true,
		"error": "live provider observations expired",
	}, 200, ""), &finished); err != nil {
		t.Fatal(err)
	}
	receipt := finished.Control.message(sent.ID)
	if receipt == nil || receipt.Status != "delivery_unknown" || receipt.Text != sent.Text || finished.State != "failed" {
		t.Fatalf("uncertain session lost its actual operation or allowed further control: %+v", finished)
	}
}

func TestIdleACPGapSuspendsFurtherClaims(t *testing.T) {
	f := newFixture(t)
	parent := f.run()
	worker := f.delegate(parent, "idle-source-gap")
	path := "/v1/workers/" + worker.ID
	ref := NativeSession{HarnessInstance: "external-fixture", SessionID: "bound-before-gap"}
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", path+"/native-session", "", ref, 200, "")
	f.call("POST", path+"/control/ready", worker.Token, struct{}{}, 200, "")
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed"}, 200, "")
	var queued WorkerFollowUp
	in := map[string]string{"text": "pending follow up"}
	if err := json.Unmarshal(f.call("POST", path+"/messages", parent.Token, in, 202, "original"), &queued); err != nil {
		t.Fatal(err)
	}
	body := map[string]string{
		"harness_instance": ref.HarnessInstance, "session_id": ref.SessionID,
		"reason": "observation_gap", "last_state": "completed",
	}
	var state Worker
	if err := json.Unmarshal(f.call("POST", path+"/control/provider-exit", worker.Token, body, 200, ""), &state); err != nil {
		t.Fatal(err)
	}
	receipt := state.Control.message(queued.ID)
	if state.ProviderAvailability != providerExited || state.State != "completed" || receipt == nil || receipt.Status != "cancelled" {
		t.Fatalf("gap lost the previous turn or left the queued operation claimable: %+v", state)
	}
	f.call("POST", path+"/messages/"+queued.ID+"/claim", worker.Token, struct{}{}, 409, "")
	f.call("POST", path+"/messages", parent.Token, in, 409, "new")
}

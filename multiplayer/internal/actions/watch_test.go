package actions

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestWatchEventsJoinChunksAndKeepToolsAndFailures(t *testing.T) {
	page := []byte(`{"records":[
		{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Reading "}}},
		{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"the test."}}},
		{"update":{"sessionUpdate":"tool_call","title":"swift test"}},
		{"update":{"sessionUpdate":"tool_call_update","status":"completed"}},
		{"update":{"sessionUpdate":"tool_call_update","title":"rg renew","status":"failed"}},
		{"update":{"sessionUpdate":"plan"}},
		{"observation":{}}
	],"nextCursor":"c2"}`)
	events, cursor := watchEvents(page, time.Unix(0, 0))
	if cursor != "c2" || len(events) != 3 {
		t.Fatalf("cursor %q events %+v", cursor, events)
	}
	if events[0].Kind != "message" || events[0].Text != "Reading the test." || events[1].Kind != "tool" || events[2].Text != "rg renew failed" {
		t.Fatalf("events %+v", events)
	}
}

func TestWatchHandlerReadsBoundedLiveHistory(t *testing.T) {
	const page = `{"records":[{"update":{"sessionUpdate":"tool_call","title":"go test"}}],"nextCursor":"second"}`
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/ag-ui/workers/worker", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"workerId":"worker","role":"worker","runStatus":"running"}`)
	})
	mux.HandleFunc("GET /v1/workers/worker/history", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if q.Get("source") != "live" || q.Get("view") != "acp" {
			t.Errorf("history query: %s", r.URL.RawQuery)
		}
		size := 64 << 10
		switch q.Get("cursor") {
		case "first":
		case "retry":
			size++
		default:
			t.Errorf("unexpected history cursor: %q", q.Get("cursor"))
		}
		fmt.Fprint(w, page, strings.Repeat(" ", size-len(page)))
	})
	cfg := Config{CommanderSocket: serveCommander(t, mux)}
	for _, tc := range []struct {
		name, after, cursor string
		available           bool
	}{
		{"at limit", "first", "second", true},
		{"over limit", "retry", "retry", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			payload, _ := json.Marshal(map[string]string{"after": tc.after})
			raw, err := watchHandler(t.Context(), cfg, Resource{Target: "worker"}, Request{Payload: payload}, "", false)
			if err != nil {
				t.Fatal(err)
			}
			var got struct {
				State, Cursor string
				Available     bool
				Events        []watchEvent
			}
			if err := json.Unmarshal(raw, &got); err != nil {
				t.Fatal(err)
			}
			if got.State != "running" || got.Cursor != tc.cursor || got.Available != tc.available {
				t.Fatalf("watch state or cursor: %s", raw)
			}
			if tc.available {
				if len(got.Events) != 1 || got.Events[0].Kind != "tool" || got.Events[0].Text != "go test" {
					t.Fatalf("64 KiB page: %s", raw)
				}
			} else if got.Events == nil || len(got.Events) != 0 {
				t.Fatalf("oversized page: %s", raw)
			}
		})
	}
}

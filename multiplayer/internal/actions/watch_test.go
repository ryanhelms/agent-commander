package actions

import (
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

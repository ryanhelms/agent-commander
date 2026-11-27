package service

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"agentcommander/internal/hosted"
)

type detailList struct {
	Revision uint64                  `json:"revision"`
	Records  []toolDetailSummaryView `json:"records"`
}

func claudePrivateDetails(marker string) []ToolDetail {
	duration := int64(0)
	failed := false
	return []ToolDetail{
		{Kind: "job", Key: "job-t1", Title: marker + " command",
			JobDetail: &JobDetail{ToolUseID: "t1", JobKind: "command", State: "completed"}, Result: marker + " exit"},
		{Kind: "job", Key: "job-t2", Title: marker + " agent",
			JobDetail: &JobDetail{ToolUseID: "t2", JobKind: "agent", State: "running", OpenToolName: "Read", OpenToolArg: marker + ".go"}},
		{Kind: "turn_end", Key: "turn-end-r1", TurnEndDetail: &TurnEndDetail{
			DurationMS: &duration, StopReason: marker + " stop", TerminalReason: marker + " terminal", IsError: &failed}},
		{Kind: "thought", Key: "thought-a", StartedAt: "2026-01-02T03:04:05Z", EndedAt: "2026-01-02T03:04:06Z", Result: marker + " thought"},
	}
}

func TestToolDetailsReachOnlyTheLocalOwner(t *testing.T) {
	f := newFixture(t)
	coordinator := f.run()
	worker := f.delegate(coordinator, "detailed")
	path := "/v1/workers/" + worker.ID
	const marker = "MARKER-only-in-details"
	zero := 0
	long := strings.Repeat("x", 600)
	f.call("POST", path+"/output", worker.Token, map[string]any{
		"stream_id": "s", "batch": 1, "text": "",
		"events": []ConsoleEvent{{Kind: "tool_call", ToolID: "t1", Name: "Bash", Text: "preview"}},
		"details": []ToolDetail{{Kind: "tool", Key: "t1", Event: &zero, Name: "Bash",
			Input:     `{"command":"echo ` + marker + `","description":"Say it","long":"` + long + `","n":{"a":1}}`,
			StartedAt: "2026-01-02T03:04:05Z"}},
	}, 200, "")
	f.call("POST", path+"/output", worker.Token, map[string]any{
		"stream_id": "s", "batch": 2, "text": "",
		"details": append([]ToolDetail{{Kind: "tool", Key: "t1", Result: marker + " result", EndedAt: "2026-01-02T03:04:07Z"}}, claudePrivateDetails(marker)...),
	}, 200, "")

	var list detailList
	if err := json.Unmarshal(f.call("GET", path+"/tool-details", "", nil, 200, ""), &list); err != nil || len(list.Records) != 5 {
		t.Fatalf("list: %+v, %v", list, err)
	}
	got := list.Records[0]
	if got.Sequence != 1 || got.Input != "" || got.Result != "" || got.ResultBytes == 0 ||
		got.StartedAt != "2026-01-02T03:04:05Z" || got.EndedAt != "2026-01-02T03:04:07Z" ||
		string(got.Fields) != `{"command":"echo `+marker+`","description":"Say it"}` {
		t.Fatalf("summary: %+v %s", got, got.Fields)
	}
	var full ToolDetail
	if err := json.Unmarshal(f.call("GET", path+"/tool-details?key=t1", "", nil, 200, ""), &full); err != nil ||
		!strings.Contains(full.Input, long) || !strings.Contains(full.Result, marker) {
		t.Fatalf("full record: %v", err)
	}

	for i, want := range claudePrivateDetails(marker) {
		row := list.Records[i+1]
		if row.Key != want.Key || row.Kind != want.Kind || row.Sequence != 1 || row.Result != "" ||
			!reflect.DeepEqual(row.JobDetail, want.JobDetail) || !reflect.DeepEqual(row.TurnEndDetail, want.TurnEndDetail) {
			t.Fatalf("summary %s: %+v", want.Key, row)
		}
		var record ToolDetail
		if err := json.Unmarshal(f.call("GET", path+"/tool-details?key="+want.Key, "", nil, 200, ""), &record); err != nil ||
			record.Result != want.Result || record.EndedAt != want.EndedAt {
			t.Fatalf("full %s: %+v, %v", want.Key, record, err)
		}
	}

	// Nothing outside the owner's details routes carries the values.
	f.call("GET", path+"/tool-details", worker.Token, nil, 403, "")
	f.call("GET", path+"/tool-details", coordinator.Token, nil, 403, "")
	for _, shared := range []string{"/v1/runs", "/v1/runs/" + worker.RunID, "/v1/runs/" + worker.RunID + "?view=ag-ui", "/v1/ag-ui" + strings.TrimPrefix(path, "/v1")} {
		if body := f.call("GET", shared, "", nil, 200, ""); strings.Contains(string(body), marker) || strings.Contains(string(body), "started_at") {
			t.Fatalf("%s carries tool details", shared)
		}
	}

	// Exercise the hosted route allowlist without a network listener.
	gateway := (&hosted.Gateway{}).Handler(f.api)
	for _, detail := range claudePrivateDetails(marker) {
		req := httptest.NewRequest(http.MethodGet, path+"/tool-details?key="+detail.Key, nil)
		w := httptest.NewRecorder()
		gateway.ServeHTTP(w, req)
		if w.Code != http.StatusNotFound || strings.Contains(w.Body.String(), marker) {
			t.Fatalf("hosted read for %s: %d", detail.Kind, w.Code)
		}
	}

	// A restarted service reads the same record.
	restarted, err := New(f.dir, f.p)
	if err != nil {
		t.Fatal(err)
	}
	f.api = restarted
	if err := json.Unmarshal(f.call("GET", path+"/tool-details?key=t1", "", nil, 200, ""), &full); err != nil || !strings.Contains(full.Result, marker) {
		t.Fatalf("after restart: %v", err)
	}
}

func TestDetailRoutesRefuseAuthorizationHeaders(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/v1/settings/transcript", nil)
	request.Header.Set("Authorization", "Bearer anything")
	if localOwner(request, "") {
		t.Fatal("a bearer request passed as the local owner")
	}
}

func TestTranscriptLimitShortensNewValuesInOrder(t *testing.T) {
	f := newFixture(t)
	coordinator := f.run()
	worker := f.delegate(coordinator, "limited")
	path := "/v1/workers/" + worker.ID
	if body := f.call("GET", "/v1/settings/transcript", "", nil, 200, ""); !strings.Contains(string(body), `"limit_bytes":0`) {
		t.Fatalf("default keeps everything: %s", body)
	}
	f.call("POST", "/v1/settings/transcript", worker.Token, map[string]any{"limit_bytes": 1024}, 403, "")
	f.call("POST", "/v1/settings/transcript", "", map[string]any{"limit_bytes": 10}, 400, "")
	f.call("POST", "/v1/settings/transcript", "", map[string]any{"limit_bytes": 1024, "hide_secrets": true}, 200, "")
	long := strings.Repeat("y", 2000)
	f.call("POST", path+"/output", worker.Token, map[string]any{"stream_id": "s", "batch": 1, "text": "",
		"details": []ToolDetail{{Kind: "tool", Key: "t", Input: `{"z":"` + long + `","a":[1,true,null,"<ok>"]}`}}}, 200, "")
	var full ToolDetail
	if err := json.Unmarshal(f.call("GET", path+"/tool-details?key=t", "", nil, 200, ""), &full); err != nil {
		t.Fatal(err)
	}
	want := `{"z":"` + strings.Repeat("y", 1024) + shortenedMark + `","a":[1,true,null,"<ok>"]}`
	if full.Input != want || len(full.Truncated) != 1 || full.Truncated[0] != "input" {
		t.Fatalf("shortened: %.80s… %v", full.Input, full.Truncated)
	}
}

func TestOwnerCancelsQueuedFollowUp(t *testing.T) {
	f := newFixture(t)
	coordinator := f.run()
	worker := f.delegate(coordinator, "queued")
	path := "/v1/workers/" + worker.ID
	f.call("POST", path+"/state", worker.Token, map[string]string{"state": "working"}, 200, "")
	f.call("POST", path+"/control/ready", worker.Token, struct{}{}, 200, "")
	f.call("POST", path+"/control", "", map[string]any{"held": true, "generation": 1}, 200, "")
	send := func(key string) WorkerFollowUp {
		var m WorkerFollowUp
		if err := json.Unmarshal(f.call("POST", path+"/messages", "", map[string]any{"text": key, "generation": 2}, 202, key), &m); err != nil {
			t.Fatal(err)
		}
		return m
	}
	first := send("first")
	cancel := path + "/messages/" + first.ID + "/cancel"
	f.call("POST", cancel, coordinator.Token, struct{}{}, 403, "")
	f.call("POST", cancel, "", struct{}{}, 200, "")
	f.call("POST", cancel, "", struct{}{}, 200, "")
	f.call("POST", path+"/messages/"+first.ID+"/claim", worker.Token, struct{}{}, 409, "")
	second := send("second")
	f.call("POST", path+"/control/finish", worker.Token, map[string]string{"state": "completed"}, 200, "")
	f.call("POST", path+"/messages/"+second.ID+"/claim", worker.Token, struct{}{}, 200, "")
	f.call("POST", path+"/messages/"+second.ID+"/cancel", "", struct{}{}, 409, "")
}

func TestJobDetailUpdatesClearOpenCallAndKeepExitSummary(t *testing.T) {
	var store toolDetailStore
	dir := t.TempDir()
	if err := store.open(dir); err != nil {
		t.Fatal(err)
	}
	for i, step := range []struct{ state, name, arg, summary string }{
		{"running", "Read", strings.Repeat("x", 520), ""},
		{"running", "", "", ""},
		{"completed", "", "", "exit summary"},
		{"completed", "", "", ""},
	} {
		d := ToolDetail{Key: "job-t", Kind: "job", Result: step.summary,
			JobDetail: &JobDetail{ToolUseID: "t", JobKind: "agent", State: step.state, OpenToolName: step.name, OpenToolArg: step.arg}}
		store.add("worker", store.prepare([]ToolDetail{d}, nil, 0, i+1))
		got := store.log("worker").records[d.Key]
		if got == nil || got.Sequence != 1 || got.State != step.state || got.OpenToolName != step.name || got.OpenToolArg != cutText(step.arg, toolDetailSummary) {
			t.Fatalf("snapshot %d: %+v", i, got)
		}
	}
	var reopened toolDetailStore
	if err := reopened.open(dir); err != nil {
		t.Fatal(err)
	}
	got := reopened.log("worker").records["job-t"]
	if got == nil || got.State != "completed" || got.OpenToolName != "" || got.Result != "exit summary" {
		t.Fatalf("reopened record: %+v", got)
	}
}

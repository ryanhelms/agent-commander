package service

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type detailList struct {
	Revision uint64                  `json:"revision"`
	Records  []toolDetailSummaryView `json:"records"`
}

func TestToolDetailsReachOnlyTheLocalOwner(t *testing.T) {
	f := newFixture(t)
	coordinator := f.run()
	worker := f.delegate(coordinator, "detailed")
	path := "/v1/workers/" + worker.ID
	const secret = "MARKER-only-in-details"
	zero := 0
	long := strings.Repeat("x", 600)
	f.call("POST", path+"/output", worker.Token, map[string]any{
		"stream_id": "s", "batch": 1, "text": "",
		"events": []ConsoleEvent{{Kind: "tool_call", ToolID: "t1", Name: "Bash", Text: "preview"}},
		"details": []ToolDetail{{Kind: "tool", Key: "t1", Event: &zero, Name: "Bash",
			Input:     `{"command":"echo ` + secret + `","description":"Say it","long":"` + long + `","n":{"a":1}}`,
			StartedAt: "2026-01-02T03:04:05Z"}},
	}, 200, "")
	f.call("POST", path+"/output", worker.Token, map[string]any{
		"stream_id": "s", "batch": 2, "text": "",
		"details": []ToolDetail{{Kind: "tool", Key: "t1", Result: secret + " result", EndedAt: "2026-01-02T03:04:07Z"}},
	}, 200, "")

	var list detailList
	if err := json.Unmarshal(f.call("GET", path+"/tool-details", "", nil, 200, ""), &list); err != nil || len(list.Records) != 1 {
		t.Fatalf("list: %+v, %v", list, err)
	}
	got := list.Records[0]
	if got.Sequence != 1 || got.Input != "" || got.Result != "" || got.ResultBytes == 0 ||
		got.StartedAt != "2026-01-02T03:04:05Z" || got.EndedAt != "2026-01-02T03:04:07Z" ||
		string(got.Fields) != `{"command":"echo `+secret+`","description":"Say it"}` {
		t.Fatalf("summary: %+v %s", got, got.Fields)
	}
	var full ToolDetail
	if err := json.Unmarshal(f.call("GET", path+"/tool-details?key=t1", "", nil, 200, ""), &full); err != nil ||
		!strings.Contains(full.Input, long) || !strings.Contains(full.Result, secret) {
		t.Fatalf("full record: %v", err)
	}

	// Nothing outside the owner's details routes carries the values.
	f.call("GET", path+"/tool-details", worker.Token, nil, 403, "")
	f.call("GET", path+"/tool-details", coordinator.Token, nil, 403, "")
	for _, shared := range []string{"/v1/runs", "/v1/runs/" + worker.RunID, "/v1/runs/" + worker.RunID + "?view=ag-ui", "/v1/ag-ui" + strings.TrimPrefix(path, "/v1")} {
		if body := f.call("GET", shared, "", nil, 200, ""); strings.Contains(string(body), secret) || strings.Contains(string(body), "started_at") {
			t.Fatalf("%s carries tool details", shared)
		}
	}

	// A restarted service reads the same record.
	restarted, err := New(f.dir, f.p)
	if err != nil {
		t.Fatal(err)
	}
	f.api = restarted
	if err := json.Unmarshal(f.call("GET", path+"/tool-details?key=t1", "", nil, 200, ""), &full); err != nil || !strings.Contains(full.Result, secret) {
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

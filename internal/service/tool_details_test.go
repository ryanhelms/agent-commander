package service

import (
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"agentcommander/internal/acpprocessor"
	"agentcommander/internal/hosted"
)

type detailList struct {
	Revision uint64                  `json:"revision"`
	Records  []toolDetailSummaryView `json:"records"`
}

func TestIdentifiedPlanDetailsBindToTheLiveBatchEvent(t *testing.T) {
	identity := strings.Repeat("a1", 32)
	events := []ConsoleEvent{
		{Sequence: 7, Kind: "output", Text: "Earlier output unavailable"},
		{Sequence: 8, Kind: "output", ACP: &acpprocessor.Activity{
			Source: "live", Kind: "plan_update", Cursor: "current", TurnID: "turn-2", PlanIdentity: identity,
		}},
		{Sequence: 9, Kind: "output", ACP: &acpprocessor.Activity{
			Source: "provider", Kind: "plan_update", Cursor: "historical", TurnID: "turn-1", PlanIdentity: identity,
		}},
		{Sequence: 10, Kind: "output", ACP: &acpprocessor.Activity{
			Source: "live", Kind: "plan", Cursor: "legacy", TurnID: "turn-2",
		}},
	}
	store := toolDetailStore{}
	live, history, legacy, invalid := 0, 1, 2, math.MaxInt
	entries := json.RawMessage(`[{"content":"Current work","status":"pending"}]`)
	supplied := &PlanEvent{Cursor: "untrusted", PlanIdentity: identity, TurnID: "old-turn"}
	records := store.prepare([]ToolDetail{
		{Kind: "plan", Event: &live, Plan: entries, PlanEvent: supplied},
		{Kind: "plan", Event: &history, Plan: entries, PlanEvent: supplied},
		{Kind: "plan", Event: &legacy, Plan: entries, PlanEvent: supplied},
		{Kind: "plan", Event: &invalid, Plan: entries, PlanEvent: supplied},
		{Kind: "plan", Plan: entries, PlanEvent: supplied},
	}, events, 1, 10)
	want := &PlanEvent{Cursor: "current", PlanIdentity: identity, TurnID: "turn-2"}
	if len(records) != 5 || !reflect.DeepEqual(records[0].PlanEvent, want) ||
		records[0].Key != "event-8" || records[0].Sequence != 8 || !reflect.DeepEqual(records[0].Plan, entries) {
		t.Fatalf("real live batch event did not bind its snapshot: %+v", records)
	}
	for _, record := range records[1:] {
		if record.PlanEvent != nil {
			t.Fatalf("unbound summary gained a claim: %+v", record)
		}
	}
	// A sequence reused after restart must never transfer the old items into
	// a new claim, or the old claim into a later legacy record.
	current := records[0]
	older := ToolDetail{Kind: "plan", Key: current.Key, Sequence: current.Sequence, Plan: entries, PlanEvent: supplied}
	current.Plan = nil
	if replaced := mergeToolDetail(older, current); replaced.Plan != nil || !reflect.DeepEqual(replaced.PlanEvent, want) {
		t.Fatalf("older items survived into a new claim: %+v", replaced)
	}
	current.Plan = entries
	older.Plan, older.PlanEvent = nil, nil
	if replaced := mergeToolDetail(current, older); replaced.Plan != nil || replaced.PlanEvent != nil {
		t.Fatalf("an identified snapshot survived into an unrelated record: %+v", replaced)
	}
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

func TestToolDetailsKeepLocationsScopedAndClearOldTargets(t *testing.T) {
	f := newFixture(t)
	coordinator := f.run()
	first := f.delegate(coordinator, "first")
	second := f.delegate(coordinator, "second")
	firstPath := "/v1/workers/" + first.ID
	secondPath := "/v1/workers/" + second.ID
	firstLocation := ToolLocation{Path: "/private/tmp/first/location-only-in-details.txt", Line: 7}
	secondLocation := ToolLocation{Path: "/private/tmp/second/location-only-in-details.txt", Line: 13}
	send := func(path, token string, location *ToolLocation) {
		f.call("POST", path+"/output", token, map[string]any{
			"events":  []ConsoleEvent{{Kind: "tool_result", ToolID: "same-id", Name: "Read", Text: "preview"}},
			"details": []ToolDetail{{Kind: "tool", Key: "same-id", Result: "file text", Location: location}},
		}, 200, "")
	}
	readLocation := func(path, query string) *ToolLocation {
		t.Helper()
		body := f.call("GET", path+"/tool-details"+query, "", nil, 200, "")
		if query == "" {
			var list detailList
			if err := json.Unmarshal(body, &list); err != nil || len(list.Records) != 1 {
				t.Fatalf("summary: %+v, %v", list, err)
			}
			return list.Records[0].Location
		}
		var detail ToolDetail
		if err := json.Unmarshal(body, &detail); err != nil || detail.Key != "same-id" {
			t.Fatalf("detail: %+v, %v", detail, err)
		}
		return detail.Location
	}
	send(firstPath, first.Token, &firstLocation)
	send(secondPath, second.Token, &secondLocation)
	send(firstPath, first.Token, nil)
	if got := readLocation(firstPath, ""); !reflect.DeepEqual(got, &firstLocation) {
		t.Fatalf("summary lost the first location: %+v", got)
	}
	if got := readLocation(secondPath, "?key=same-id"); !reflect.DeepEqual(got, &secondLocation) {
		t.Fatalf("equal call ID borrowed a different worker's location: %+v", got)
	}
	for _, shared := range []string{"/v1/runs", "/v1/runs/" + first.RunID + "?view=ag-ui"} {
		if body := f.call("GET", shared, "", nil, 200, ""); strings.Contains(string(body), "location-only-in-details") {
			t.Fatalf("%s carries the private location", shared)
		}
	}
	f.call("GET", firstPath+"/tool-details?key=same-id", first.Token, nil, 403, "")

	for _, invalid := range []ToolLocation{
		{}, {Path: "relative", Line: 7}, {Path: "/a", Line: -1}, {Path: "/a", Line: 1 << 32},
		{Path: "/a\nline", Line: 7}, {Path: "/" + strings.Repeat("a", 4096), Line: 7},
	} {
		send(firstPath, first.Token, &invalid)
		if got := readLocation(firstPath, ""); got != nil {
			t.Fatalf("invalid update retained a location: %+v", got)
		}
		send(firstPath, first.Token, &firstLocation)
	}
	send(firstPath, first.Token, &ToolLocation{})
	restarted, err := New(f.dir, f.p)
	if err != nil {
		t.Fatal(err)
	}
	f.api = restarted
	if got := readLocation(firstPath, "?key=same-id"); got != nil {
		t.Fatalf("restart restored the cleared location: %+v", got)
	}
	if got := readLocation(secondPath, "?key=same-id"); !reflect.DeepEqual(got, &secondLocation) {
		t.Fatalf("restart lost the unaffected location: %+v", got)
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

// pointed follows a JSON Pointer the service recorded into the stored text.
func pointed(t *testing.T, stored, pointer string) any {
	t.Helper()
	var at any
	if err := json.Unmarshal([]byte(stored), &at); err != nil {
		t.Fatalf("stored value is not JSON: %v", err)
	}
	if pointer == "" {
		return at
	}
	for _, step := range strings.Split(pointer[1:], "/") {
		step = strings.NewReplacer("~1", "/", "~0", "~").Replace(step)
		switch value := at.(type) {
		case map[string]any:
			at = value[step]
		case []any:
			index, err := strconv.Atoi(step)
			if err != nil || index >= len(value) {
				t.Fatalf("pointer %q leaves the list at %q", pointer, step)
			}
			at = value[index]
		default:
			t.Fatalf("pointer %q passes a scalar at %q", pointer, step)
		}
	}
	return at
}

func limitedStore(t *testing.T, limit int) *toolDetailStore {
	t.Helper()
	store := &toolDetailStore{}
	if err := store.open(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	store.settings.LimitBytes = limit
	return store
}

func TestShortenedPathsNameExactlyTheCutStrings(t *testing.T) {
	store := limitedStore(t, 1024)
	long := func(prefix string) string { return prefix + strings.Repeat("a", 4000) }
	literal := "the provider wrote " + shortenedMark
	payload := `{"complete_field":"INTACT","literal":"` + literal + `","rows":[` +
		`{"name":"alpha","note":"` + literal + `","count":1},` +
		`{"name":"bravo","note":"` + long("ROW_ONE_") + `","count":2}],` +
		`"a/b~c":{"deep":["x","` + long("DEEP_") + `"]},` +
		`"cut_field":"` + long("VISIBLE_") + `","later_field":"UNRECEIVED"}`
	prepared := store.prepare([]ToolDetail{{Kind: "tool", Key: "t", Result: payload,
		Shortened: map[string][]string{"result": {"/complete_field"}, "input": {""}}}}, nil, 0, 1)
	if len(prepared) != 1 {
		t.Fatalf("prepared: %+v", prepared)
	}
	got := prepared[0]
	want := []string{"/rows/1/note", "/a~1b~0c/deep/1", "/cut_field"}
	if !reflect.DeepEqual(got.Truncated, []string{"result"}) || !reflect.DeepEqual(got.Shortened, map[string][]string{"result": want}) {
		t.Fatalf("paths: %v %v", got.Truncated, got.Shortened)
	}
	// Each path leads to its own cut string: the row's, never its neighbour's.
	for pointer, prefix := range map[string]string{"/rows/1/note": "ROW_ONE_", "/a~1b~0c/deep/1": "DEEP_", "/cut_field": "VISIBLE_"} {
		text, _ := pointed(t, got.Result, pointer).(string)
		if !strings.HasPrefix(text, prefix) || !strings.HasSuffix(text, shortenedMark) || len(text) != 1024+len(shortenedMark) {
			t.Fatalf("%s: %.40s… (%d bytes)", pointer, text, len(text))
		}
	}
	// A value that only ends in the mark's text is kept whole and not listed.
	for _, pointer := range []string{"/literal", "/rows/0/note"} {
		if text := pointed(t, got.Result, pointer); text != literal {
			t.Fatalf("%s: %v", pointer, text)
		}
	}
	// Everything else keeps its value, type and order.
	cut := strings.Repeat("a", 4000)
	kept := strings.Repeat("a", 1024)
	shape := strings.NewReplacer("ROW_ONE_"+cut, "ROW_ONE_"+kept[:1016]+shortenedMark, "DEEP_"+cut, "DEEP_"+kept[:1019]+shortenedMark,
		"VISIBLE_"+cut, "VISIBLE_"+kept[:1016]+shortenedMark).Replace(payload)
	if got.Result != shape {
		t.Fatalf("shape changed: %.120s…", got.Result)
	}

	// The list of summaries carries no paths; the full record does, after a restart too.
	store.add("worker", prepared)
	var reopened toolDetailStore
	if err := reopened.open(filepath.Dir(store.dir)); err != nil {
		t.Fatal(err)
	}
	if record := reopened.log("worker").records["t"]; record == nil || !reflect.DeepEqual(record.Shortened, got.Shortened) {
		t.Fatalf("reopened: %+v", record)
	}
}

func TestShortenedPathsOmitAmbiguousDuplicateKeys(t *testing.T) {
	store := limitedStore(t, 1024)
	literal := "provider text " + shortenedMark
	long := strings.Repeat("x", 1500)
	payload := `{"rows":[{"name":"` + literal + `","name":"` + long + `"}],"later":"intact"}`
	want := strings.Replace(payload, long, long[:1024]+shortenedMark, 1)
	got := store.prepare([]ToolDetail{{Kind: "tool", Key: "t", Result: payload}}, nil, 0, 1)[0]
	if !reflect.DeepEqual(got.Truncated, []string{"result"}) || got.Shortened != nil {
		t.Fatalf("duplicate key provenance: %v %v", got.Truncated, got.Shortened)
	}
	if got.Result != want {
		t.Fatal("duplicate key result changed beyond its shortened value")
	}
}

func TestShortenedPathsMarkAWholeValueCut(t *testing.T) {
	store := limitedStore(t, 1024)
	whole := map[string][]string{"result": {""}}
	for name, value := range map[string]string{
		"plain text":      strings.Repeat("line of output\n", 200),
		"incomplete JSON": `{"rows":[{"name":"` + strings.Repeat("x", 3000),
		"a JSON string":   `"` + strings.Repeat("x", 3000) + `"`,
	} {
		got := store.prepare([]ToolDetail{{Kind: "tool", Key: "t", Result: value}}, nil, 0, 1)[0]
		if !reflect.DeepEqual(got.Shortened, whole) || !strings.HasSuffix(got.Result, shortenedMark) || len(got.Result) != 1024+len(shortenedMark) {
			t.Fatalf("%s: %v, %d bytes", name, got.Shortened, len(got.Result))
		}
	}
	// The hard cap cuts the end of the value, structured or not, whatever the setting.
	for _, limit := range []int{0, MaxToolDetailField} {
		store.settings.LimitBytes = limit
		rows := `{"rows":["` + strings.Repeat(strings.Repeat("r", 600)+`","`, 2*MaxToolDetailField/600) + `end"]}`
		got := store.prepare([]ToolDetail{{Kind: "tool", Key: "t", Result: rows}}, nil, 0, 1)[0]
		if !reflect.DeepEqual(got.Shortened, whole) || !reflect.DeepEqual(got.Truncated, []string{"result"}) ||
			len(got.Result) != MaxToolDetailField+len(shortenedMark) || json.Valid([]byte(got.Result)) {
			t.Fatalf("limit %d: %v %v, %d bytes", limit, got.Shortened, got.Truncated, len(got.Result))
		}
	}
	// A value under the limit is neither listed nor pointed at, even ending in the mark.
	store.settings.LimitBytes = 1024
	got := store.prepare([]ToolDetail{{Kind: "tool", Key: "t", Result: "said " + shortenedMark}}, nil, 0, 1)[0]
	if got.Truncated != nil || got.Shortened != nil || got.Result != "said "+shortenedMark {
		t.Fatalf("literal mark: %+v", got)
	}
}

func TestShortenedPathsStayBounded(t *testing.T) {
	store := limitedStore(t, 1024)
	list := func(count int) string {
		return `{"items":["` + strings.Repeat(strings.Repeat("v", 1100)+`","`, count-1) + strings.Repeat("v", 1100) + `"]}`
	}
	atCap := store.prepare([]ToolDetail{{Kind: "tool", Key: "t", Result: list(maxShortenedPaths)}}, nil, 0, 1)[0]
	if len(atCap.Shortened["result"]) != maxShortenedPaths || atCap.Shortened["result"][maxShortenedPaths-1] != "/items/"+strconv.Itoa(maxShortenedPaths-1) {
		t.Fatalf("at the cap: %d paths", len(atCap.Shortened["result"]))
	}
	// One more cut than the bound keeps no path at all: the value is still listed as cut.
	past := store.prepare([]ToolDetail{{Kind: "tool", Key: "t", Result: list(maxShortenedPaths + 1)}}, nil, 0, 1)[0]
	if past.Shortened != nil || !reflect.DeepEqual(past.Truncated, []string{"result"}) || !json.Valid([]byte(past.Result)) {
		t.Fatalf("past the cap: %v %v", past.Shortened, past.Truncated)
	}
	// Long keys pass the byte bound before the count.
	key := strings.Repeat("k", maxShortenedPathBytes)
	wide := store.prepare([]ToolDetail{{Kind: "tool", Key: "t", Result: `{"` + key + `":"` + strings.Repeat("v", 1100) + `"}`}}, nil, 0, 1)[0]
	if wide.Shortened != nil || !reflect.DeepEqual(wide.Truncated, []string{"result"}) {
		t.Fatalf("wide key: %d path bytes kept", len(wide.Shortened["result"]))
	}
	if size := (&atCap).Size(); size < len(atCap.Result)+maxShortenedPaths*len("/items/0") {
		t.Fatalf("size %d leaves the paths out", size)
	}
}

func TestShortenedPathsFollowTheValueTheyDescribe(t *testing.T) {
	store := limitedStore(t, 1024)
	long := strings.Repeat("z", 3000)
	put := func(detail ToolDetail) *ToolDetail {
		detail.Kind, detail.Key = "tool", "t"
		store.add("worker", store.prepare([]ToolDetail{detail}, nil, 0, 1))
		return store.log("worker").records["t"]
	}
	first := put(ToolDetail{Input: `{"prompt":"` + long + `"}`, Result: `{"a":"` + long + `","b":"ok"}`})
	want := map[string][]string{"input": {"/prompt"}, "result": {"/a"}}
	if !reflect.DeepEqual(first.Shortened, want) {
		t.Fatalf("first: %v", first.Shortened)
	}
	// An update without the value leaves its paths alone.
	if kept := put(ToolDetail{Title: "renamed"}); !reflect.DeepEqual(kept.Shortened, want) || !reflect.DeepEqual(first.Shortened, want) {
		t.Fatalf("kept: %v, earlier copy: %v", kept.Shortened, first.Shortened)
	}
	// A new result cut elsewhere replaces the result's paths only.
	moved := put(ToolDetail{Result: `{"a":"ok","b":"` + long + `"}`})
	if !reflect.DeepEqual(moved.Shortened, map[string][]string{"input": {"/prompt"}, "result": {"/b"}}) {
		t.Fatalf("moved: %v", moved.Shortened)
	}
	// A whole result clears its paths and its listing; the input's stay.
	whole := put(ToolDetail{Result: `{"a":"ok","b":"ok"}`})
	if !reflect.DeepEqual(whole.Shortened, map[string][]string{"input": {"/prompt"}}) || !reflect.DeepEqual(whole.Truncated, []string{"input"}) {
		t.Fatalf("whole: %v %v", whole.Shortened, whole.Truncated)
	}
	// A runner's own cut is listed without paths, and drops the stale ones.
	runner := put(ToolDetail{Input: `{"prompt":"short"}`, Truncated: []string{"input"}, Shortened: map[string][]string{"input": {"/prompt"}}})
	if runner.Shortened != nil || !reflect.DeepEqual(runner.Truncated, []string{"input"}) {
		t.Fatalf("runner cut: %v %v", runner.Shortened, runner.Truncated)
	}
}

func TestToolDetailSummariesCarryNoShortenedPaths(t *testing.T) {
	f := newFixture(t)
	worker := f.delegate(f.run(), "paths")
	path := "/v1/workers/" + worker.ID
	f.call("POST", "/v1/settings/transcript", "", map[string]any{"limit_bytes": 1024}, 200, "")
	f.call("POST", path+"/output", worker.Token, map[string]any{"stream_id": "s", "batch": 1, "text": "",
		"details": []ToolDetail{{Kind: "tool", Key: "t", Result: `{"rows":[{"name":"alpha"}],"cut_field":"` + strings.Repeat("a", 4000) + `","later_field":"kept"}`}}}, 200, "")
	if list := string(f.call("GET", path+"/tool-details", "", nil, 200, "")); strings.Contains(list, "shortened") || !strings.Contains(list, `"truncated":["result"]`) {
		t.Fatalf("summaries: %s", list)
	}
	var full ToolDetail
	if err := json.Unmarshal(f.call("GET", path+"/tool-details?key=t", "", nil, 200, ""), &full); err != nil ||
		!reflect.DeepEqual(full.Shortened, map[string][]string{"result": {"/cut_field"}}) {
		t.Fatalf("full record: %v %v", full.Shortened, err)
	}
}

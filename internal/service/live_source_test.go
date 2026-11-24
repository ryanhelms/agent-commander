package service

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	model "agent-acp.local/sdks/go/model"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

func TestLiveSourceObservationKeepsOriginalAndChecksEnvelope(t *testing.T) {
	f := newFixture(t)
	w := f.run()
	path := "/v1/workers/" + w.ID
	ref := NativeSession{HarnessInstance: "fixture", SessionID: "selected"}
	f.call("POST", path+"/native-session", "", ref, 200, "")
	obs := &model.Observation{
		Session: &model.SessionRef{HarnessInstance: ref.HarnessInstance, SessionId: ref.SessionID},
		Cursor:  "c1", TurnId: "turn", SourceCursor: proto.String("c1"),
		Event:        &model.Observation_TurnEnded{TurnEnded: &model.TurnEnded{Reason: "end_turn"}},
		SourceRecord: &model.Extension{Type: "acp.prompt_result", MediaType: "application/json", Data: []byte(`{"stopReason":"end_turn","_meta":{"meter":9007199254740993}}`)},
	}
	update := LiveSourceUpdate{Session: ref, Cursor: obs.Cursor, TurnID: obs.TurnId, Kind: LiveSourcedObservationKind}
	post := func(status int) {
		t.Helper()
		var err error
		update.Observation, err = protojson.Marshal(obs)
		if err != nil {
			t.Fatal(err)
		}
		f.call("POST", path+"/live-source", w.Token, update, status, "")
	}
	post(200)
	post(200)
	obs.Session.SessionId = "another-session"
	post(400)
	obs.Session.SessionId = ref.SessionID
	obs.TurnId = "another-turn"
	post(400)
	obs.TurnId, obs.Cursor = update.TurnID, "another-cursor"
	post(400)
	var page model.ReadHistoryResponse
	body := f.call("GET", path+"/history?source=live&turnId=turn", "", nil, 200, "")
	if protojson.Unmarshal(body, &page) != nil || len(page.Observations) != 1 {
		t.Fatal("lost or duplicated a sourced observation")
	}
	got := page.Observations[0]
	if got.Cursor != update.Cursor || got.GetSourceCursor() != got.Cursor || got.GetTurnEnded().GetReason() != "end_turn" ||
		!bytes.Equal(got.GetSourceRecord().GetData(), obs.SourceRecord.Data) {
		t.Fatal("restored a different operation or changed the original JSON")
	}
}

func TestLiveACPSourceIsScopedAndOutsideWorkspace(t *testing.T) {
	f := newFixture(t)
	parent := f.run()
	worker := f.delegate(parent, "source-worker")
	path := "/v1/workers/" + worker.ID
	ref := NativeSession{HarnessInstance: "local-claude", SessionID: "source-session"}
	f.call("POST", path+"/native-session", "", ref, 200, "")
	body := LiveSourceUpdate{Session: ref, Cursor: "source-1", TurnID: "turn",
		Body: []byte(`{"sessionUpdate":"tool_call","rawInput":{"value":"held-only-in-source"}}`)}
	f.call("POST", path+"/live-source", parent.Token, body, 403, "")
	f.call("POST", path+"/live-source", "", body, 403, "")
	cross := body
	cross.Session.SessionID = "another-session"
	f.call("POST", path+"/live-source", worker.Token, cross, 409, "")
	f.call("POST", path+"/live-source", worker.Token, body, 200, "")
	f.call("POST", path+"/live-source", worker.Token, body, 200, "")
	body.Cursor = "source-2"
	f.call("POST", path+"/live-source", worker.Token, body, 200, "")
	pageURL := path + "/history?source=live&limit=1"
	f.call("GET", pageURL, worker.Token, nil, 403, "")
	var page model.ReadHistoryResponse
	if err := protojson.Unmarshal(f.call("GET", pageURL, "", nil, 200, ""), &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Observations) != 1 || page.GetNextCursor() == "" ||
		page.Observations[0].GetCursor() != "source-1" || string(page.Observations[0].GetExtension().GetData()) != string(body.Body) {
		t.Fatal("the first source update lost data or paging identity")
	}
	pathOther := "/v1/workers/" + parent.ID
	f.call("POST", pathOther+"/native-session", "", cross.Session, 200, "")
	f.call("GET", pathOther+"/history?source=live&cursor="+page.GetNextCursor(), "", nil, 400, "")
	cursor := page.GetNextCursor()
	if err := protojson.Unmarshal(f.call("GET", pageURL+"&cursor="+cursor, "", nil, 200, ""), &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Observations) != 1 || page.Observations[0].GetCursor() != "source-2" || page.GetNextCursor() != "" {
		t.Fatal("retry duplicated the live source or paging skipped a record")
	}
	if projection := f.call("GET", "/v1/runs/"+parent.RunID, "", nil, 200, ""); strings.Contains(string(projection), "held-only-in-source") {
		t.Fatal("live source entered the shared run projection")
	}
	state, err := os.ReadFile(filepath.Join(f.dir, "state.json"))
	if err != nil || strings.Contains(string(state), "held-only-in-source") {
		t.Fatal("live source entered the persisted state", err)
	}
}

func TestLiveACPSourcePageMarksExpiredPrefix(t *testing.T) {
	var store liveSourceStore
	ref := NativeSession{HarnessInstance: "fixture", SessionID: "fixture"}
	for i := range LiveSourceWindowRecords + 2 {
		store.append("worker", LiveSourceUpdate{Session: ref, Cursor: fmt.Sprint(i), Body: []byte("{}")})
	}
	first, err := store.page("worker", ref, "", "", "", 1)
	if err != nil || len(first.Observations) != 1 || first.Observations[0].GetGap() == nil || first.GetNextCursor() == "" {
		t.Fatal("evicted live records were not marked as a gap", first, err)
	}
	next, err := store.page("worker", ref, "", "", first.GetNextCursor(), 1)
	if err != nil || len(next.Observations) != 1 || next.Observations[0].GetCursor() != "2" {
		t.Fatal("could not recover the first retained record after the gap", next, err)
	}
}

func TestLiveSourceReaderKeepsTwoOverlappingBursts(t *testing.T) {
	var store liveSourceStore
	ref := NativeSession{HarnessInstance: "fixture", SessionID: "selected"}
	store.append("worker", LiveSourceUpdate{Session: ref, Cursor: "anchor", Body: []byte("{}")})
	const burst = 67
	var wanted []string
	var cursor string
	for i := range burst {
		for _, turn := range []string{"first", "second"} {
			id := fmt.Sprintf("%s-%d", turn, i)
			update := LiveSourceUpdate{Session: ref, TurnID: turn, Cursor: id, Body: []byte(fmt.Sprintf(`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":%q}}`, id))}
			store.append("worker", update)
			store.append("worker", update) // The runner may retry an entire source batch.
			wanted = append(wanted, id)
			if len(wanted) == 1 {
				page, err := store.page("worker", ref, "", "", "", 1)
				if err != nil || len(page.GetObservations()) != 1 || page.Observations[0].Cursor != "anchor" || page.GetNextCursor() == "" {
					t.Fatalf("reader did not obtain an initial continuation: %v %v", page, err)
				}
				cursor = page.NextCursor
			}
		}
	}
	var read int
	for cursor != "" {
		page, err := store.page("worker", ref, "", "", cursor, 16)
		if err != nil || len(page.GetObservations()) == 0 {
			t.Fatalf("read after %d records: %v %v", read, page, err)
		}
		for _, obs := range page.Observations {
			if read >= len(wanted) || obs.GetGap() != nil || obs.Cursor != wanted[read] || !bytes.Contains(obs.GetExtension().GetData(), []byte(fmt.Sprintf(`"text":%q`, wanted[read]))) {
				t.Fatalf("unexpected record at offset %d: %v", read, obs)
			}
			read++
		}
		cursor = page.NextCursor
	}
	if read != len(wanted) {
		t.Fatalf("read %d of %d originals", read, len(wanted))
	}
}

func TestLiveSourceCursorIndexExpiresWithRecords(t *testing.T) {
	var store liveSourceStore
	put := func(worker, cursor string, body []byte) {
		store.append(worker, LiveSourceUpdate{Session: NativeSession{HarnessInstance: "fixture", SessionID: worker}, Cursor: cursor, Body: body})
	}
	for i := range LiveSourceWindowRecords + 1 {
		put("one", fmt.Sprint(i), nil)
	}
	w := store.windows["one"]
	if _, present := w.cursors["0"]; present || len(w.cursors) != LiveSourceWindowRecords {
		t.Fatal("count eviction left stale cursor entries")
	}
	put("one", "0", []byte("replayed"))
	put("one", "0", []byte("duplicate"))
	put("two", "0", []byte("independent"))
	if w.removed != 2 || string(w.records[len(w.records)-1].Body) != "replayed" || string(store.windows["two"].records[0].Body) != "independent" {
		t.Fatal("retry or cross-worker cursor changed the wrong record")
	}
	body := make([]byte, MaxLiveSourceRecord)
	for i := range 8 {
		put("one", fmt.Sprintf("large-%d", i), body)
	}
	if _, present := w.cursors["0"]; present || len(w.cursors) != len(w.records) || w.bytes > LiveSourceWindowBytes {
		t.Fatal("byte eviction left stale cursor entries")
	}
	for i := range 9 {
		for j := range 5 {
			put(fmt.Sprintf("worker-%d", i), fmt.Sprint(j), body)
		}
	}
	if _, present := store.windows["one"]; present || store.bytes > liveSourceTotalBytes {
		t.Fatal("global pressure retained an evicted worker window")
	}
	put("one", "0", []byte("new window"))
	if len(store.windows["one"].cursors) != 1 || store.windows["one"].removed != 0 {
		t.Fatal("new worker window inherited discarded cursor entries")
	}
}

func TestACPHistoryViewPreservesUnknownMemberAndScope(t *testing.T) {
	f := newFixture(t)
	w := f.run()
	path := "/v1/workers/" + w.ID
	ref := NativeSession{HarnessInstance: "fixture", SessionID: "source"}
	f.call("POST", path+"/native-session", "", ref, 200, "")
	f.call("POST", path+"/live-source", w.Token, LiveSourceUpdate{
		Session: ref, Cursor: "rich-record", TurnID: "turn-one",
		Body: []byte(`{"sessionUpdate":"current_mode_update","currentModeId":"plan","extra":{"revision":9007199254740993}}`),
	}, 200, "")
	url := path + "/history?source=live&view=acp&turnId=turn-one"
	got := f.call("GET", url, "", nil, 200, "")
	for _, field := range []string{`"disposition":"decoded"`, `"cursor":"rich-record"`, `"revision":9007199254740993`} {
		if !strings.Contains(string(got), field) {
			t.Fatalf("missing %s in %s", field, got)
		}
	}
	f.call("GET", url, w.Token, nil, 403, "")
	f.call("GET", path+"/history?view=acp&source=journal", "", nil, 400, "")
}

func TestLiveACPSourcePagesOnlyTheSelectedTurn(t *testing.T) {
	f := newFixture(t)
	worker := f.delegate(f.run(), "source-worker")
	path := "/v1/workers/" + worker.ID
	ref := NativeSession{HarnessInstance: "fixture", SessionID: "turn-history"}
	f.call("POST", path+"/native-session", "", ref, 200, "")
	for i, turn := range []string{"first", "chosen", "first", "chosen", "first"} {
		f.call("POST", path+"/live-source", worker.Token, LiveSourceUpdate{
			Session: ref, Cursor: fmt.Sprint(i), TurnID: turn,
			Body: []byte(fmt.Sprintf(`{"data":"%s-%d"}`, turn, i)),
		}, 200, "")
	}
	firstURL := path + "/history?source=live&limit=1&turnId=chosen"
	var page model.ReadHistoryResponse
	if err := protojson.Unmarshal(f.call("GET", firstURL, "", nil, 200, ""), &page); err != nil {
		t.Fatal(err)
	}
	cursor := page.GetNextCursor()
	if len(page.GetObservations()) != 1 || page.GetObservations()[0].GetCursor() != "1" || cursor == "" {
		t.Fatal("first page did not select the requested turn")
	}
	f.call("GET", path+"/history?source=live&cursor="+cursor, "", nil, 400, "")
	f.call("GET", path+"/history?source=live&turnId=first&cursor="+cursor, "", nil, 400, "")
	f.call("GET", path+"/history?source=journal&turnId=chosen", "", nil, 400, "")
	if err := protojson.Unmarshal(f.call("GET", firstURL+"&cursor="+cursor, "", nil, 200, ""), &page); err != nil {
		t.Fatal(err)
	}
	if len(page.GetObservations()) != 1 || page.GetObservations()[0].GetCursor() != "3" || page.GetNextCursor() != "" {
		t.Fatal("pagination mixed turns or offered an empty next page")
	}

	restarted, err := New(f.dir, f.p)
	if err != nil {
		t.Fatal(err)
	}
	f.api = restarted
	if err := protojson.Unmarshal(f.call("GET", firstURL+"&cursor="+cursor, "", nil, 200, ""), &page); err != nil {
		t.Fatal(err)
	}
	if len(page.GetObservations()) != 1 || page.GetObservations()[0].GetGap() == nil || page.GetNextCursor() != "" {
		t.Fatal("restart failed to mark the expired live source")
	}
}

func TestPromptAttachmentsStayInTheSelectedTurnAndSource(t *testing.T) {
	f := newFixture(t)
	worker := f.run()
	path := "/v1/workers/" + worker.ID
	ref := NativeSession{HarnessInstance: "fixture", SessionID: "mixed"}
	f.call("POST", path+"/native-session", "", ref, 200, "")
	for i, item := range []struct{ turn, kind string }{
		{"mine", ""}, {"mine", "acp.prompt_part"}, {"other", "acp.prompt_part"}, {"mine", "acp.prompt_part"}, {"mine", ""},
	} {
		f.call("POST", path+"/live-source", worker.Token, LiveSourceUpdate{
			Session: ref, Cursor: fmt.Sprint(i), TurnID: item.turn, Kind: item.kind, Body: []byte("{}"),
		}, 200, "")
	}
	all := path + "/history?source=live&turnId=mine&limit=1"
	filter := all + "&kind=acp.prompt_part"
	var page model.ReadHistoryResponse
	read := func(url string) {
		t.Helper()
		if err := protojson.Unmarshal(f.call("GET", url, "", nil, 200, ""), &page); err != nil {
			t.Fatal(err)
		}
	}
	read(filter)
	if len(page.Observations) != 1 || page.Observations[0].Cursor != "1" || page.NextCursor == "" {
		t.Fatal("did not find the first prompt attachment", &page)
	}
	cursor := "&cursor=" + page.NextCursor
	f.call("GET", all+cursor, "", nil, 400, "")
	f.call("GET", path+"/history?source=live&kind=acp.prompt_part", "", nil, 400, "")
	f.call("GET", filter, worker.Token, nil, 403, "")
	read(filter + cursor)
	if len(page.Observations) != 1 || page.Observations[0].Cursor != "3" || page.NextCursor != "" {
		t.Fatal("filtered page returned an unrelated update or attachment", &page)
	}
	read(path + "/history?source=live&turnId=unknown&kind=acp.prompt_part")
	if len(page.Observations) != 1 || page.Observations[0].GetGap() == nil {
		t.Fatal("missing attachments had no explanation")
	}
}

func TestPromptAttachmentFitsBothJSONEnvelopes(t *testing.T) {
	f := newFixture(t)
	worker := f.run()
	path := "/v1/workers/" + worker.ID
	ref := NativeSession{HarnessInstance: "fixture", SessionID: "large-image"}
	f.call("POST", path+"/native-session", "", ref, 200, "")
	part := LiveSourceUpdate{Session: ref, Cursor: "prompt-turn-0", TurnID: "turn", Kind: "acp.prompt_part",
		Body: []byte(`{"type":"image","mimeType":"image/png","data":"` + strings.Repeat("A", 980<<10) + `"}`)}
	f.call("POST", path+"/live-source", worker.Token, part, 200, "")
	var page model.ReadHistoryResponse
	raw := f.call("GET", path+"/history?source=live&turnId=turn&kind=acp.prompt_part", "", nil, 200, "")
	if err := protojson.Unmarshal(raw, &page); err != nil || len(page.Observations) != 1 ||
		string(page.Observations[0].GetExtension().GetData()) != string(part.Body) {
		t.Fatal("the admitted prompt could not be read back in full", err)
	}
	part.Kind = ""
	f.call("POST", path+"/live-source", worker.Token, part, 400, "")
}

func TestLiveSourceBatchIsAtomicScopedAndRetryable(t *testing.T) {
	f := newFixture(t)
	parent := f.run()
	w := f.delegate(parent, "source-batch")
	path := "/v1/workers/" + w.ID
	selected := NativeSession{HarnessInstance: "codex", SessionID: "selected"}
	f.call("POST", path+"/native-session", "", selected, 200, "")
	item := LiveSourceUpdate{Session: selected, Cursor: "c1", TurnID: "turn", Body: []byte(`{"text":"one"}`)}
	marker := LiveSourceUpdate{Session: selected, Cursor: "gap-2", TurnID: "turn", Gap: "Queue limit at c2"}
	batch := path + "/live-source/batch"

	f.call("POST", batch, parent.Token, []LiveSourceUpdate{item}, 403, "")
	f.call("POST", batch, "", []LiveSourceUpdate{item}, 403, "")
	cross := marker
	cross.Session.SessionID = "other"
	f.call("POST", batch, w.Token, []LiveSourceUpdate{item, cross}, 409, "")
	missingCursor := marker
	missingCursor.Cursor = ""
	f.call("POST", batch, w.Token, []LiveSourceUpdate{item, missingCursor}, 400, "")
	badObservation := item
	badObservation.Kind, badObservation.Body = LiveSourcedObservationKind, nil
	badObservation.Observation = []byte(`{"cursor":"different"}`)
	f.call("POST", batch, w.Token, []LiveSourceUpdate{item, badObservation}, 400, "")
	f.call("POST", batch, w.Token, []LiveSourceUpdate{}, 400, "")

	maximum := make([]LiveSourceUpdate, LiveSourceBatchRecords)
	for i := range maximum {
		maximum[i] = item
		maximum[i].Cursor = fmt.Sprintf("m%d", i)
	}
	f.call("POST", batch, w.Token, append(maximum, item), 400, "")
	// Each record is individually valid. The combined wire request exceeds the HTTP limit.
	large := item
	large.Body = []byte(`"` + strings.Repeat("x", 600<<10) + `"`)
	f.call("POST", batch, w.Token, []LiveSourceUpdate{large, large, large}, 400, "")

	read := func() []*model.Observation {
		t.Helper()
		var page model.ReadHistoryResponse
		if err := protojson.Unmarshal(f.call("GET", path+"/history?source=live&limit=50", "", nil, 200, ""), &page); err != nil {
			t.Fatal(err)
		}
		return page.Observations
	}
	if got := read(); len(got) != 1 || got[0].GetGap() == nil || got[0].GetCursor() != "" {
		t.Fatalf("an invalid batch created a partial history: %v", got)
	}
	f.call("POST", path+"/live-source", w.Token, item, 200, "")
	f.call("POST", batch, w.Token, []LiveSourceUpdate{item, marker, marker}, 200, "")
	f.call("POST", batch, w.Token, []LiveSourceUpdate{item, marker, marker}, 200, "")
	f.call("POST", batch, w.Token, maximum, 200, "")
	got := read()
	if len(got) != 2+len(maximum) || got[0].Cursor != item.Cursor ||
		got[1].GetGap().GetReason() != marker.Gap || got[1].Cursor != marker.Cursor || got[1].TurnId != marker.TurnID {
		t.Fatalf("retry lost or duplicated a record: %v", got)
	}
	for i, record := range maximum {
		if got[i+2].Cursor != record.Cursor {
			t.Fatalf("cursor order at %d = %q, want %q", i, got[i+2].Cursor, record.Cursor)
		}
	}
}

func TestLiveSourceRetainedSizeMatchesValidatedObservation(t *testing.T) {
	ref := NativeSession{HarnessInstance: "instance", SessionID: "selected"}
	update := LiveSourceUpdate{Session: ref, Cursor: "c1", TurnID: "turn", Kind: LiveSourcedObservationKind}
	metadata := update.RetainedSize()
	obs := &model.Observation{Session: &model.SessionRef{HarnessInstance: ref.HarnessInstance, SessionId: ref.SessionID},
		Cursor: update.Cursor, TurnId: update.TurnID, SourceCursor: proto.String(update.Cursor),
		Event: &model.Observation_Extension{Extension: &model.Extension{Type: "example", Data: []byte("native")}}}
	raw, err := protojson.Marshal(obs)
	if err != nil {
		t.Fatal(err)
	}
	update.Observation = raw
	if update.RetainedSize() != metadata+len(raw) {
		t.Fatal("pending observation was omitted from the retention charge")
	}
	if err := update.prepare(&ref); err != nil {
		t.Fatal(err)
	}
	if len(update.Observation) != 0 || update.observation == nil || update.RetainedSize() != metadata+len(raw) {
		t.Fatalf("retention changed after validating native source: charged %d, expected %d", update.RetainedSize(), metadata+len(raw))
	}
}

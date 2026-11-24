package service

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

func TestSourcedUpdateHTTPFieldsAndScope(t *testing.T) {
	f := newFixture(t)
	w := f.delegate(f.run(), "params")
	path := "/v1/workers/" + w.ID
	ref := NativeSession{HarnessInstance: "fixture", SessionID: "selected"}
	f.call("POST", path+"/native-session", "", ref, 200, "")
	originals := []string{
		`{"_meta":{"nullable":null},"sessionId":"selected","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"fixture"},"attachment":"ONE-COPY"},"future":9007199254740993}`,
		`{"sessionId":"selected","update":null,"future":false}`,
		`{"sessionId":"selected","_meta":null}`,
	}
	put := func(body, cursor string, passive bool, code int) {
		t.Helper()
		ext := &model.Extension{Type: runtime.ACPUpdateParamsSource, MediaType: "application/json", Data: []byte(body)}
		obs := &model.Observation{Session: &model.SessionRef{HarnessInstance: "fixture", SessionId: "selected"}, Cursor: cursor, SourceCursor: proto.String(cursor)}
		if passive {
			obs.Event = &model.Observation_Extension{Extension: ext}
		} else {
			obs.SourceRecord = ext
			obs.Event = &model.Observation_Text{Text: &model.TextUpdate{Speaker: model.Speaker_SPEAKER_ASSISTANT, Text: "fixture"}}
		}
		raw, err := protojson.Marshal(obs)
		if err != nil {
			t.Fatal(err)
		}
		f.call("POST", path+"/live-source", w.Token, LiveSourceUpdate{Session: ref, Cursor: cursor, Kind: LiveSourcedObservationKind, Observation: raw}, code, "")
	}
	for i, original := range originals {
		put(original, []string{"a", "b", "c"}[i], i > 0, 200)
	}
	for _, passive := range []bool{true, false} {
		put(strings.Replace(originals[0], `"selected"`, `"other"`, 1), "foreign", passive, 400)
		put(`{"sessionId":"other","sessionId":"selected","update":null}`, "ambiguous", passive, 400)
	}
	body := f.call("GET", path+"/history?source=live", "", nil, 200, "")
	var page model.ReadHistoryResponse
	if err := protojson.Unmarshal(body, &page); err != nil || len(page.Observations) != 3 {
		t.Fatal(err)
	}
	for i, o := range page.Observations {
		ext := o.GetSourceRecord()
		if ext == nil {
			ext = o.GetExtension()
		}
		if string(ext.Data) != originals[i] || o.GetSourceCursor() != o.Cursor {
			t.Fatal("default source lost exact payload or cursor")
		}
	}
	data := f.call("GET", path+"/history?view=acp&source=live", "", nil, 200, "")
	var result struct {
		Records []struct {
			Cursor, Disposition  string
			Update, ParamsFields json.RawMessage
		}
	}
	if err := json.Unmarshal(data, &result); err != nil || len(result.Records) != 3 {
		t.Fatal(err)
	}
	if result.Records[0].Disposition != "decoded" || bytes.Count(data, []byte("ONE-COPY")) != 1 || !bytes.Contains(result.Records[0].ParamsFields, []byte("9007199254740993")) || !bytes.Contains(result.Records[0].ParamsFields, []byte(`"nullable":null`)) || bytes.Contains(result.Records[0].ParamsFields, []byte(`"update"`)) {
		t.Fatal("ACP view lost outer fields or duplicated inner attachments")
	}
	if string(result.Records[1].Update) != "null" || result.Records[2].Update != nil {
		t.Fatal("confused explicit null and missing update")
	}
	f.call("GET", path+"/history?view=acp&source=live", w.Token, nil, 403, "")
}

func TestWorkerGapHTTPKeepsOriginalCursorAbsenceAndFields(t *testing.T) {
	f := newFixture(t)
	w := f.delegate(f.run(), "gap")
	path := "/v1/workers/" + w.ID
	ref := NativeSession{HarnessInstance: "fixture", SessionID: "selected"}
	f.call("POST", path+"/native-session", "", ref, 200, "")
	raw := json.RawMessage(`{"session":{"harnessInstance":"fixture","sessionId":"selected"},"gap":{"reason":"private provider reason"},"sourceCursor":"original-page","sourceRecord":{"type":"provider.gap","data":"e30="}}`)
	record := LiveSourceUpdate{Session: ref, Cursor: "gap-fixture", Kind: LiveObservationKind, Body: raw}
	f.call("POST", path+"/live-source", w.Token, record, 200, "")
	record.Body = bytes.Replace(raw, []byte("selected"), []byte("wrong"), 1)
	f.call("POST", path+"/live-source", w.Token, record, 400, "")
	data := f.call("GET", path+"/history?source=live&view=acp", "", nil, 200, "")
	var page struct {
		Records []struct {
			Cursor      string
			Observation json.RawMessage
		}
	}
	if json.Unmarshal(data, &page) != nil || len(page.Records) != 1 || page.Records[0].Cursor != "gap-fixture" {
		t.Fatal("absent source identity")
	}
	var expected, got model.Observation
	if protojson.Unmarshal(raw, &expected) != nil || protojson.Unmarshal(page.Records[0].Observation, &got) != nil || !proto.Equal(&got, &expected) {
		t.Fatal("gap report lost native fields")
	}
}

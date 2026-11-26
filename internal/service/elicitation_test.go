package service

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"

	"agent-acp.local/sdks/go/runtime"
)

func TestACPElicitationOwnerAnswersAndScopesExternalCompletion(t *testing.T) {
	f := newFixture(t)
	parent, other := f.run(), f.run()
	worker := f.delegate(parent, "elicitation-worker")
	base := "/v1/workers/" + worker.ID + "/elicitations"
	ref := NativeSession{HarnessInstance: "fixture", SessionID: "bound"}
	f.call("POST", "/v1/workers/"+worker.ID+"/native-session", "", ref, 200, "")
	f.call("GET", base, other.Token, nil, 403, "")
	begin := func(ctx context.Context, in runtime.ElicitationRequest) <-chan *httptest.ResponseRecorder {
		t.Helper()
		payload, err := json.Marshal(in)
		if err != nil {
			t.Fatal(err)
		}
		request := httptest.NewRequest("POST", base+"/await", bytes.NewReader(payload)).WithContext(ctx)
		request.Header.Set("Authorization", "Bearer "+worker.Token)
		finished := make(chan *httptest.ResponseRecorder, 1)
		go func() {
			w := httptest.NewRecorder()
			f.api.ServeHTTP(w, request)
			finished <- w
		}()
		return finished
	}
	list := func() []Elicitation {
		t.Helper()
		var rows struct{ Elicitations []Elicitation }
		if err := json.Unmarshal(f.call("GET", base, "", nil, 200, ""), &rows); err != nil {
			t.Fatal(err)
		}
		return rows.Elicitations
	}
	waitFor := func(ctx context.Context, mode string) Elicitation {
		t.Helper()
		for ctx.Err() == nil {
			for _, item := range list() {
				if item.Mode == mode && item.Status == "pending" {
					return item
				}
			}
			time.Sleep(time.Millisecond)
		}
		t.Fatal("pending provider interaction never became visible")
		return Elicitation{}
	}
	replyFrom := func(ctx context.Context, done <-chan *httptest.ResponseRecorder) runtime.ElicitationResponse {
		t.Helper()
		select {
		case w := <-done:
			var result runtime.ElicitationResponse
			if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil || w.Code != 200 {
				t.Fatalf("unexpected runner response %d: %s", w.Code, w.Body)
			}
			return result
		case <-ctx.Done():
			t.Fatal("runner did not receive a user choice")
			return runtime.ElicitationResponse{}
		}
	}
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	form := runtime.ElicitationRequest{SessionID: ref.SessionID, Mode: "form", Message: "Select a build label",
		RequestedSchema: json.RawMessage(`{"type":"object","properties":{"label":{"type":"string","minLength":2}},"required":["label"]}`)}
	formDone := begin(ctx, form)
	shown := waitFor(ctx, "form")
	route := base + "/" + shown.ID + "/reply"
	valid := runtime.ElicitationResponse{Action: "accept", Content: json.RawMessage(`{"label":"literal $HOME"}`)}
	f.call("POST", route, other.Token, valid, 403, "")
	f.call("POST", route, "", runtime.ElicitationResponse{Action: "accept", Content: json.RawMessage(`{"label":17}`)}, 400, "")
	f.call("POST", route, "", runtime.ElicitationResponse{Action: "accept", Content: json.RawMessage(`{"label":"ok","extra":true}`)}, 400, "")
	f.call("POST", route, "", valid, 200, "")
	if got := replyFrom(ctx, formDone); got.Action != "accept" || !bytes.Equal(got.Content, valid.Content) {
		t.Fatalf("form content changed: %+v", got)
	}
	if len(list()) != 0 {
		t.Fatal("resolved form data remained visible")
	}
	choiceForm := form
	choiceForm.RequestedSchema = json.RawMessage(`{"type":"object","properties":{"colors":{"type":"array","minItems":1,"items":{"anyOf":[{"const":"#ff0000","title":"Red"},{"const":"#00ff00","title":"Green"}]}}},"required":["colors"]}`)
	choiceDone := begin(ctx, choiceForm)
	shown = waitFor(ctx, "form")
	route = base + "/" + shown.ID + "/reply"
	f.call("POST", route, "", runtime.ElicitationResponse{Action: "accept", Content: json.RawMessage(`{"colors":["Blue"]}`)}, 400, "")
	selected := runtime.ElicitationResponse{Action: "accept", Content: json.RawMessage(`{"colors":["#ff0000","#00ff00"]}`)}
	f.call("POST", route, "", selected, 200, "")
	if got := replyFrom(ctx, choiceDone); got.Action != "accept" || !bytes.Equal(got.Content, selected.Content) {
		t.Fatalf("titled choices changed: %+v", got)
	}
	url := runtime.ElicitationRequest{SessionID: ref.SessionID, Mode: "url", Message: "Confirm the external destination",
		ElicitationID: "opaque-id", URL: "https://example.test/confirm?a=%24literal"}
	urlDone := begin(ctx, url)
	confirmation := waitFor(ctx, "url")
	if confirmation.URL != url.URL || confirmation.URLHost != "example.test" {
		t.Fatalf("full URL or its host is unavailable for consent: %+v", confirmation)
	}
	f.call("POST", base+"/"+confirmation.ID+"/reply", "", runtime.ElicitationResponse{Action: "accept"}, 200, "")
	if got := replyFrom(ctx, urlDone); got.Action != "accept" || len(got.Content) != 0 {
		t.Fatalf("URL consent did not remain distinct from form content: %+v", got)
	}
	f.call("POST", base+"/complete", worker.Token, map[string]string{"sessionId": ref.SessionID, "elicitationId": "wrong"}, 200, "")
	if current := list(); len(current) != 1 || current[0].Status != "accept" {
		t.Fatalf("unknown completion advanced the URL workflow: %+v", current)
	}
	f.call("POST", base+"/complete", worker.Token, map[string]string{"sessionId": ref.SessionID, "elicitationId": url.ElicitationID}, 200, "")
	if current := list(); len(current) != 1 || current[0].Status != "completed" {
		t.Fatalf("addressed completion was lost: %+v", current)
	}
	cancelCtx, stop := context.WithCancel(ctx)
	cancelDone := begin(cancelCtx, form)
	cancelled := waitFor(ctx, "form")
	stop()
	if got := replyFrom(ctx, cancelDone); got.Action != "cancel" {
		t.Fatalf("withdrawn provider interaction remained active: %+v", got)
	}
	f.call("POST", base+"/"+cancelled.ID+"/reply", "", valid, 404, "")

	stoppedDone := begin(ctx, form)
	stopped := waitFor(ctx, "form")
	f.call("POST", "/v1/workers/"+worker.ID+"/stop", "", map[string]any{}, 202, "")
	if got := replyFrom(ctx, stoppedDone); got.Action != "cancel" {
		t.Fatalf("worker stop left an elicitation pending: %+v", got)
	}
	f.call("POST", base+"/"+stopped.ID+"/reply", "", valid, 404, "")
}

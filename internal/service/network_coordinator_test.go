package service

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestNetworkCoordinatorAttestsLiveScopedActor(t *testing.T) {
	f := newFixture(t)
	c := f.run()
	peer := f.delegate(c, "other")
	second := f.run()
	prove := func(token, run, worker string, dup bool) int {
		req := httptest.NewRequest(http.MethodGet, "/v1/network/coordinator", nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		req.Header.Set("X-Commander-Run", run)
		req.Header.Set("X-Commander-Worker", worker)
		if dup {
			req.Header.Add("X-Commander-Run", run)
		}
		w := httptest.NewRecorder()
		f.api.ServeHTTP(w, req)
		if w.Code == 200 {
			var got map[string]string
			if json.Unmarshal(w.Body.Bytes(), &got) != nil || len(got) != 2 || got["run"] != run || got["worker"] != worker {
				t.Fatalf("misbound proof: %s", w.Body.String())
			}
		}
		return w.Code
	}
	if code := prove(c.Token, c.RunID, c.ID, false); code != 200 {
		t.Fatal(code)
	}
	for _, test := range []struct {
		token, run, worker string
		dup                bool
	}{{"", c.RunID, c.ID, false}, {"wrong", c.RunID, c.ID, false}, {peer.Token, c.RunID, c.ID, false}, {peer.Token, c.RunID, peer.ID, false}, {c.Token, second.RunID, c.ID, false}, {c.Token, c.RunID, peer.ID, false}, {c.Token, c.RunID, c.ID, true}} {
		if code := prove(test.token, test.run, test.worker, test.dup); code != 401 && code != 403 {
			t.Fatalf("untrusted proof returned %d", code)
		}
	}
	f.call("POST", "/v1/workers/"+c.ID+"/state", c.Token, map[string]string{"state": "completed"}, 200, "")
	if code := prove(c.Token, c.RunID, c.ID, false); code != 403 {
		t.Fatalf("retired coordinator proof: %d", code)
	}
}

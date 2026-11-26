package device

import (
	"encoding/json"
	"net/http"
	"net/http/cookiejar"
	"strings"
	"testing"
)

func TestRemotePairingAndAPI(t *testing.T) {
	m := testManager(t)
	h := m.Handler()
	data, e := call(t, h, "remote-enable", map[string]any{"listen": "127.0.0.1:0"})
	if e != "" {
		t.Fatal(e)
	}
	var en struct{ URL, Code, PairURL string }
	json.Unmarshal(data, &en)
	t.Cleanup(func() { call(t, h, "remote-disable", map[string]any{}) })
	jar, _ := cookiejar.New(nil)
	c := &http.Client{Jar: jar}
	if r, _ := c.Get(en.URL + "/api/overview"); r.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unpaired API call answered %d, want 401", r.StatusCode)
	}
	if r, _ := c.Get(en.URL + "/"); r.StatusCode != 200 || !strings.HasPrefix(r.Header.Get("Content-Type"), "text/html") {
		t.Fatalf("the page must load before pairing: %d", r.StatusCode)
	}
	r, err := c.Get(en.PairURL)
	if err != nil || r.StatusCode != 200 {
		t.Fatalf("pair: %v %v", r.StatusCode, err)
	}
	r, _ = c.Get(en.URL + "/api/overview")
	var body struct {
		OK   bool
		Data map[string]any
	}
	json.NewDecoder(r.Body).Decode(&body)
	if !body.OK || body.Data["servers"] == nil || body.Data["handoffs"] == nil {
		t.Fatalf("overview: %+v", body)
	}
	if r, _ = c.Get(en.PairURL); r.StatusCode != 403 {
		t.Fatal("pairing code worked twice")
	}
	req, _ := http.NewRequest("POST", en.URL+"/api/approvals/x/y/approve", strings.NewReader(""))
	r, _ = c.Do(req)
	json.NewDecoder(r.Body).Decode(&body)
	if body.OK {
		t.Fatal("POST without the request guard succeeded")
	}
	if r, _ = c.Get(en.URL + "/api/watchable"); r.StatusCode != 200 {
		t.Fatalf("watchable: %d", r.StatusCode)
	}
	data, _ = call(t, h, "remote-devices", map[string]any{})
	if !strings.Contains(string(data), `"name":"Phone"`) {
		t.Fatalf("devices: %s", data)
	}
}

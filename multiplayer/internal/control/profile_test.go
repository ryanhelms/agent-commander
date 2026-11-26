package control

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"image"
	"image/png"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func newSocialFixture(t *testing.T) *Service {
	t.Helper()
	auth := func(r *http.Request) (Principal, error) {
		user := r.Header.Get("Test-User")
		hash := sha256.Sum256([]byte(user + "@example.test"))
		return Principal{User: user, Device: r.Header.Get("Test-Device"), EmailHash: hex.EncodeToString(hash[:])}, nil
	}
	s, err := New(t.Context(), controlTestPool(t), "social", auth, nil)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func socialRequest(t *testing.T, h http.Handler, user, device, method, path string, in any, wantStatus int) *httptest.ResponseRecorder {
	t.Helper()
	data, err := json.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(method, path, bytes.NewReader(data)).WithContext(t.Context())
	req.Header.Set("Test-User", user)
	req.Header.Set("Test-Device", device)
	out := httptest.NewRecorder()
	h.ServeHTTP(out, req)
	if out.Code != wantStatus {
		t.Fatalf("%s %s as %s: expected %d, got %d %s", method, path, user, wantStatus, out.Code, out.Body)
	}
	return out
}

func TestPartialProfileAndAvatar(t *testing.T) {
	s := newSocialFixture(t)
	h := s.Handler()
	if _, err := s.pool.Exec(t.Context(), "INSERT INTO mp_members(user_id) VALUES ('sam')"); err != nil {
		t.Fatal(err)
	}
	called := func(method, path string, input any, status int) *httptest.ResponseRecorder {
		t.Helper()
		return socialRequest(t, h, "sam", "phone", method, path, input, status)
	}
	profile := func(method, path string, in any) User {
		t.Helper()
		var u User
		if err := json.Unmarshal(called(method, path, in, 200).Body.Bytes(), &u); err != nil {
			t.Fatal(err)
		}
		return u
	}
	if u := profile("GET", "/v1/profile", nil); u.User != "sam" || u.Presence != "offline" || u.Handle != "" || u.LastSeen != nil {
		t.Fatalf("defaults at enrollment: %+v", u)
	}
	profile("PUT", "/v1/profile", map[string]string{"displayName": "Sam", "statusMessage": "Working", "presence": "busy"})
	var pngData bytes.Buffer
	if err := png.Encode(&pngData, image.NewRGBA(image.Rect(0, 0, 1, 1))); err != nil {
		t.Fatal(err)
	}
	avatar := "data:image/png;base64," + base64.StdEncoding.EncodeToString(pngData.Bytes())
	profile("PUT", "/v1/profile", map[string]string{"avatar": avatar})
	profile("PUT", "/v1/profile", map[string]string{"handle": "SAm"})
	if u := profile("GET", "/v1/users/sam", nil); u.Handle != "sam" || u.DisplayName != "Sam" || u.StatusMessage != "Working" || !u.HasAvatar || u.Presence != "offline" {
		t.Fatalf("patch lost earlier fields: %+v", u)
	}
	called("PUT", "/v1/profile", map[string]string{"handle": "", "displayName": "lost"}, 400)
	called("PUT", "/v1/profile", map[string]string{"presence": "offline"}, 400)
	called("PUT", "/v1/profile", map[string]string{"avatar": "data:image/jpeg;base64,eA=="}, 400)
	called("PUT", "/v1/profile", map[string]string{"avatar": "data:image/png;base64," + base64.StdEncoding.EncodeToString(make([]byte, 65537))}, 400)
	pic := called("GET", "/v1/users/SAM/avatar", nil, 200)
	if pic.Header().Get("Content-Type") != "image/png" || !bytes.Equal(pic.Body.Bytes(), pngData.Bytes()) {
		t.Fatal("avatar response lost image data or content type")
	}
	socialRequest(t, h, "", "", "GET", "/v1/users/sam/avatar", nil, 401)
	called("GET", "/v1/users/unknown/avatar", nil, 404)
	if u := profile("PUT", "/v1/profile", map[string]string{"avatar": "", "statusMessage": ""}); u.HasAvatar || u.StatusMessage != "" || u.DisplayName != "Sam" {
		t.Fatalf("clear avatar and status: %+v", u)
	}
	called("GET", "/v1/users/sam/avatar", nil, 404)
}

func TestFriendPresenceAndContactPrivacy(t *testing.T) {
	s := newSocialFixture(t)
	h := s.Handler()
	ctx := t.Context()
	const samKey = "88f19028bf2b18c75a652f4ef921bfb2e0054d337960bccb42e1e84fe2a53fba"
	if _, err := s.pool.Exec(ctx, "INSERT INTO mp_members(user_id,contact_key) VALUES ('sam',$1)", samKey); err != nil {
		t.Fatal(err)
	}
	req := func(user, device, method, path string, in any) *httptest.ResponseRecorder {
		t.Helper()
		return socialRequest(t, h, user, device, method, path, in, 200)
	}
	for _, user := range []string{"sam", "jane"} {
		req(user, "phone", "PUT", "/v1/profile", map[string]string{"handle": user})
	}
	req("sam", "phone", "PUT", "/v1/profile", map[string]string{"presence": "dnd"})
	lease := func(device string) Lease {
		t.Helper()
		var l Lease
		if err := json.Unmarshal(req("sam", device, "POST", "/v1/session", nil).Body.Bytes(), &l); err != nil {
			t.Fatal(err)
		}
		req("sam", device, "PUT", "/v1/session", leaseProof{l.Session, l.Generation})
		return l
	}
	phone := lease("phone")
	see := func(viewer string) User {
		t.Helper()
		var u User
		r := req(viewer, "phone", "GET", "/v1/users/sam", nil)
		if err := json.Unmarshal(r.Body.Bytes(), &u); err != nil {
			t.Fatal(err)
		}
		if u.ContactKey == "" && bytes.Contains(r.Body.Bytes(), []byte(`"contactKey"`)) {
			t.Fatal("contactKey should be omitted")
		}
		return u
	}
	if u := see("sam"); !u.Online || u.Presence != "dnd" || u.ContactKey != samKey || u.LastSeen != nil {
		t.Fatalf("self: %+v", u)
	}
	if u := see("jane"); u.Online || u.Presence != "offline" || u.ContactKey != "" || u.LastSeen != nil {
		t.Fatalf("stranger: %+v", u)
	}
	req("sam", "phone", "POST", "/v1/friends/jane", nil)
	if u := see("jane"); u.Online || u.ContactKey != "" || u.LastSeen != nil {
		t.Fatalf("pending request: %+v", u)
	}
	req("jane", "phone", "PUT", "/v1/friends/sam", nil)
	var friends struct{ Friends []User }
	if err := json.Unmarshal(req("jane", "phone", "GET", "/v1/friends", nil).Body.Bytes(), &friends); err != nil {
		t.Fatal(err)
	}
	if len(friends.Friends) != 1 || friends.Friends[0].ContactKey != samKey || friends.Friends[0].Presence != "dnd" || friends.Friends[0].Status != "accepted" {
		t.Fatalf("accepted friend list: %+v", friends)
	}
	lease("laptop")
	req("sam", "phone", "DELETE", "/v1/session", leaseProof{phone.Session, phone.Generation})
	if u := see("jane"); !u.Online || u.LastSeen != nil || u.Presence != "dnd" {
		t.Fatalf("second device still online: %+v", u)
	}
	// Ensure the laptop expires after the explicit phone disconnect, in the database clock.
	var expired time.Time
	if err := s.pool.QueryRow(ctx, "UPDATE mp_leases SET expires_at=clock_timestamp() WHERE device='laptop' RETURNING expires_at").Scan(&expired); err != nil {
		t.Fatal(err)
	}
	checkOffline := func() {
		t.Helper()
		if u := see("jane"); u.Online || u.LastSeen == nil || !u.LastSeen.Equal(expired) || u.Presence != "offline" || u.ContactKey != samKey {
			t.Fatalf("offline accepted friend, expected lastSeen %s: %+v", expired, u)
		}
	}
	checkOffline()
	req("sam", "laptop", "POST", "/v1/session", nil)
	checkOffline() // Taking over the expired lease shouldn't erase its last ready time.
	req("jane", "phone", "DELETE", "/v1/friends/sam", nil)
	if u := see("jane"); u.ContactKey != "" || u.LastSeen != nil {
		t.Fatalf("removed friend: %+v", u)
	}
}

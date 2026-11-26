package control

import (
	"net/http/httptest"
	"testing"
)

func TestKnowledgeVersionsRespectAudienceAndPolicy(t *testing.T) {
	s := newSocialFixture(t)
	h := s.Handler()
	call := func(who, method, path string, in any, status int) *httptest.ResponseRecorder {
		t.Helper()
		return socialRequest(t, h, who, who+"-device", method, path, in, status)
	}
	for _, u := range []string{"alice", "bob", "cara"} {
		call(u, "PUT", "/v1/profile", map[string]string{"handle": u}, 200)
	}
	call("alice", "POST", "/v1/friends/bob", nil, 200)
	call("bob", "PUT", "/v1/friends/alice", nil, 200)
	in := map[string]string{"name": "review", "kind": "instructions", "content": "draft"}
	const endpoint = "/v1/knowledge"
	first := shareResponse[knowledgeItem](t, call("alice", "POST", endpoint, in, 200))
	if first.Version != 1 || first.Visibility != "private" || first.ID == "" {
		t.Fatal(first)
	}
	item := endpoint + "/" + first.ID
	history := func(who string, status int) []knowledgeItem {
		t.Helper()
		response := call(who, "GET", item+"/versions", nil, status)
		if status != 200 {
			return nil
		}
		return shareResponse[struct{ Versions []knowledgeItem }](t, response).Versions
	}
	browse := func(who string) []knowledgeItem {
		return shareResponse[struct{ Items []knowledgeItem }](t, call(who, "GET", endpoint, nil, 200)).Items
	}
	if len(browse("bob")) != 0 {
		t.Fatal("friend could read a draft")
	}
	history("bob", 404)
	call("bob", "PUT", item, map[string]string{"content": "overwrite"}, 404)
	call("alice", "PUT", item, map[string]string{"visibility": "friend:cara"}, 403)
	call("alice", "PUT", item, map[string]string{"visibility": "friend:bob", "content": "published"}, 200)
	if v := history("bob", 200); len(v) != 1 || v[0].Content != "published" {
		t.Fatal(v)
	}
	if v := history("alice", 200); len(v) != 2 || v[1].Content != "draft" {
		t.Fatal(v)
	}
	if v := browse("bob"); len(v) != 1 || v[0].Version != 2 {
		t.Fatal(v)
	}
	call("bob", "PUT", "/v1/profile", map[string]string{"handle": "robert"}, 200)
	call("cara", "PUT", "/v1/profile", map[string]string{"handle": "bob"}, 200)
	history("cara", 404)
	if v := history("bob", 200); len(v) != 1 || v[0].Visibility != "friend:robert" {
		t.Fatal(v)
	}
	group := shareResponse[struct{ ID string }](t, call("alice", "POST", "/v1/groups", map[string]string{"name": "reviewers"}, 200)).ID
	call("alice", "PUT", "/v1/groups/"+group+"/members/robert", nil, 200)
	call("alice", "PUT", item, map[string]string{"visibility": "group:" + group, "content": "group instructions"}, 200)
	if v := history("bob", 200); len(v) != 2 || v[0].Version != 3 {
		t.Fatal(v)
	}
	call("alice", "DELETE", "/v1/groups/"+group+"/members/robert", nil, 200)
	history("bob", 404)
	call("alice", "PUT", item, map[string]string{"visibility": "server"}, 200)
	if len(browse("cara")) != 1 {
		t.Fatal("missing server item")
	}
	if _, err := s.pool.Exec(t.Context(), `UPDATE mp_policy SET knowledge_widest='friend'`); err != nil {
		t.Fatal(err)
	}
	history("cara", 404)
	if len(browse("bob")) != 0 {
		t.Fatal("tightened policy left item visible")
	}
	call("alice", "PUT", item, map[string]string{"content": "still server"}, 403)
	call("alice", "PUT", item, map[string]string{"visibility": "friend:robert"}, 200)
	call("alice", "DELETE", "/v1/friends/robert", nil, 200)
	history("bob", 404)
}

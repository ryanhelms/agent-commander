package device

import (
	"context"
	"testing"
)

func TestRepoSlug(t *testing.T) {
	for in, want := range map[string]string{
		"github.com/example/relay":             "example/relay",
		"https://github.com/example/relay.git": "example/relay",
		"git@github.com:example/relay.git":     "example/relay",
	} {
		if got, err := repoSlug(in); err != nil || got != want {
			t.Errorf("repoSlug(%q) = %q, %v", in, got, err)
		}
	}
	if _, err := repoSlug("gitlab.com/example/relay"); err == nil {
		t.Error("a non-GitHub repository should be refused")
	}
}

func TestListPullRequestsParsesGh(t *testing.T) {
	old := listPullRequests
	t.Cleanup(func() { listPullRequests = old })
	listPullRequests = func(_ context.Context, repo string) ([]byte, error) {
		if repo != "example/relay" {
			t.Fatalf("repo %q", repo)
		}
		return []byte(`[{"number":7,"title":"Fix lease","url":"https://github.com/example/relay/pull/7","state":"OPEN","headRefName":"fix-lease","author":{"login":"sam"}}]`), nil
	}
	raw, _ := listPullRequests(context.Background(), "example/relay")
	if len(raw) == 0 {
		t.Fatal("stub not called")
	}
}

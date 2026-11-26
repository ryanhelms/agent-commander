package device

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"agentcommander.network/pilot/internal/identity"
)

// pullRequest is one open pull request in a workspace's repository.
type pullRequest struct {
	Number int    `json:"number"`
	Title  string `json:"title"`
	URL    string `json:"url"`
	Author string `json:"author"`
	State  string `json:"state"`
	Branch string `json:"branch"`
}

// listPullRequests runs gh with the person's own GitHub login. Tests replace it.
var listPullRequests = func(ctx context.Context, repo string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "gh", "pr", "list", "--repo", repo, "--state", "open", "--limit", "50",
		"--json", "number,title,url,author,state,headRefName").Output()
}

var githubRepo = regexp.MustCompile(`^(?:https?://)?(?:www\.)?github\.com[/:]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$`)

// repoSlug turns a workspace repository into owner/name for gh.
func repoSlug(repository string) (string, error) {
	r := strings.TrimSpace(repository)
	if m := githubRepo.FindStringSubmatch(r); m != nil {
		return m[1] + "/" + m[2], nil
	}
	if m := regexp.MustCompile(`^git@github\.com:([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?$`).FindStringSubmatch(r); m != nil {
		return m[1] + "/" + m[2], nil
	}
	return "", fmt.Errorf("pull requests can only be listed for GitHub repositories, not %s", repository)
}

// workspacePRs lists the open pull requests of a pull_request workspace.
func (a *Agent) workspacePRs(ctx context.Context, s identity.Session, in input) (any, error) {
	if in.Workspace == "" {
		return nil, errors.New("name a workspace")
	}
	var list struct {
		Workspaces []struct{ ID, Repository, Integration string }
	}
	if e := a.remote(ctx, s, "GET", "/v1/workspaces", nil, &list); e != nil {
		return nil, e
	}
	for _, w := range list.Workspaces {
		if w.ID != in.Workspace {
			continue
		}
		slug, e := repoSlug(w.Repository)
		if e != nil {
			return nil, e
		}
		raw, e := listPullRequests(ctx, slug)
		if e != nil {
			return nil, fmt.Errorf("gh could not list pull requests for %s; check that gh is installed and signed in", slug)
		}
		var rows []struct {
			Number      int
			Title, URL  string
			State       string
			HeadRefName string
			Author      struct{ Login string }
		}
		if json.Unmarshal(raw, &rows) != nil {
			return nil, errors.New("gh returned an unreadable pull request list")
		}
		out := []pullRequest{}
		for _, r := range rows {
			out = append(out, pullRequest{r.Number, r.Title, r.URL, r.Author.Login, strings.ToLower(r.State), r.HeadRefName})
		}
		return map[string]any{"workspace": w.ID, "repository": slug, "pullRequests": out}, nil
	}
	return nil, fmt.Errorf("unknown workspace %s", in.Workspace)
}

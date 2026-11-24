//go:build pilotfixture

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

func inspect(ctx context.Context, handle, onlyResource string) error {
	roots, e := fixtureRoots()
	if e != nil {
		return e
	}
	client := fixtureHTTP(roots)
	defer client.CloseIdleConnections()
	token, e := readSecret(githubToken)
	if e != nil {
		return e
	}
	get := func(path string, out any) (bool, error) {
		r, e := http.NewRequestWithContext(ctx, "GET", githubOrigin+"/repos/"+handle+"/pilot/"+path, nil)
		if e != nil {
			return false, e
		}
		r.Header.Set("Authorization", "Bearer "+token)
		resp, e := client.Do(r)
		if e != nil {
			return false, errors.New("fixture repository unavailable")
		}
		defer resp.Body.Close()
		if resp.StatusCode == 404 {
			return false, nil
		}
		if resp.StatusCode != 200 {
			return false, fmt.Errorf("repository inspection returned HTTP %d", resp.StatusCode)
		}
		b, e := io.ReadAll(io.LimitReader(resp.Body, 65537))
		if e != nil || len(b) > 65536 || json.Unmarshal(b, out) != nil {
			return false, errors.New("invalid fixture repository response")
		}
		return true, nil
	}
	published := func(resource string) (string, error) {
		var ref struct{ Object struct{ SHA string } }
		found, e := get("git/ref/heads/commander-share/"+resource, &ref)
		if e != nil || !found {
			return "", e
		}
		if len(ref.Object.SHA) != 40 && len(ref.Object.SHA) != 64 {
			return "", errors.New("missing published revision")
		}
		return ref.Object.SHA, nil
	}
	if onlyResource != "" {
		head, e := published(onlyResource)
		if e != nil {
			return e
		}
		if head == "" {
			return errors.New("branch has not been published")
		}
		fmt.Println(head)
		return nil
	}
	var issue struct {
		State    string
		Comments int
	}
	found, e := get("issues/1", &issue)
	if e != nil {
		return e
	}
	if !found {
		return errors.New("fixture issue missing")
	}
	turns, e := filepath.Glob(stateDir + "/turns/*.json")
	if e != nil {
		return e
	}
	local, e := runGit(ctx, checkout, "for-each-ref", "--format=%(refname)", "refs/heads/commander-share")
	if e != nil {
		return e
	}
	heads := map[string]string{}
	for _, branch := range strings.Fields(local) {
		id, ok := strings.CutPrefix(branch, "refs/heads/commander-share/")
		if !ok || !resourceID.MatchString(id) {
			continue
		}
		head, e := published(id)
		if e != nil {
			return e
		}
		if head != "" {
			heads[id] = head
		}
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{"comments": issue.Comments, "issue_state": issue.State, "worker_turns": len(turns), "pushed_heads": heads})
}

package linear

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestGrantRequiresCredentialReferenceAndTeamUUIDs(t *testing.T) {
	tool := IssueRead(t.TempDir(), nil)
	for _, test := range []struct{ name, settings string }{
		{"missing settings", ""},
		{"empty teams", `{"credential":"work","team_ids":[]}`},
		{"team display key", `{"credential":"work","team_ids":["ENG"]}`},
		{"external path", `{"credential":"../work","team_ids":["7f6d8dee-b367-4a1f-8cbe-b0d0d6d8f250"]}`},
		{"unknown override", `{"credential":"work","team_ids":["7f6d8dee-b367-4a1f-8cbe-b0d0d6d8f250"],"endpoint":"https://example.invalid"}`},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := tool.Bind(json.RawMessage(test.settings)); err == nil {
				t.Fatal("accepted an invalid Linear grant")
			}
		})
	}
}

func TestCredentialMustBePrivateRegularFile(t *testing.T) {
	state := t.TempDir()
	dir := filepath.Join(state, "linear-credentials")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "work.key")
	if err := os.WriteFile(path, []byte("sample-key\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if key, err := readCredential(state, "work"); err != nil || key != "sample-key" {
		t.Fatalf("could not read private credential: %v", err)
	}
	if err := os.Chmod(path, 0640); err != nil {
		t.Fatal(err)
	}
	if _, err := readCredential(state, "work"); err == nil {
		t.Fatal("accepted a group-readable credential")
	}
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(path, filepath.Join(dir, "linked.key")); err != nil {
		t.Fatal(err)
	}
	if _, err := readCredential(state, "linked"); err == nil {
		t.Fatal("accepted a credential symlink")
	}
}

func TestIssueProjectionTruncatesOnUTF8Boundary(t *testing.T) {
	var found issue
	found.Identifier = "ENG-24"
	found.Title = "Example title"
	found.Description = strings.Repeat("界", 2800)
	found.State.Name = "Todo"
	found.URL = "https://linear.app/example/issue/ENG-24"
	raw, err := projectIssue(&found)
	if err != nil {
		t.Fatal(err)
	}
	var result issueResult
	if err := json.Unmarshal(raw, &result); err != nil {
		t.Fatal(err)
	}
	if !result.DescriptionTruncated || !utf8.ValidString(result.Description) ||
		result.Description != strings.Repeat("界", 2730) {
		t.Fatal("unexpected truncated description")
	}
}

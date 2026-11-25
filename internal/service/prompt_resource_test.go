package service

import (
	"net/url"
	"os"
	"path/filepath"
	"testing"
)

func TestPromptResourceRequiresNegotiationAndLocalScope(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "context.txt")
	if err := os.WriteFile(path, []byte("exact $context\n"), 0600); err != nil {
		t.Fatal(err)
	}
	var err error
	path, err = filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	address := (&url.URL{Scheme: "file", Path: path}).String()
	payload := `[{"type":"resource_link","uri":"` + address + `","name":"context.txt"},
		{"type":"resource","uri":"urn:commander:context","source":{"type":"text","value":"exact $context\n"}}]`
	text, parts, err := aguiPrompt([]byte(payload))
	if err != nil || text != "" || len(parts) != 2 {
		t.Fatalf("ordered context: %q, %+v, %v", text, parts, err)
	}
	if parts[0].URI != address || parts[1].ResourceText == nil || *parts[1].ResourceText != "exact $context\n" {
		t.Fatalf("literal source was changed: %+v", parts)
	}
	capabilities := &PromptCapabilities{ResourceLink: true}
	if !capabilities.allows(parts[:1]) || capabilities.allows(parts) {
		t.Fatal("embedded resources must be negotiated separately from links")
	}
	capabilities.EmbeddedContext = true
	if !capabilities.allows(parts) {
		t.Fatal("supported context was rejected")
	}
	if err := validatePromptResourceLinks(dir, parts); err != nil {
		t.Fatal(err)
	}
	if err := validatePromptResourceLinks(t.TempDir(), parts); err == nil {
		t.Fatal("cross-workspace resource link was accepted")
	}
}

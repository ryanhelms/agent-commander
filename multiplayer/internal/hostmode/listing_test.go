package hostmode

import (
	"strings"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/directory"
)

func TestListingReport(t *testing.T) {
	dir := t.TempDir()
	if err := InitConfig(dir, Config{
		Name: "Relay", Listen: ":8443", Hostnames: []string{"relay.example.test"},
		Issuer: GoogleIssuer, ClientID: "desktop", Admins: []string{"admin@example.test"},
	}); err != nil {
		t.Fatal(err)
	}
	cfg, _ := ReadConfig(dir)
	if r := listingReport(dir, cfg); r.URL != "" || r.Directory != directory.DefaultURL || r.Listed {
		t.Fatalf("unlisted report %+v", r)
	}
	if err := SetPublicListing(dir, "relay.example.org", ""); err != nil {
		t.Fatal(err)
	}
	cfg, _ = ReadConfig(dir)
	if url, d := ListingTarget(dir); url != "https://relay.example.org" || d != directory.DefaultURL {
		t.Fatalf("target %q %q", url, d)
	}
	now := time.Now().UTC().Truncate(time.Second)
	if err := WriteListingStatus(dir, ListingStatus{URL: "https://relay.example.org", Listed: true, CheckedAt: now}); err != nil {
		t.Fatal(err)
	}
	if r := listingReport(dir, cfg); r.URL != "https://relay.example.org" || !r.Listed || !r.CheckedAt.Equal(now) {
		t.Fatalf("listed report %+v", r)
	}
	// A status for another address says nothing about this one.
	if err := WriteListingStatus(dir, ListingStatus{URL: "https://old.example.org", Listed: true, CheckedAt: now}); err != nil {
		t.Fatal(err)
	}
	if r := listingReport(dir, cfg); r.Listed || r.Error != "" {
		t.Fatalf("stale status used: %+v", r)
	}
	WriteListingStatus(dir, ListingStatus{URL: "https://relay.example.org", Error: "the relay's address is not public", CheckedAt: now})
	if r := listingReport(dir, cfg); r.Listed || r.Error != "the relay's address is not public" {
		t.Fatalf("failed report %+v", r)
	}
	if _, err := ReadListingInput([]byte(`{"url":"x","bogus":1}`)); err == nil || !strings.Contains(err.Error(), "can't be read") {
		t.Fatalf("unknown field: %v", err)
	}
	if in, err := ReadListingInput([]byte(`{"url":"https://relay.example.org"}`)); err != nil || in.URL != "https://relay.example.org" {
		t.Fatalf("input %+v %v", in, err)
	}
}

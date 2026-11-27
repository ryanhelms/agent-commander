package hostmode

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"

	"agentcommander.network/pilot/internal/directory"
)

// The tray's "List publicly" switch. The running relay reads the listing from
// host.json about every 30 seconds and writes what happened to
// directory-status.json, so the switch needs no restart and the tray can say
// whether the relay is listed or why not.

const listingStatusFile = "directory-status.json"

// ListingStatus is the relay's last attempt to update its listing.
type ListingStatus struct {
	URL       string    `json:"url,omitempty"`
	Listed    bool      `json:"listed"`
	Error     string    `json:"error,omitempty"`
	CheckedAt time.Time `json:"checkedAt"`
}

// ListingReport is the "listing" block of the host report.
type ListingReport struct {
	// URL is the public origin the relay lists itself under; empty when it is unlisted.
	URL       string    `json:"url"`
	Directory string    `json:"directory"`
	Listed    bool      `json:"listed"`
	Error     string    `json:"error,omitempty"`
	CheckedAt time.Time `json:"checkedAt,omitzero"`
}

// WriteListingStatus records the relay's last listing attempt.
func WriteListingStatus(dir string, s ListingStatus) error {
	data, err := json.Marshal(s)
	if err != nil {
		return err
	}
	return publishFile(filepath.Join(dir, listingStatusFile), append(data, '\n'), true)
}

func readListingStatus(dir string) (ListingStatus, bool) {
	data, err := os.ReadFile(filepath.Join(dir, listingStatusFile))
	if err != nil {
		return ListingStatus{}, false
	}
	var s ListingStatus
	if json.Unmarshal(data, &s) != nil {
		return ListingStatus{}, false
	}
	return s, true
}

func listingReport(dir string, cfg Config) *ListingReport {
	r := &ListingReport{URL: cfg.PublicListing, Directory: cfg.DirectoryURL}
	if r.Directory == "" {
		r.Directory = directory.DefaultURL
	}
	// A status for another address, or from before the switch was turned off, says nothing.
	if s, ok := readListingStatus(dir); ok && s.URL == cfg.PublicListing && cfg.PublicListing != "" {
		r.Listed, r.Error, r.CheckedAt = s.Listed, s.Error, s.CheckedAt
	}
	return r
}

// ListingTarget reads the listing the relay should have now: the public
// origin (empty for none) and the directory.
func ListingTarget(dir string) (string, string) {
	cfg, err := ReadConfig(dir)
	if err != nil {
		return "", ""
	}
	d := cfg.DirectoryURL
	if d == "" {
		d = directory.DefaultURL
	}
	return cfg.PublicListing, d
}

// ListingInput is the tray's `host --json listing` request.
type ListingInput struct {
	// URL is the public https origin to list under; empty turns listing off.
	URL       string `json:"url"`
	Directory string `json:"directory"`
}

// ReadListingInput decodes one listing request from the app.
func ReadListingInput(data []byte) (ListingInput, error) {
	var in ListingInput
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		return in, errors.New("the listing Commander sent can't be read")
	}
	return in, nil
}

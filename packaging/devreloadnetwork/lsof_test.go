package main

import (
	"slices"
	"testing"
)

func TestSocketPIDsMatchesOnlyWholeNamesDeduplicated(t *testing.T) {
	raw := []byte("p250\x00\nf3\x00n/tmp/owner\x00\nf4\x00n/tmp/owner\x00\n" +
		"p42\x00\nf4\x00n/private/tmp/owner\x00\n" +
		"p51\x00\nf4\x00n/tmp/owner-other\x00\n" +
		"p61\x00\nf5\x00n-> /tmp/owner\x00\n")
	if got, err := socketPIDs(raw, "/tmp/owner", "/private/tmp/owner"); err != nil ||
		!slices.Equal(got, []int{42, 250}) {
		t.Fatalf("socket owners = %v, %v", got, err)
	}
}

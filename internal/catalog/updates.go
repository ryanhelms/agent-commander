package catalog

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

type Update struct {
	StagedBinary
	CurrentVersion string `json:"current_version"`
	Stage          string `json:"stage"`
}

var stableVersion = regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`)

// Compare stable registry versions without coercing large components to machine integers.
func compareVersions(a, b string) int {
	left, right := strings.Split(a, "."), strings.Split(b, ".")
	for i := range left {
		if len(left[i]) != len(right[i]) {
			return len(left[i]) - len(right[i])
		}
		if order := strings.Compare(left[i], right[i]); order != 0 {
			return order
		}
	}
	return 0
}

// Updates reports verified, staged stable releases for currently pinned
// adapters. Reading notices leaves the active executable unchanged.
func Updates(state string) ([]Update, error) {
	entries, err := os.ReadDir(filepath.Join(state, "catalog", "staged"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	updates := []Update{}
	seen := make(map[string]int)
	conflicted := make(map[string]bool)
	for _, item := range entries {
		if !item.IsDir() || !stageID.MatchString(item.Name()) {
			continue
		}
		_, release, err := readStagedBinary(state, item.Name())
		if err != nil || !stableVersion.MatchString(release.Version) {
			continue
		}
		pinned, err := readPin(state, release.ID)
		if err != nil {
			return nil, err
		}
		if pinned == nil || !stableVersion.MatchString(pinned.Current.Version) ||
			pinned.Current.PublisherKeySHA256 != release.PublisherKeySHA256 || pinned.Current.Catalog != release.Catalog ||
			compareVersions(release.Version, pinned.Current.Version) <= 0 {
			continue
		}
		if digest, found := pinned.Releases[release.Version]; found && digest != release.ManifestSHA256 {
			continue
		}
		if verifyStagedArchive(context.Background(), release) != nil {
			continue
		}
		key := release.ID + "@" + release.Version
		if earlier, exists := seen[key]; exists {
			if updates[earlier].ManifestSHA256 != release.ManifestSHA256 {
				conflicted[key] = true
			}
			continue
		}
		seen[key] = len(updates)
		updates = append(updates, Update{release, pinned.Current.Version, item.Name()})
	}
	updates = slices.DeleteFunc(updates, func(item Update) bool {
		return conflicted[item.ID+"@"+item.Version]
	})
	slices.SortFunc(updates, func(a, b Update) int {
		if order := strings.Compare(a.ID, b.ID); order != 0 {
			return order
		}
		return compareVersions(b.Version, a.Version)
	})
	return updates, nil
}

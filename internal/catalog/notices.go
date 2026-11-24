package catalog

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// Notice is the result of an explicit successful refresh against the active
// publisher pin. The activation command still verifies the chosen artifact.
type Notice struct {
	AdapterID        string `json:"adapterId"`
	CurrentVersion   string `json:"currentVersion"`
	AvailableVersion string `json:"availableVersion"`
	ManifestSHA256   string `json:"manifestSHA256"`
}

// A pin can move independently of the last refresh. Keep an outstanding
// verified release only while it is newer than the newly selected version.
func (p *pin) noticeFor(version string) *Notice {
	n := p.Notice
	if n == nil || n.AdapterID != p.Current.ID || n.CurrentVersion != p.Current.Version ||
		!stableVersion.MatchString(n.AvailableVersion) || !stableVersion.MatchString(version) ||
		compareVersions(n.AvailableVersion, version) <= 0 || len(n.ManifestSHA256) != sha256.Size*2 {
		return nil
	}
	if _, err := hex.DecodeString(n.ManifestSHA256); err != nil {
		return nil
	}
	next := *n
	next.CurrentVersion = version
	return &next
}

func recordRefreshNotice(ctx context.Context, state string, checked *pin, notice *Notice) error {
	root := filepath.Join(state, "catalog")
	unlock, err := lockPins(ctx, root)
	if err != nil {
		return err
	}
	defer unlock()
	id := checked.Current.ID
	now, err := readPin(state, id)
	if err != nil {
		return err
	}
	if now == nil || now.Current.ManifestSHA256 != checked.Current.ManifestSHA256 ||
		now.UpdateSource == nil || now.UpdateSource.EntryURL != checked.UpdateSource.EntryURL ||
		now.UpdateSource.SignatureURL != checked.UpdateSource.SignatureURL {
		return errors.New("adapter pin or update source changed during refresh")
	}
	if now.Notice == nil && notice == nil || now.Notice != nil && notice != nil && *now.Notice == *notice {
		return nil
	}
	now.Notice = notice
	return writePin(ctx, root, id, *now)
}

// RefreshNotices reads the last verified refresh for each installed adapter.
// os.ReadDir orders entries by name. Repeated reads use stable ordering even
// when several independent clients refresh different adapters concurrently.
func RefreshNotices(state string) ([]Notice, error) {
	entries, err := os.ReadDir(filepath.Join(state, "catalog", "pins"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	notices := []Notice{}
	for _, entry := range entries {
		id, ok := strings.CutSuffix(entry.Name(), ".json")
		if !ok || !entry.Type().IsRegular() {
			continue
		}
		current, err := readPin(state, id)
		if err != nil {
			return nil, err
		}
		if current != nil {
			if n := current.noticeFor(current.Current.Version); n != nil {
				notices = append(notices, *n)
			}
		}
	}
	return notices, nil
}

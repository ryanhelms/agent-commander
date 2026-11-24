package catalog

import (
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"time"
)

type updateSource struct {
	EntryURL     string `json:"entry_url"`
	SignatureURL string `json:"signature_url"`
	PublicKey    []byte `json:"public_key"`
}

// SetUpdateSource associates the publisher's proof endpoints with an existing pin.
func SetUpdateSource(ctx context.Context, state, id, entryURL, signatureURL string, publicKey []byte) error {
	for _, address := range []string{entryURL, signatureURL} {
		if _, err := readURL(address); err != nil {
			return err
		}
	}
	_, fingerprint, err := publisherKey(publicKey)
	if err != nil {
		return err
	}
	root := filepath.Join(state, "catalog")
	unlock, err := lockPins(ctx, root)
	if err != nil {
		return err
	}
	defer unlock()
	pinned, err := readPin(state, id)
	if err != nil {
		return err
	}
	if pinned == nil || fingerprint != pinned.Current.PublisherKeySHA256 {
		return errors.New("update source requires the public key of the pinned publisher")
	}
	if pinned.UpdateSource == nil || pinned.UpdateSource.EntryURL != entryURL || pinned.UpdateSource.SignatureURL != signatureURL {
		pinned.Notice = nil
	}
	pinned.UpdateSource = &updateSource{EntryURL: entryURL, SignatureURL: signatureURL, PublicKey: publicKey}
	return writePin(ctx, root, id, *pinned)
}

// Refresh checks one pinned catalog adapter and stages a newer verified release.
// A nil result means that the catalog advertises no newer stable release.
func Refresh(ctx context.Context, state, id string) (*Update, error) {
	return refresh(ctx, httpsClient(15*time.Second), httpsClient(2*time.Minute), state, id)
}

func refresh(ctx context.Context, metadata, artifacts *http.Client, state, id string) (*Update, error) {
	if !profileID.MatchString(id) || id == "claude" || id == "codex" {
		return nil, errors.New("adapter ID is invalid or reserved")
	}
	locks := filepath.Join(state, "catalog", "refresh")
	if err := os.MkdirAll(locks, 0700); err != nil {
		return nil, err
	}
	unlock, err := lockCatalogFile(ctx, filepath.Join(locks, id+".lock"))
	if err != nil {
		return nil, err
	}
	defer unlock()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	pinned, err := readPin(state, id)
	if err != nil {
		return nil, err
	}
	if pinned == nil || pinned.UpdateSource == nil {
		return nil, errors.New("adapter has no configured update source")
	}
	current, source := pinned.Current, pinned.UpdateSource
	_, fingerprint, err := publisherKey(source.PublicKey)
	if err != nil || fingerprint != current.PublisherKeySHA256 {
		return nil, errors.New("update source does not match the pinned publisher")
	}
	if !stableVersion.MatchString(current.Version) {
		return nil, errors.New("catalog refresh requires a stable version pin")
	}
	snapshot, err := read(ctx, metadata, current.Catalog)
	if err != nil {
		return nil, fmt.Errorf("read pinned ACP catalog: %w", err)
	}
	index := slices.IndexFunc(snapshot.Agents, func(agent Agent) bool { return agent.ID == id })
	if index < 0 {
		return nil, errors.New("pinned adapter is absent from its catalog")
	}
	version := snapshot.Agents[index].Version
	if !stableVersion.MatchString(version) || compareVersions(version, current.Version) <= 0 {
		return nil, recordRefreshNotice(ctx, state, pinned, nil)
	}
	entry, err := fetchProof(ctx, metadata, source.EntryURL, 64<<10)
	if err != nil {
		return nil, fmt.Errorf("read publisher entry: %w", err)
	}
	signature, err := fetchProof(ctx, metadata, source.SignatureURL, ed25519.SignatureSize)
	if err != nil {
		return nil, fmt.Errorf("read publisher signature: %w", err)
	}
	proof := BinaryProof{Manifest: entry, Signature: signature, PublicKey: source.PublicKey}
	binary, release, err := verifyRelease(snapshot, id, version, current.PackageManager, proof)
	if err != nil {
		return nil, err
	}
	if digest, found := pinned.Releases[version]; found && digest != release.ManifestSHA256 {
		return nil, errors.New("publisher reused a version for a different release")
	}
	stageDir := filepath.Join(state, "catalog", "staged")
	staged, err := existingUpdateStage(ctx, state, stageDir, release)
	if err != nil {
		return nil, err
	}
	if staged == nil {
		release, err = stageVerifiedRelease(ctx, artifacts, stageDir, binary, release, proof)
		if err != nil {
			return nil, err
		}
		staged = &release
	}
	notice := &Notice{AdapterID: id, CurrentVersion: current.Version, AvailableVersion: staged.Version, ManifestSHA256: staged.ManifestSHA256}
	if err := recordRefreshNotice(ctx, state, pinned, notice); err != nil {
		return nil, err
	}
	return &Update{*staged, current.Version, filepath.Base(staged.Directory)}, nil
}

func existingUpdateStage(ctx context.Context, state, dir string, release StagedBinary) (*StagedBinary, error) {
	entries, err := os.ReadDir(dir)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	var existing *StagedBinary
	for _, item := range entries {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if !item.IsDir() || !stageID.MatchString(item.Name()) {
			continue
		}
		_, staged, err := readStagedBinary(state, item.Name())
		if err != nil || staged.ID != release.ID || staged.Version != release.Version ||
			staged.PublisherKeySHA256 != release.PublisherKeySHA256 || staged.Catalog != release.Catalog ||
			verifyStagedArchive(ctx, staged) != nil {
			continue
		}
		if staged.ManifestSHA256 != release.ManifestSHA256 {
			return nil, errors.New("publisher offered conflicting proofs for the same version")
		}
		if staged.PackageManager == release.PackageManager && staged.ArtifactSHA256 == release.ArtifactSHA256 {
			existing = &staged
		}
	}
	return existing, ctx.Err()
}

func fetchProof(ctx context.Context, client *http.Client, address string, limit int64) ([]byte, error) {
	target, err := readURL(address)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target.String(), nil)
	if err != nil {
		return nil, err
	}
	res, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("proof endpoint returned HTTP %d", res.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(res.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > limit {
		return nil, errors.New("publisher proof exceeds size limit")
	}
	return body, nil
}

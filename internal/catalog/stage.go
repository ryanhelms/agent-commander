package catalog

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"maps"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

const maxBinaryBytes = 512 << 20

// BinaryProof is supplied by the operator. The publisher signs the exact
// bytes of its ACP agent entry using an independently obtained public key.
type BinaryProof struct {
	Manifest  []byte
	Signature []byte
	PublicKey []byte
}

type StagedBinary struct {
	ID                 string `json:"id"`
	Version            string `json:"version"`
	Platform           string `json:"platform"`
	Catalog            string `json:"catalog"`
	CatalogSHA256      string `json:"catalog_sha256"`
	PublisherKeySHA256 string `json:"publisher_key_sha256"`
	ManifestSHA256     string `json:"manifest_sha256"`
	ArtifactSHA256     string `json:"artifact_sha256"`
	Directory          string `json:"directory"`
	PackageManager     string `json:"package_manager,omitempty"`
	PackageSpec        string `json:"package_spec,omitempty"`
}

func packageDistribution(d Distribution, manager string) *Package {
	switch manager {
	case "npm":
		return d.NPX
	case "python":
		return d.UVX
	default:
		return nil
	}
}

func publisherKey(data []byte) (ed25519.PublicKey, string, error) {
	block, rest := pem.Decode(data)
	if block == nil || block.Type != "PUBLIC KEY" || strings.TrimSpace(string(rest)) != "" {
		return nil, "", errors.New("expected one PEM public key")
	}
	parsed, err := x509.ParsePKIXPublicKey(block.Bytes)
	key, ok := parsed.(ed25519.PublicKey)
	if err != nil || !ok {
		return nil, "", errors.New("expected an Ed25519 publisher public key")
	}
	return key, fmt.Sprintf("%x", sha256.Sum256(block.Bytes)), nil
}

func verifyRelease(snapshot Snapshot, id, version, manager string, proof BinaryProof) (Binary, StagedBinary, error) {
	key, fingerprint, err := publisherKey(proof.PublicKey)
	if err != nil {
		return Binary{}, StagedBinary{}, err
	}
	if !ed25519.Verify(key, proof.Manifest, proof.Signature) {
		return Binary{}, StagedBinary{}, errors.New("publisher signature did not verify")
	}
	var signed Agent
	if err := json.Unmarshal(proof.Manifest, &signed); err != nil || signed.ID != id || signed.Version != version {
		return Binary{}, StagedBinary{}, errors.New("signed ACP entry does not identify the requested release")
	}
	index := slices.IndexFunc(snapshot.Agents, func(a Agent) bool { return a.ID == id && a.Version == version })
	if index < 0 {
		return Binary{}, StagedBinary{}, errors.New("the requested adapter and exact version are absent from this catalog")
	}
	binary, signedPlatform := signed.Distribution.Binary[snapshot.HostPlatform]
	distribution := snapshot.Agents[index].Distribution
	var packageSpec string
	if manager == "" {
		candidate, found := distribution.Binary[snapshot.HostPlatform]
		if !found || !signedPlatform ||
			binary.Archive != candidate.Archive ||
			(candidate.SHA256 != "" && !strings.EqualFold(binary.SHA256, candidate.SHA256)) ||
			binary.Command != candidate.Command || !slices.Equal(binary.Args, candidate.Args) || !maps.Equal(binary.Env, candidate.Env) {
			return Binary{}, StagedBinary{}, errors.New("signed binary distribution does not match the catalog release for this host")
		}
	} else {
		candidate, packageProof := packageDistribution(distribution, manager), packageDistribution(signed.Distribution, manager)
		if !signedPlatform || candidate == nil || packageProof == nil || !matchPackageRelease(manager, candidate.Package, packageProof.Package) ||
			!slices.Equal(candidate.Args, packageProof.Args) || !maps.Equal(candidate.Env, packageProof.Env) {
			return Binary{}, StagedBinary{}, errors.New("signed package distribution does not match the catalog or lacks a host bundle")
		}
		binary.Args, binary.Env = packageProof.Args, packageProof.Env
		packageSpec = packageProof.Package
	}
	digest, err := hex.DecodeString(binary.SHA256)
	if err != nil || len(digest) != sha256.Size || strings.TrimSpace(binary.Command) == "" {
		return Binary{}, StagedBinary{}, errors.New("signed binary distribution requires an executable and a SHA-256 archive digest")
	}
	receipt := StagedBinary{
		ID: id, Version: version, Platform: snapshot.HostPlatform, Catalog: snapshot.Source, CatalogSHA256: snapshot.SHA256,
		PublisherKeySHA256: fingerprint, ManifestSHA256: fmt.Sprintf("%x", sha256.Sum256(proof.Manifest)),
		ArtifactSHA256: hex.EncodeToString(digest),
		PackageManager: manager, PackageSpec: packageSpec,
	}
	return binary, receipt, nil
}

// StageBinary verifies publisher authorization before fetching the archive.
// The archive remains inert and is retained with its verification evidence.
func StageBinary(ctx context.Context, dir string, snapshot Snapshot, id, version string, proof BinaryProof) (StagedBinary, error) {
	return stageBinary(ctx, httpsClient(2*time.Minute), dir, snapshot, id, version, proof)
}

func stageBinary(ctx context.Context, client *http.Client, dir string, snapshot Snapshot, id, version string, proof BinaryProof) (StagedBinary, error) {
	return stageRelease(ctx, client, dir, snapshot, id, version, "", proof)
}

func StagePackage(ctx context.Context, dir string, snapshot Snapshot, id, version, manager string, proof BinaryProof) (StagedBinary, error) {
	if manager != "npm" && manager != "python" {
		return StagedBinary{}, errors.New("package manager must be npm or python")
	}
	return stageRelease(ctx, httpsClient(2*time.Minute), dir, snapshot, id, version, manager, proof)
}

func stageRelease(ctx context.Context, client *http.Client, dir string, snapshot Snapshot, id, version, manager string, proof BinaryProof) (StagedBinary, error) {
	binary, receipt, err := verifyRelease(snapshot, id, version, manager, proof)
	if err != nil {
		return StagedBinary{}, err
	}
	return stageVerifiedRelease(ctx, client, dir, binary, receipt, proof)
}

func stageVerifiedRelease(ctx context.Context, client *http.Client, dir string, binary Binary, receipt StagedBinary, proof BinaryProof) (StagedBinary, error) {
	target, err := readURL(binary.Archive)
	if err != nil {
		return StagedBinary{}, fmt.Errorf("invalid signed archive URL: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target.String(), nil)
	if err != nil {
		return StagedBinary{}, err
	}
	response, err := client.Do(req)
	if err != nil {
		return StagedBinary{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return StagedBinary{}, fmt.Errorf("archive request returned HTTP %d", response.StatusCode)
	}
	if response.ContentLength > maxBinaryBytes {
		return StagedBinary{}, errors.New("adapter archive exceeds 512 MiB")
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return StagedBinary{}, err
	}
	scratch, err := os.MkdirTemp(dir, ".incoming-")
	if err != nil {
		return StagedBinary{}, err
	}
	defer os.RemoveAll(scratch)
	if err := stageArchive(ctx, filepath.Join(scratch, "archive"), response.Body, receipt.ArtifactSHA256); err != nil {
		return StagedBinary{}, err
	}
	receipt.Directory = filepath.Join(dir, "stage-"+strings.TrimPrefix(filepath.Base(scratch), ".incoming-"))
	metadata, err := json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		return StagedBinary{}, err
	}
	for name, body := range map[string][]byte{
		"receipt.json": metadata, "publisher-entry.json": proof.Manifest, "publisher-entry.sig": proof.Signature, "publisher.pem": proof.PublicKey,
	} {
		if err := os.WriteFile(filepath.Join(scratch, name), body, 0600); err != nil {
			return StagedBinary{}, err
		}
	}
	if err := ctx.Err(); err != nil {
		return StagedBinary{}, err
	}
	if err := os.Rename(scratch, receipt.Directory); err != nil {
		return StagedBinary{}, err
	}
	return receipt, nil
}

type archiveReader struct {
	ctx    context.Context
	source io.Reader
}

func (r archiveReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.source.Read(p)
}

func stageArchive(ctx context.Context, path string, source io.Reader, expectedDigest string) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	return errors.Join(copyVerifiedArchive(ctx, file, source, expectedDigest), file.Close())
}

func verifyStagedArchive(ctx context.Context, release StagedBinary) error {
	archive, err := os.Open(filepath.Join(release.Directory, "archive"))
	if err != nil {
		return err
	}
	defer archive.Close()
	return copyVerifiedArchive(ctx, io.Discard, archive, release.ArtifactSHA256)
}

func copyVerifiedArchive(ctx context.Context, destination io.Writer, source io.Reader, expectedDigest string) error {
	hash := sha256.New()
	size, copyErr := io.Copy(io.MultiWriter(destination, hash), io.LimitReader(archiveReader{ctx, source}, maxBinaryBytes+1))
	if err := errors.Join(copyErr, ctx.Err()); err != nil {
		return err
	}
	if size > maxBinaryBytes {
		return errors.New("adapter archive exceeds 512 MiB")
	}
	if actual := hex.EncodeToString(hash.Sum(nil)); actual != expectedDigest {
		return errors.New("adapter archive SHA-256 differs from the signed release")
	}
	return nil
}

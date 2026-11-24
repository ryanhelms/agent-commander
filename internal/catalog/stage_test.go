package catalog

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func binaryFixture(t *testing.T, artifact string) (Snapshot, BinaryProof) {
	t.Helper()
	entry := Agent{ID: "fixture", Name: "Fixture", Version: "1.2.3", Distribution: Distribution{
		Binary: map[string]Binary{"darwin-aarch64": {
			Archive: "https://download.example.test/fixture.tar.gz",
			SHA256:  fmt.Sprintf("%x", sha256.Sum256([]byte(artifact))),
			Command: "./agent", Args: []string{"--acp"},
		}},
	}}
	manifest, err := json.Marshal(entry)
	if err != nil {
		t.Fatal(err)
	}
	key, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return Snapshot{Source: "https://catalog.example.test", HostPlatform: "darwin-aarch64", Agents: []Agent{entry}}, BinaryProof{
		Manifest: manifest, Signature: ed25519.Sign(private, manifest), PublicKey: pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}),
	}
}

func TestStageBinaryVerifiesPublisherAndArchive(t *testing.T) {
	const artifact = "publisher's synthetic archive bytes"
	snapshot, proof := binaryFixture(t, artifact)
	var fetches int
	body := artifact
	client := &http.Client{Transport: testTransport(func(req *http.Request) (*http.Response, error) {
		fetches++
		if req.URL.String() != "https://download.example.test/fixture.tar.gz" {
			t.Fatal("request did not use the signed archive URL")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
	})}
	dir := t.TempDir()
	_, wrongKey := binaryFixture(t, artifact)
	changed := snapshot
	changed.Agents = append([]Agent(nil), snapshot.Agents...)
	original := snapshot.Agents[0].Distribution.Binary[snapshot.HostPlatform]
	changedBinary := original
	changedBinary.Args = []string{"--different"}
	changed.Agents[0].Distribution.Binary = map[string]Binary{snapshot.HostPlatform: changedBinary}
	conflictingDigest := snapshot
	conflictingDigest.Agents = append([]Agent(nil), snapshot.Agents...)
	otherDigest := original
	otherDigest.SHA256 = strings.Repeat("0", 64)
	conflictingDigest.Agents[0].Distribution.Binary = map[string]Binary{snapshot.HostPlatform: otherDigest}
	for title, rejected := range map[string]struct {
		snapshot Snapshot
		proof    BinaryProof
	}{
		"untrusted publisher":      {snapshot, BinaryProof{Manifest: proof.Manifest, Signature: proof.Signature, PublicKey: wrongKey.PublicKey}},
		"changed launch arguments": {changed, proof},
		"conflicting digest":       {conflictingDigest, proof},
	} {
		t.Run(title, func(t *testing.T) {
			if _, err := stageBinary(context.Background(), client, dir, rejected.snapshot, "fixture", "1.2.3", rejected.proof); err == nil || fetches != 0 {
				t.Fatalf("unverified entry reached artifact transport: fetches=%d err=%v", fetches, err)
			}
		})
	}
	body = "tampered bytes"
	if _, err := stageBinary(context.Background(), client, dir, snapshot, "fixture", "1.2.3", proof); err == nil || !strings.Contains(err.Error(), "SHA-256") {
		t.Fatalf("tampered artifact was accepted: %v", err)
	}
	if entries, err := os.ReadDir(dir); err != nil || len(entries) != 0 {
		t.Fatalf("failed staging left an artifact: %v, %v", entries, err)
	}
	body = artifact
	beforeStage, cancel := context.WithCancel(t.Context())
	defer cancel()
	canceledClient := &http.Client{Transport: testTransport(func(*http.Request) (*http.Response, error) {
		body := io.MultiReader(strings.NewReader(artifact), cancelOnEOF{cancel})
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(body)}, nil
	})}
	if _, err := stageBinary(beforeStage, canceledClient, dir, snapshot, "fixture", "1.2.3", proof); !errors.Is(err, context.Canceled) {
		t.Fatalf("a canceled download published a stage: %v", err)
	}
	if entries, err := os.ReadDir(dir); err != nil || len(entries) != 0 {
		t.Fatalf("a canceled download left a partial stage: %v, %v", entries, err)
	}
	unsignedDigest := original
	unsignedDigest.SHA256 = ""
	snapshot.Agents[0].Distribution.Binary = map[string]Binary{snapshot.HostPlatform: unsignedDigest}
	stage, err := stageBinary(context.Background(), client, dir, snapshot, "fixture", "1.2.3", proof)
	if err != nil {
		t.Fatal(err)
	}
	if stage.ID != "fixture" || stage.Version != "1.2.3" || len(stage.PublisherKeySHA256) != 64 || stage.ArtifactSHA256 != original.SHA256 {
		t.Fatalf("incorrect verification receipt: %+v", stage)
	}
	path := filepath.Join(stage.Directory, "archive")
	data, err := os.ReadFile(path)
	if err != nil || string(data) != artifact {
		t.Fatalf("staged archive mismatch: %s, %v", data, err)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("staged archive should be private and inert: %v, %v", info, err)
	}
}

type cancelOnEOF struct{ cancel context.CancelFunc }

func (r cancelOnEOF) Read([]byte) (int, error) {
	r.cancel()
	return 0, io.EOF
}

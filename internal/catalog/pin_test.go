package catalog

import (
	"archive/zip"
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
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestActivateAndRollbackKeepRunningVersion(t *testing.T) {
	key, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(key)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	stage := func(version string, protocol int) StagedBinary {
		t.Helper()
		script := fmt.Sprintf("#!/bin/sh\nIFS= read -r ignored\nprintf '%%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":%d}}'\n# release %s\n", protocol, version)
		agent := Agent{ID: "fixture", Name: "Fixture", Version: version, Distribution: Distribution{Binary: map[string]Binary{
			hostPlatform(): {Archive: "https://publisher.example/agent", SHA256: fmt.Sprintf("%x", sha256.Sum256([]byte(script))), Command: "./agent"},
		}}}
		manifest, err := json.Marshal(agent)
		if err != nil {
			t.Fatal(err)
		}
		proof := BinaryProof{Manifest: manifest, Signature: ed25519.Sign(private, manifest), PublicKey: pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})}
		client := &http.Client{Transport: testTransport(func(req *http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(script))}, nil
		})}
		result, err := stageBinary(context.Background(), client, filepath.Join(root, "catalog", "staged"),
			Snapshot{Source: "https://catalog.example", HostPlatform: hostPlatform(), Agents: []Agent{agent}}, "fixture", version, proof)
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	apply := func(staged StagedBinary) (InstalledBinary, error) {
		return Activate(context.Background(), root, filepath.Base(staged.Directory), staged.PublisherKeySHA256)
	}
	first := stage("1.0.0", 1)
	if _, err := Activate(context.Background(), root, filepath.Base(first.Directory), strings.Repeat("0", 64)); err == nil {
		t.Fatal("activation accepted a different publisher fingerprint")
	}
	one, err := apply(first)
	if err != nil {
		t.Fatal(err)
	}
	retried, err := apply(first)
	if err != nil || retried.Directory != one.Directory {
		t.Fatalf("retry did not reuse the verified installation: %+v, %v", retried, err)
	}
	if err := os.WriteFile(filepath.Join(first.Directory, "archive"), []byte("replaced after initial activation"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := apply(first); err == nil || !strings.Contains(err.Error(), "SHA-256") {
		t.Fatalf("same-version activation accepted an altered staged archive: %v", err)
	}
	currentPin, err := LoadPin(root, "fixture")
	if err != nil || currentPin == nil || currentPin.Command != one.Command {
		t.Fatalf("failed same-version activation changed the existing launcher: %+v, %v", currentPin, err)
	}
	second := stage("2.0.0", 1)
	_ = stage("2.0.0", 1)
	tampered := stage("9.0.0", 1)
	if err := os.WriteFile(filepath.Join(tampered.Directory, "archive"), []byte("changed"), 0600); err != nil {
		t.Fatal(err)
	}
	_ = stage("1.1.0", 1)
	_ = stage("1.1.0", 2)
	updates, err := Updates(root)
	if err != nil || len(updates) != 1 || updates[0].Version != "2.0.0" || updates[0].CurrentVersion != "1.0.0" {
		t.Fatalf("expected one verified candidate, excluding duplicate, altered and ambiguous releases: %+v, %v", updates, err)
	}
	stillPinned, err := LoadPin(root, "fixture")
	if err != nil || stillPinned == nil || stillPinned.Command != one.Command {
		t.Fatalf("reading update notices changed the active pin: %+v, %v", stillPinned, err)
	}
	unlock, err := lockPins(t.Context(), filepath.Join(root, "catalog"))
	if err != nil {
		t.Fatal(err)
	}
	waiting, cancelWaiting := context.WithTimeout(t.Context(), 75*time.Millisecond)
	defer cancelWaiting()
	waited := make(chan error, 1)
	go func() {
		_, err := Activate(waiting, root, filepath.Base(second.Directory), second.PublisherKeySHA256)
		waited <- err
	}()
	select {
	case err := <-waited:
		unlock()
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("waiting for another installer did not return cancellation: %v", err)
		}
	case <-time.After(2 * time.Second):
		unlock()
		t.Fatal("canceled activation remained blocked on the pin lock")
	}
	activating, cancelActivation := context.WithCancel(t.Context())
	defer cancelActivation()
	if _, err := activate(activating, root, filepath.Base(second.Directory), second.PublisherKeySHA256,
		func(context.Context, InstalledBinary) error {
			cancelActivation()
			return nil
		}); !errors.Is(err, context.Canceled) {
		t.Fatalf("activation switched the pin after cancellation: %v", err)
	}
	stillPinned, err = LoadPin(root, "fixture")
	if err != nil || stillPinned == nil || stillPinned.Command != one.Command {
		t.Fatalf("cancellation changed the active pin: %+v, %v", stillPinned, err)
	}
	if entries, err := os.ReadDir(filepath.Join(root, "catalog", "installed")); err != nil || len(entries) != 1 {
		t.Fatalf("cancellation left a partial installation: %v, %v", entries, err)
	}
	two, err := apply(second)
	if err != nil || one.Command == two.Command {
		t.Fatalf("activation did not use a new immutable executable: %+v, %v", two, err)
	}
	if _, err := apply(stage("3.0.0", 2)); err == nil {
		t.Fatal("incompatible adapter activated")
	}
	current, err := LoadPin(root, "fixture")
	if err != nil || current == nil || current.Version != "2.0.0" {
		t.Fatalf("failed activation changed the current pin: %+v, %v", current, err)
	}
	for _, installed := range []InstalledBinary{one, two} {
		cmd := exec.Command(installed.Command)
		cmd.Stdin = strings.NewReader("fixture\n")
		if output, err := cmd.Output(); err != nil || !strings.Contains(string(output), `"protocolVersion":1`) {
			t.Fatalf("existing worker's executable disappeared: %s, %v", output, err)
		}
	}
	restored, err := Rollback(t.Context(), root, "fixture")
	if err != nil || restored.Command != one.Command {
		t.Fatalf("rollback did not restore the prior pin: %+v, %v", restored, err)
	}
	if _, err := apply(stage("2.0.0", 2)); err == nil || !strings.Contains(err.Error(), "reused") {
		t.Fatalf("previously installed version could be substituted: %v", err)
	}
}

func TestUnpackRejectsTraversal(t *testing.T) {
	dir := t.TempDir()
	file, err := os.Create(filepath.Join(dir, "archive"))
	if err != nil {
		t.Fatal(err)
	}
	z := zip.NewWriter(file)
	entry, err := z.Create("../escaped")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.WriteString(entry, "unsafe"); err != nil {
		t.Fatal(err)
	}
	if err := z.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := unpackBinary(file.Name(), filepath.Join(dir, "content"),
		Binary{Archive: "https://publisher.example/agent.zip", Command: "./agent"}); err == nil {
		t.Fatal("archive escaped its installation directory")
	}
	if _, err := os.Stat(filepath.Join(dir, "escaped")); !os.IsNotExist(err) {
		t.Fatal("unexpected output beyond installation directory")
	}
}

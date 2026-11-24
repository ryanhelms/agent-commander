package catalog

import (
	"bytes"
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
	"testing/iotest"

	"agentcommander/internal/catalog/testfixture"
)

func TestOfflinePackageActivationAndRollback(t *testing.T) {
	for _, manager := range []string{"npm", "python"} {
		t.Run(manager, func(t *testing.T) {
			tool := manager
			if manager == "python" {
				tool = "python3"
			}
			if _, err := exec.LookPath(tool); err != nil {
				t.Skipf("%s is required to exercise the real package manager", tool)
			}
			state := t.TempDir()
			key, secret, err := ed25519.GenerateKey(rand.Reader)
			if err != nil {
				t.Fatal(err)
			}
			der, err := x509.MarshalPKIXPublicKey(key)
			if err != nil {
				t.Fatal(err)
			}
			prepare := func(version string, protocol int) (Snapshot, BinaryProof, []byte) {
				t.Helper()
				var bundle []byte
				var command string
				release := Agent{ID: "fixture", Name: "Fixture", Version: version}
				if manager == "npm" {
					script := fmt.Sprintf("#!/usr/bin/env node\nrequire('node:readline').createInterface({input:process.stdin}).once('line', line => console.log(JSON.stringify({jsonrpc:'2.0',id:JSON.parse(line).id,result:{protocolVersion:%d}})));\n", protocol)
					bundle, command = testfixture.NPM(t, version, script)
					release.Distribution.NPX = &Package{Package: "fixture"}
				} else {
					script := fmt.Sprintf("import json\nimport sys\ndef main():\n    msg=json.loads(sys.stdin.readline())\n    print(json.dumps({'jsonrpc':'2.0','id':msg['id'],'result':{'protocolVersion':%d}}))\n", protocol)
					bundle, command = testfixture.Python(t, version, script)
					release.Distribution.UVX = &Package{Package: "fixture"}
				}
				signed := release
				if manager == "npm" {
					signed.Distribution.NPX = &Package{Package: "fixture@" + version}
				} else {
					signed.Distribution.UVX = &Package{Package: "fixture==" + version}
				}
				signed.Distribution.Binary = map[string]Binary{hostPlatform(): {
					Archive: "https://publisher.example/fixture.zip", Command: command, SHA256: fmt.Sprintf("%x", sha256.Sum256(bundle)),
				}}
				manifest, err := json.Marshal(signed)
				if err != nil {
					t.Fatal(err)
				}
				proof := BinaryProof{Manifest: manifest, Signature: ed25519.Sign(secret, manifest), PublicKey: pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})}
				return Snapshot{Source: "https://catalog.example", Version: "1.0.0", HostPlatform: hostPlatform(), Agents: []Agent{release}}, proof, bundle
			}
			stagingDir := filepath.Join(state, "catalog", "staged")
			download := func(snapshot Snapshot, proof BinaryProof, artifact io.Reader) (StagedBinary, error) {
				client := &http.Client{Transport: testTransport(func(*http.Request) (*http.Response, error) {
					return &http.Response{StatusCode: 200, Body: io.NopCloser(artifact)}, nil
				})}
				return stageRelease(t.Context(), client, stagingDir, snapshot, "fixture", snapshot.Agents[0].Version, manager, proof)
			}
			stage := func(version string, protocol int) StagedBinary {
				t.Helper()
				snapshot, proof, bundle := prepare(version, protocol)
				staged, err := download(snapshot, proof, bytes.NewReader(bundle))
				if err != nil {
					t.Fatal(err)
				}
				return staged
			}
			apply := func(staged StagedBinary) InstalledBinary {
				t.Helper()
				installed, err := Activate(t.Context(), state, filepath.Base(staged.Directory), staged.PublisherKeySHA256)
				if err != nil {
					t.Fatal(err)
				}
				name, version, err := exactPackage(manager, installed.PackageSpec)
				if err != nil || installed.PackageManager != manager || name != "fixture" || version != staged.Version {
					t.Fatalf("package identity was not preserved: %+v", installed)
				}
				return installed
			}
			one := apply(stage("1.0.0", 1))
			snapshot, proof, bundle := prepare("2.0.0", 1)
			badProof := proof
			badProof.Signature = append([]byte(nil), proof.Signature...)
			badProof.Signature[0] ^= 1
			if _, err := download(snapshot, badProof, bytes.NewReader(bundle)); err == nil || !strings.Contains(err.Error(), "signature") {
				t.Fatalf("invalid publisher signature was accepted: %v", err)
			}
			if _, err := download(snapshot, proof, strings.NewReader("different bytes")); err == nil || !strings.Contains(err.Error(), "SHA-256") {
				t.Fatalf("tampered package bundle was accepted: %v", err)
			}
			interrupted := io.MultiReader(bytes.NewReader(bundle[:len(bundle)/2]), iotest.ErrReader(context.Canceled))
			if _, err := download(snapshot, proof, interrupted); err == nil || !strings.Contains(err.Error(), "canceled") {
				t.Fatalf("interrupted staging was accepted: %v", err)
			}
			if entries, err := os.ReadDir(stagingDir); err != nil || len(entries) != 1 {
				t.Fatalf("a rejected update left a staged release: %v, %v", entries, err)
			}
			registry, err := json.Marshal(snapshot)
			if err != nil {
				t.Fatal(err)
			}
			responses := map[string][]byte{
				snapshot.Source: registry, "https://publisher.example/entry": proof.Manifest,
				"https://publisher.example/signature": proof.Signature, "https://publisher.example/fixture.zip": bundle,
			}
			client := &http.Client{Transport: testTransport(func(req *http.Request) (*http.Response, error) {
				body, ok := responses[req.URL.String()]
				if !ok {
					t.Fatalf("unexpected update request: %s", req.URL)
				}
				return &http.Response{StatusCode: 200, Request: req, Body: io.NopCloser(bytes.NewReader(body))}, nil
			})}
			_, alternate := binaryFixture(t, "")
			if err := SetUpdateSource(t.Context(), state, "fixture", "https://publisher.example/entry", "https://publisher.example/signature", alternate.PublicKey); err == nil {
				t.Fatal("configured a different key for the pinned publisher")
			}
			if err := SetUpdateSource(t.Context(), state, "fixture", "https://publisher.example/entry", "https://publisher.example/signature", proof.PublicKey); err != nil {
				t.Fatal(err)
			}
			if got, err := RefreshNotices(state); err != nil || len(got) != 0 {
				t.Fatalf("unexpected notice before a refresh: %+v, %v", got, err)
			}
			update, err := refresh(t.Context(), client, client, state, "fixture")
			if err != nil || update == nil || update.Version != "2.0.0" || update.PackageManager != manager {
				t.Fatalf("refresh lost the pinned package distribution: %+v, %v", update, err)
			}
			next := update.StagedBinary
			wantNotice := Notice{AdapterID: "fixture", CurrentVersion: "1.0.0", AvailableVersion: "2.0.0", ManifestSHA256: next.ManifestSHA256}
			if got, err := RefreshNotices(state); err != nil || len(got) != 1 || got[0] != wantNotice {
				t.Fatalf("wrong cockpit notice for %s: %+v, %v", manager, got, err)
			}
			notices, err := Updates(state)
			if err != nil || len(notices) != 1 || notices[0].CurrentVersion != "1.0.0" || notices[0].Stage != filepath.Base(next.Directory) {
				t.Fatalf("wrong verified update notice: %+v, %v", notices, err)
			}
			if _, err := Activate(t.Context(), state, filepath.Base(next.Directory), strings.Repeat("0", 64)); err == nil {
				t.Fatal("activated an update without the trusted publisher fingerprint")
			}
			activateCtx, cancelActivation := context.WithCancel(t.Context())
			defer cancelActivation()
			if _, err := activate(activateCtx, state, filepath.Base(next.Directory), next.PublisherKeySHA256,
				func(ctx context.Context, installed InstalledBinary) error {
					if err := probeACP(ctx, installed); err != nil {
						return err
					}
					cancelActivation()
					return nil
				}); !errors.Is(err, context.Canceled) {
				t.Fatalf("package activation disregarded cancellation before pinning: %v", err)
			}
			current, err := LoadPin(state, "fixture")
			if err != nil || current == nil || current.Command != one.Command {
				t.Fatalf("package cancellation changed the pin: %+v, %v", current, err)
			}
			if entries, err := os.ReadDir(filepath.Join(state, "catalog", "installed")); err != nil || len(entries) != 1 {
				t.Fatalf("package cancellation left a partial installation: %v, %v", entries, err)
			}
			two := apply(next)
			if got, err := RefreshNotices(state); err != nil || len(got) != 0 {
				t.Fatalf("applied release is still advertised: %+v, %v", got, err)
			}
			changed := stage("2.0.0", 2)
			if _, err := Activate(t.Context(), state, filepath.Base(changed.Directory), changed.PublisherKeySHA256); err == nil ||
				!strings.Contains(err.Error(), "reused") {
				t.Fatalf("replacing the bytes of an installed version was accepted: %v", err)
			}
			incompatible := stage("3.0.0", 2)
			if _, err := Activate(t.Context(), state, filepath.Base(incompatible.Directory), incompatible.PublisherKeySHA256); err == nil ||
				!strings.Contains(err.Error(), "ACP compatibility check") {
				t.Fatalf("incompatible package activated: %v", err)
			}
			restored, err := Rollback(t.Context(), state, "fixture")
			if err != nil || restored.Command != one.Command || one.Command == two.Command {
				t.Fatalf("rollback did not restore the prior release: %+v, %v", restored, err)
			}
			for _, installed := range []InstalledBinary{one, two} {
				if err := probeACP(t.Context(), installed); err != nil {
					t.Fatalf("installing or rolling back removed version %s: %v", installed.Version, err)
				}
			}
		})
	}
}

func TestMatchPackageRelease(t *testing.T) {
	for _, tc := range []struct {
		manager, published, signed string
		want                       bool
	}{
		{"npm", "@scope/adapter", "@scope/adapter@2.0.0", true},
		{"npm", "@scope/adapter@2.0.0", "@scope/adapter@2.0.0", true},
		{"npm", "@scope/adapter@1.0.0", "@scope/adapter@2.0.0", false},
		{"npm", "@scope/adapter@latest", "@scope/adapter@2.0.0", false},
		{"npm", "@scope/adapter@2.0.x", "@scope/adapter@2.0.0", false},
		{"npm", "@scope/adapter", "@scope/adapter@2.0.0-preview.1", true},
		{"npm", "@scope/adapter", "@other/adapter@2.0.0", false},
		{"npm", "@scope/adapter", "@scope/adapter", false},
		{"python", "Fixture_Adapter", "fixture-adapter==2.0.0", true},
		{"python", "Fixture.Adapter@2.0.0", "fixture-adapter==2.0.0", true},
		{"python", "fixture-adapter>=2.0.0", "fixture-adapter==2.0.0", false},
		{"python", "different", "fixture-adapter==2.0.0", false},
	} {
		t.Run(tc.manager+"/"+tc.published+" with "+tc.signed, func(t *testing.T) {
			if got := matchPackageRelease(tc.manager, tc.published, tc.signed); got != tc.want {
				t.Fatalf("package match = %t, want %t", got, tc.want)
			}
		})
	}
}

func TestPackageLocksRejectRemoteOrUnpinnedInputs(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "package-lock.json"), []byte(`{
		"lockfileVersion":3,"packages":{"node_modules/fixture":{
			"version":"1.0.0","resolved":"https://example.test/fixture.tgz","integrity":"sha512-test"
		}}
	}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := verifyNPMLock(dir, "fixture", "1.0.0"); err == nil {
		t.Fatal("npm lockfile allowed a remote dependency source")
	}
	if err := os.WriteFile(filepath.Join(dir, "requirements.txt"), []byte("fixture @ https://example.test/fixture.whl\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := verifyPythonLock(dir, "fixture", "1.0.0"); err == nil {
		t.Fatal("Python lockfile allowed a remote or unhashed dependency")
	}
	for _, spec := range []string{"fixture", "fixture@latest", "fixture@^1.0.0", "fixture@1", "fixture@1.2", "fixture@1.2.x", "fixture@1.2.0-preview.01"} {
		if _, _, err := exactPackage("npm", spec); err == nil {
			t.Fatalf("accepted an unpinned npm distribution %q", spec)
		}
	}
}

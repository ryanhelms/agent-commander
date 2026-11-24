// Package testfixture builds offline ACP installations for catalog and worker integration tests.
package testfixture

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"fmt"
	"io"
	"testing"
)

func fixtureZIP(t *testing.T, files map[string][]byte) []byte {
	t.Helper()
	var out bytes.Buffer
	writer := zip.NewWriter(&out)
	for name, value := range files {
		entry, err := writer.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := entry.Write(value); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func NPM(t *testing.T, version, script string) ([]byte, string) {
	t.Helper()
	var artifact bytes.Buffer
	compressor := gzip.NewWriter(&artifact)
	writer := tar.NewWriter(compressor)
	for name, value := range map[string]string{
		"package/package.json": fmt.Sprintf(`{"name":"fixture","version":%q,"bin":{"fixture":"cli.cjs"},"scripts":{"install":"exit 9"}}`, version),
		"package/cli.cjs":      script,
	} {
		if err := writer.WriteHeader(&tar.Header{Name: name, Mode: 0755, Size: int64(len(value))}); err != nil {
			t.Fatal(err)
		}
		if _, err := io.WriteString(writer, value); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := compressor.Close(); err != nil {
		t.Fatal(err)
	}
	hash := sha512.Sum512(artifact.Bytes())
	integrity := "sha512-" + base64.StdEncoding.EncodeToString(hash[:])
	return fixtureZIP(t, map[string][]byte{
		"packages/fixture.tgz": artifact.Bytes(),
		"package.json":         []byte(`{"name":"fixture-install","version":"1.0.0","dependencies":{"fixture":"file:packages/fixture.tgz"}}`),
		"package-lock.json":    fmt.Appendf(nil, `{"name":"fixture-install","version":"1.0.0","lockfileVersion":3,"packages":{"":{"dependencies":{"fixture":"file:packages/fixture.tgz"}},"node_modules/fixture":{"version":%q,"resolved":"file:packages/fixture.tgz","integrity":%q,"bin":{"fixture":"cli.cjs"}}}}`, version, integrity),
	}), "node_modules/.bin/fixture"
}

func Python(t *testing.T, version, script string) ([]byte, string) {
	t.Helper()
	dist := "fixture-" + version + ".dist-info/"
	wheel := fixtureZIP(t, map[string][]byte{
		"fixture.py":              []byte(script),
		dist + "METADATA":         fmt.Appendf(nil, "Metadata-Version: 2.1\nName: fixture\nVersion: %s\n", version),
		dist + "WHEEL":            []byte("Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n"),
		dist + "entry_points.txt": []byte("[console_scripts]\nfixture = fixture:main\n"),
		dist + "RECORD":           []byte(""),
	})
	return fixtureZIP(t, map[string][]byte{
		"wheels/fixture-" + version + "-py3-none-any.whl": wheel,
		"requirements.txt": fmt.Appendf(nil, "fixture==%s --hash=sha256:%x\n", version, sha256.Sum256(wheel)),
	}), "venv/bin/fixture"
}

package hostmode

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
)

func TestHostCertificates(t *testing.T) {
	dir := t.TempDir()
	names := []string{"relay.example.test", "other.example.test", "127.0.0.1", "2001:db8::1"}
	server, err := EnsureTLS(dir, names)
	if err != nil {
		t.Fatal(err)
	}
	ca, err := readCA(dir)
	if err != nil {
		t.Fatal(err)
	}
	pub, ok := ca.PublicKey.(*ecdsa.PublicKey)
	if !ca.IsCA || !ok || pub.Curve != elliptic.P256() {
		t.Fatal("expected a P-256 CA")
	}
	roots := x509.NewCertPool()
	roots.AddCert(ca)
	for _, name := range names {
		if _, err = server.Leaf.Verify(x509.VerifyOptions{DNSName: name, Roots: roots}); err != nil {
			t.Fatalf("server certificate for %s: %v", name, err)
		}
	}
	tlsDir := filepath.Join(dir, "tls")
	checkMode(t, tlsDir, 0700)
	checkMode(t, filepath.Join(tlsDir, "ca-key.pem"), 0600)
	checkMode(t, filepath.Join(tlsDir, "server-key.pem"), 0600)
	digest := sha256.Sum256(ca.RawSubjectPublicKeyInfo)
	want := "sha256/" + base64.StdEncoding.EncodeToString(digest[:])
	got, err := CAPin(dir)
	if err != nil || got != want {
		t.Fatalf("CA pin = %q (%v), want %q", got, err, want)
	}
	reopened, err := EnsureTLS(dir, names)
	if err != nil || !bytes.Equal(reopened.Certificate[0], server.Certificate[0]) {
		t.Fatalf("certificate reuse failed: %v", err)
	}
	renewed, err := EnsureTLS(dir, append(names, "added.example.test"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = renewed.Leaf.Verify(x509.VerifyOptions{DNSName: "added.example.test", Roots: roots}); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(renewed.Leaf.RawSubjectPublicKeyInfo, server.Leaf.RawSubjectPublicKeyInfo) {
		t.Fatal("adding a SAN changed the pinned leaf key")
	}
	if err := os.Remove(filepath.Join(tlsDir, "server-key.pem")); err != nil {
		t.Fatal(err)
	}
	if _, err = EnsureTLS(dir, names); err == nil {
		t.Fatal("missing key replaced an existing identity")
	}
}

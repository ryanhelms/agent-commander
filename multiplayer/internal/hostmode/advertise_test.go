package hostmode

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"math/big"
	"net"
	"strings"
	"testing"
	"time"
)

func testCert(t *testing.T) (tls.Certificate, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "relay"},
		NotBefore: time.Now(), NotAfter: time.Now().Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, _ := x509.ParseCertificate(der)
	sum := sha256.Sum256(leaf.RawSubjectPublicKeyInfo)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, "sha256/" + base64.StdEncoding.EncodeToString(sum[:])
}

func TestBonjourService(t *testing.T) {
	cert, pin := testCert(t)
	cfg := Config{Name: "Nick's\x00 Relay"}
	s, skip := BonjourService(cfg, cert, &net.TCPAddr{IP: net.IPv6unspecified, Port: 8443})
	if skip != "" {
		t.Fatal(skip)
	}
	if s.Name != "Nick's Relay" || s.Port != 8443 || s.TXT["pin"] != pin || s.TXT["v"] != "1" || s.TXT["mode"] != "host" || s.TXT["name"] != s.Name {
		t.Fatalf("service: %+v", s)
	}
	if s, skip = BonjourService(cfg, cert, &net.TCPAddr{IP: net.ParseIP("192.168.8.155"), Port: 443}); skip != "" || s.Port != 443 {
		t.Fatalf("LAN address: %+v %q", s, skip)
	}
	for _, ip := range []string{"100.64.0.7", "fd7a:115c:a1e0::7", "127.0.0.1", "::1"} {
		if _, skip := BonjourService(cfg, cert, &net.TCPAddr{IP: net.ParseIP(ip), Port: 443}); skip == "" {
			t.Errorf("%s should not advertise", ip)
		}
	}
	cfg.NoAdvertise = true
	if _, skip := BonjourService(cfg, cert, &net.TCPAddr{Port: 443}); !strings.Contains(skip, "turned off") {
		t.Fatalf("disabled: %q", skip)
	}
}

func TestSetAdvertise(t *testing.T) {
	dir := t.TempDir()
	cfg := Config{
		Name: "Relay", Listen: ":8443", Hostnames: []string{"relay.example.test"},
		Issuer: "https://issuer.example.test", ClientID: "commander", Admins: []string{"admin@example.test"},
	}
	if err := InitConfig(dir, cfg); err != nil {
		t.Fatal(err)
	}
	if err := SetAdvertise(dir, false); err != nil {
		t.Fatal(err)
	}
	got, err := ReadConfig(dir)
	if err != nil || !got.NoAdvertise || got.Name != "Relay" {
		t.Fatalf("off: %+v %v", got, err)
	}
	if err = SetAdvertise(dir, true); err != nil {
		t.Fatal(err)
	}
	if got, _ = ReadConfig(dir); got.NoAdvertise {
		t.Fatal("still off")
	}
	for in, want := range map[string]bool{"on": true, "off": false} {
		if v, err := ParseOnOff(in); err != nil || v != want {
			t.Fatalf("ParseOnOff(%q) = %v, %v", in, v, err)
		}
	}
	if _, err := ParseOnOff("maybe"); err == nil {
		t.Fatal("accepted maybe")
	}
}

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
	"encoding/pem"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

func newKey(path string) (*ecdsa.PrivateKey, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	raw, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return nil, err
	}
	return key, os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: raw}), 0600)
}

func issueLeaf(dir string, names []string, ca *x509.Certificate, caKey, serverKey *ecdsa.PrivateKey) error {
	now := time.Now()
	expiry := now.AddDate(1, 0, 0)
	if ca.NotAfter.Before(expiry) {
		expiry = ca.NotAfter
	}
	leaf := &x509.Certificate{
		Subject:   pkix.Name{CommonName: "Agent Commander relay"},
		NotBefore: now.Add(-5 * time.Minute), NotAfter: expiry,
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	for _, name := range names {
		if ip := net.ParseIP(name); ip != nil {
			leaf.IPAddresses = append(leaf.IPAddresses, ip)
		} else {
			leaf.DNSNames = append(leaf.DNSNames, name)
		}
	}
	raw, err := x509.CreateCertificate(rand.Reader, leaf, ca, &serverKey.PublicKey, caKey)
	if err != nil {
		return err
	}
	return publishFile(filepath.Join(dir, "server.pem"), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: raw}), true)
}

func createTLS(dir string, names []string) error {
	// Publish both key pairs together. If another process wins the rename, use its identity.
	staging, err := os.MkdirTemp(dir, ".tls-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(staging)
	caKey, err := newKey(filepath.Join(staging, "ca-key.pem"))
	if err != nil {
		return err
	}
	now := time.Now()
	ca := &x509.Certificate{
		Subject:   pkix.Name{CommonName: "Agent Commander relay CA"},
		NotBefore: now.Add(-5 * time.Minute), NotAfter: now.AddDate(10, 0, 0),
		KeyUsage: x509.KeyUsageCertSign, BasicConstraintsValid: true, IsCA: true, MaxPathLenZero: true,
	}
	raw, err := x509.CreateCertificate(rand.Reader, ca, ca, &caKey.PublicKey, caKey)
	if err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(staging, "ca.pem"), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: raw}), 0600); err != nil {
		return err
	}
	ca, err = x509.ParseCertificate(raw)
	if err != nil {
		return err
	}
	serverKey, err := newKey(filepath.Join(staging, "server-key.pem"))
	if err != nil {
		return err
	}
	if err = issueLeaf(staging, names, ca, caKey, serverKey); err != nil {
		return err
	}
	err = os.Rename(staging, filepath.Join(dir, "tls"))
	if errors.Is(err, syscall.ENOTEMPTY) || errors.Is(err, os.ErrExist) {
		return nil
	}
	return err
}

func readCA(dir string) (*x509.Certificate, error) {
	raw, err := os.ReadFile(filepath.Join(dir, "tls", "ca.pem"))
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(raw)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, errors.New("invalid host CA certificate")
	}
	return x509.ParseCertificate(block.Bytes)
}

func CAPin(dir string) (string, error) {
	ca, err := readCA(dir)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(ca.RawSubjectPublicKeyInfo)
	return "sha256/" + base64.StdEncoding.EncodeToString(digest[:]), nil
}

// ServerPin is the SPKI pin of the server certificate. Agent Commander shows
// this value when a person adds the relay, and the leaf key survives renewal.
func ServerPin(dir string) (string, error) {
	raw, err := os.ReadFile(filepath.Join(dir, "tls", "server.pem"))
	if err != nil {
		return "", err
	}
	block, _ := pem.Decode(raw)
	if block == nil || block.Type != "CERTIFICATE" {
		return "", errors.New("invalid host server certificate")
	}
	leaf, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(leaf.RawSubjectPublicKeyInfo)
	return "sha256/" + base64.StdEncoding.EncodeToString(digest[:]), nil
}

// EnsureTLS preserves the CA and leaf keys across restarts, including SAN changes.
func EnsureTLS(dir string, names []string) (tls.Certificate, error) {
	tlsDir := filepath.Join(dir, "tls")
	if _, err := os.Stat(tlsDir); errors.Is(err, os.ErrNotExist) {
		if err := createTLS(dir, names); err != nil {
			return tls.Certificate{}, err
		}
	} else if err != nil {
		return tls.Certificate{}, err
	}
	ca, err := readCA(dir)
	if err != nil {
		return tls.Certificate{}, err
	}
	now := time.Now()
	if now.Before(ca.NotBefore) || !now.Before(ca.NotAfter) {
		return tls.Certificate{}, errors.New("host CA is outside its validity period")
	}
	certFile := filepath.Join(tlsDir, "server.pem")
	keyFile := filepath.Join(tlsDir, "server-key.pem")
	server, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return tls.Certificate{}, err
	}
	leaf, err := x509.ParseCertificate(server.Certificate[0])
	if err != nil {
		return tls.Certificate{}, err
	}
	if err := leaf.CheckSignatureFrom(ca); err != nil {
		return tls.Certificate{}, fmt.Errorf("host certificate signature: %w", err)
	}
	renew := !now.Before(leaf.NotAfter)
	for _, name := range names {
		renew = renew || leaf.VerifyHostname(name) != nil
	}
	if renew {
		signer, err := tls.LoadX509KeyPair(filepath.Join(tlsDir, "ca.pem"), filepath.Join(tlsDir, "ca-key.pem"))
		if err != nil {
			return tls.Certificate{}, err
		}
		caKey, caOK := signer.PrivateKey.(*ecdsa.PrivateKey)
		serverKey, leafOK := server.PrivateKey.(*ecdsa.PrivateKey)
		if !caOK || !leafOK {
			return tls.Certificate{}, errors.New("host certificates require ECDSA keys")
		}
		if err = issueLeaf(tlsDir, names, ca, caKey, serverKey); err != nil {
			return tls.Certificate{}, err
		}
		server, err = tls.LoadX509KeyPair(certFile, keyFile)
		if err != nil {
			return tls.Certificate{}, err
		}
		leaf, err = x509.ParseCertificate(server.Certificate[0])
		if err != nil {
			return tls.Certificate{}, err
		}
	}
	server.Leaf = leaf
	server.Certificate = append(server.Certificate, ca.Raw)
	return server, nil
}

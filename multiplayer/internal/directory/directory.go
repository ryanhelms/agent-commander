// Package directory is the opt-in public list of Commander relays, and the
// registrar a relay uses to appear in it. A relay signs each registration with
// its own TLS key. The directory dials the relay's public URL itself, checks
// that the certificate matches the registered pin and that the pin's key made
// the signature, then takes the listing from the relay's /v1/info. A listing
// therefore proves the registrant controls the key that answers at that URL.
// The directory never sees accounts, members, payloads or device keys.
// See design/COMMANDER-NETWORK-DISCOVERY.md, "Public directory".
package directory

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	// DefaultURL is the public directory Commander uses unless configured otherwise.
	DefaultURL = "https://directory.bytedesk.ai"

	HeartbeatEvery = 5 * time.Minute
	VisibleFor     = 15 * time.Minute
	KeptFor        = 7 * 24 * time.Hour
	clockSkew      = 5 * time.Minute
	payloadPrefix  = "agent-commander-directory/v1"
)

// Registration is what a relay signs to be listed or removed.
type Registration struct {
	Action    string `json:"action"` // "register" or "remove"
	URL       string `json:"url"`
	Pin       string `json:"pin"`
	Timestamp int64  `json:"timestamp"`
}

// Signed is a registration with its signature by the relay's TLS key.
type Signed struct {
	Registration
	Algorithm string `json:"alg"`
	Signature string `json:"sig"`
}

// Listing is one relay as the directory shows it. Every field is already
// public at the relay's /v1/info, apart from when it was last confirmed.
type Listing struct {
	URL          string    `json:"url"`
	Name         string    `json:"name"`
	Pin          string    `json:"pin"`
	Membership   string    `json:"membership"`
	Issuer       string    `json:"issuer"`
	Mode         string    `json:"mode"`
	Version      string    `json:"version"`
	RegisteredAt time.Time `json:"registeredAt"`
	LastSeen     time.Time `json:"lastSeen"`
}

func (r Registration) payload() []byte {
	return []byte(strings.Join([]string{payloadPrefix, r.Action, r.URL, r.Pin, strconv.FormatInt(r.Timestamp, 10)}, "\n"))
}

// SPKIPin is "sha256/<base64>" of a certificate's SubjectPublicKeyInfo, the
// pin format devices use.
func SPKIPin(c *x509.Certificate) string {
	sum := sha256.Sum256(c.RawSubjectPublicKeyInfo)
	return "sha256/" + base64.StdEncoding.EncodeToString(sum[:])
}

// Sign signs r with the relay's certificate key.
func Sign(r Registration, cert tls.Certificate) (Signed, error) {
	signer, ok := cert.PrivateKey.(crypto.Signer)
	if !ok || len(cert.Certificate) == 0 {
		return Signed{}, errors.New("directory: the relay certificate has no usable key")
	}
	payload := r.payload()
	sum := sha256.Sum256(payload)
	var sig []byte
	var alg string
	var err error
	switch signer.Public().(type) {
	case *ecdsa.PublicKey:
		alg = "ES256"
		sig, err = signer.Sign(rand.Reader, sum[:], crypto.SHA256)
	case *rsa.PublicKey:
		alg = "RS256"
		sig, err = signer.Sign(rand.Reader, sum[:], crypto.SHA256)
	case ed25519.PublicKey:
		alg = "EdDSA"
		sig, err = signer.Sign(rand.Reader, payload, crypto.Hash(0))
	default:
		return Signed{}, errors.New("directory: unsupported relay key type")
	}
	if err != nil {
		return Signed{}, err
	}
	return Signed{Registration: r, Algorithm: alg, Signature: base64.StdEncoding.EncodeToString(sig)}, nil
}

// Verify checks that leaf's key made the signature on s.
func Verify(s Signed, leaf *x509.Certificate) error {
	sig, err := base64.StdEncoding.DecodeString(s.Signature)
	if err != nil || len(sig) == 0 || len(sig) > 1024 {
		return errors.New("directory: malformed signature")
	}
	var algo x509.SignatureAlgorithm
	switch s.Algorithm {
	case "ES256":
		algo = x509.ECDSAWithSHA256
	case "RS256":
		algo = x509.SHA256WithRSA
	case "EdDSA":
		algo = x509.PureEd25519
	default:
		return errors.New("directory: unsupported signature algorithm")
	}
	if err := leaf.CheckSignature(algo, s.payload(), sig); err != nil {
		return errors.New("directory: the signature does not match the relay's key")
	}
	return nil
}

// NormalizeURL turns a relay's public address into an https origin.
func NormalizeURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || strings.Trim(u.Path, "/") != "" {
		return "", errors.New("expected an https:// origin")
	}
	host := strings.ToLower(u.Host)
	if u.Port() == "443" {
		host = strings.ToLower(u.Hostname())
		if strings.Contains(host, ":") {
			host = "[" + host + "]"
		}
	}
	return "https://" + host, nil
}

// hostPort splits a normalized origin into host and port.
func hostPort(origin string) (string, string) {
	u, _ := url.Parse(origin)
	port := u.Port()
	if port == "" {
		port = "443"
	}
	return u.Hostname(), port
}

var cgnat = net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}

// PublicIP reports whether ip is a globally routable unicast address.
func PublicIP(ip net.IP) bool {
	return ip.IsGlobalUnicast() && !ip.IsPrivate() && !ip.IsLoopback() && !ip.IsLinkLocalUnicast() &&
		!ip.IsUnspecified() && !cgnat.Contains(ip)
}

// NewRegistration builds a registration for a relay at publicURL with cert.
func NewRegistration(action, publicURL string, cert tls.Certificate, now time.Time) (Registration, error) {
	u, err := NormalizeURL(publicURL)
	if err != nil {
		return Registration{}, fmt.Errorf("public URL: %w", err)
	}
	if len(cert.Certificate) == 0 {
		return Registration{}, errors.New("directory: the relay has no certificate")
	}
	leaf, err := x509.ParseCertificate(cert.Certificate[0])
	if err != nil {
		return Registration{}, err
	}
	return Registration{Action: action, URL: u, Pin: SPKIPin(leaf), Timestamp: now.Unix()}, nil
}

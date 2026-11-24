// Package devicekeys binds a TLS/signing identity to a distinct encryption key.
package devicekeys

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"time"

	jose "github.com/go-jose/go-jose/v4"
)

var raw = base64.RawURLEncoding

// Keys is secret material. Persist it only in the device's protected Store.
type Keys struct {
	Certificate []byte `json:"certificate"`
	Signing     []byte `json:"signing"`
	Encryption  []byte `json:"encryption"`
}
type Public struct {
	User          string `json:"user,omitempty"`
	Device        string `json:"device"`
	SigningKey    string `json:"signing_key"`
	EncryptionKey string `json:"encryption_key"`
	Binding       string `json:"binding"`
}

func Generate() (*Keys, error) {
	s, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	e, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	if err != nil {
		return nil, err
	}
	now := time.Now()
	cert := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "Commander device"}, NotBefore: now.Add(-5 * time.Minute), NotAfter: now.AddDate(2, 0, 0), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}, BasicConstraintsValid: true}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, &s.PublicKey, s)
	if err != nil {
		return nil, err
	}
	sk, err := x509.MarshalECPrivateKey(s)
	if err != nil {
		return nil, err
	}
	ek, err := x509.MarshalECPrivateKey(e)
	if err != nil {
		return nil, err
	}
	return &Keys{der, sk, ek}, nil
}

func (k *Keys) TLSCertificate() (tls.Certificate, error) {
	return tls.X509KeyPair(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: k.Certificate}), pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: k.Signing}))
}
func Fingerprint(pub *ecdsa.PublicKey) (string, error) {
	der, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		return "", err
	}
	h := sha256.Sum256(der)
	return hex.EncodeToString(h[:]), nil
}
func parsePrivate(der []byte) (*ecdsa.PrivateKey, error) {
	k, err := x509.ParseECPrivateKey(der)
	if err != nil || k.Curve != elliptic.P256() {
		return nil, errors.New("invalid P-256 device secret")
	}
	return k, nil
}
func publicText(k *ecdsa.PublicKey) string {
	der, _ := x509.MarshalPKIXPublicKey(k)
	return raw.EncodeToString(der)
}
func publicKey(text string) (*ecdsa.PublicKey, error) {
	if len(text) > 256 {
		return nil, errors.New("invalid public key")
	}
	der, err := raw.DecodeString(text)
	if err != nil {
		return nil, err
	}
	parsed, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, err
	}
	key, ok := parsed.(*ecdsa.PublicKey)
	if !ok || key.Curve != elliptic.P256() || publicText(key) != text {
		return nil, errors.New("invalid P-256 device public key")
	}
	return key, nil
}
func bindingDigest(enc string) [32]byte {
	return sha256.Sum256([]byte("agent-commander.device-encryption.v1\x00" + enc))
}
func (k *Keys) Public() (Public, error) {
	sk, err := parsePrivate(k.Signing)
	if err != nil {
		return Public{}, err
	}
	ek, err := parsePrivate(k.Encryption)
	if err != nil {
		return Public{}, err
	}
	if _, err = k.TLSCertificate(); err != nil {
		return Public{}, err
	}
	id, err := Fingerprint(&sk.PublicKey)
	if err != nil {
		return Public{}, err
	}
	p := Public{Device: id, SigningKey: publicText(&sk.PublicKey), EncryptionKey: publicText(&ek.PublicKey)}
	hash := bindingDigest(p.EncryptionKey)
	sig, err := ecdsa.SignASN1(rand.Reader, sk, hash[:])
	if err != nil {
		return Public{}, err
	}
	p.Binding = raw.EncodeToString(sig)
	return p, p.Validate()
}
func (p Public) Validate() error {
	sk, err := publicKey(p.SigningKey)
	if err != nil {
		return err
	}
	if _, err = publicKey(p.EncryptionKey); err != nil {
		return err
	}
	id, err := Fingerprint(sk)
	if err != nil || id != p.Device || p.SigningKey == p.EncryptionKey || len(p.Binding) > 144 {
		return errors.New("device key binding mismatch")
	}
	sig, err := raw.DecodeString(p.Binding)
	hash := bindingDigest(p.EncryptionKey)
	if err != nil || !ecdsa.VerifyASN1(sk, hash[:], sig) {
		return errors.New("invalid device encryption key attestation")
	}
	return nil
}

// VerifyPin compares device key material with the previously trusted descriptor.
// A rotated key pair must be verified and enrolled as a new device.
func VerifyPin(pinned, candidate Public) error {
	if err := candidate.Validate(); err != nil {
		return err
	}
	if pinned.Device != candidate.Device || pinned.User != candidate.User || pinned.SigningKey != candidate.SigningKey || pinned.EncryptionKey != candidate.EncryptionKey {
		return errors.New("peer key changed; verify the new device fingerprint")
	}
	return nil
}

type Header struct {
	Sender          string    `json:"sender"`
	SenderDevice    string    `json:"sender_device"`
	Recipient       string    `json:"recipient"`
	RecipientDevice string    `json:"recipient_device"`
	Operation       string    `json:"operation"`
	Resource        string    `json:"resource"`
	Action          string    `json:"action"`
	Kind            string    `json:"kind"`
	ExpiresAt       time.Time `json:"expires_at"`
}
type body struct {
	Version int             `json:"version"`
	Header  Header          `json:"header"`
	Payload json.RawMessage `json:"payload"`
}

const MaxEnvelope = 768 << 10
const MaxPayload = 384 << 10

func (h Header) valid() bool {
	for _, s := range []string{h.Sender, h.SenderDevice, h.Recipient, h.RecipientDevice, h.Operation, h.Resource, h.Action} {
		if s == "" || len(s) > 512 {
			return false
		}
	}
	// Expiry controls execution. A device can report an uncertain outcome or
	// authenticate a recorded receipt after that execution window closes.
	return (h.Kind == "request" && h.ExpiresAt.After(time.Now())) ||
		(h.Kind == "result" && !h.ExpiresAt.IsZero())
}
func (k *Keys) Seal(peer Public, h Header, payload json.RawMessage) (json.RawMessage, error) {
	if err := peer.Validate(); err != nil {
		return nil, err
	}
	sk, err := parsePrivate(k.Signing)
	if err != nil {
		return nil, err
	}
	id, err := Fingerprint(&sk.PublicKey)
	if err != nil || !h.valid() || id != h.SenderDevice || peer.Device != h.RecipientDevice || peer.User != h.Recipient || len(payload) > MaxPayload || !json.Valid(payload) {
		return nil, errors.New("invalid sealed operation metadata or payload")
	}
	clear, err := json.Marshal(body{1, h, payload})
	if err != nil {
		return nil, err
	}
	signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.ES256, Key: sk}, nil)
	if err != nil {
		return nil, err
	}
	signed, err := signer.Sign(clear)
	if err != nil {
		return nil, err
	}
	compact, err := signed.CompactSerialize()
	if err != nil {
		return nil, err
	}
	pub, err := publicKey(peer.EncryptionKey)
	if err != nil {
		return nil, err
	}
	enc, err := jose.NewEncrypter(jose.A256GCM, jose.Recipient{Algorithm: jose.ECDH_ES, Key: pub}, nil)
	if err != nil {
		return nil, err
	}
	encrypted, err := enc.Encrypt([]byte(compact))
	if err != nil {
		return nil, err
	}
	wire, err := encrypted.CompactSerialize()
	if err != nil {
		return nil, err
	}
	if len(wire)+2 > MaxEnvelope {
		return nil, errors.New("sealed operation exceeds envelope limit")
	}
	return json.Marshal(wire)
}
func (k *Keys) Open(peer Public, expected Header, envelope json.RawMessage) (json.RawMessage, error) {
	if err := peer.Validate(); err != nil {
		return nil, err
	}
	if !expected.valid() || len(envelope) > MaxEnvelope || peer.Device != expected.SenderDevice || peer.User != expected.Sender {
		return nil, errors.New("invalid expected sender or operation")
	}
	key, err := parsePrivate(k.Signing)
	if err != nil {
		return nil, err
	}
	id, err := Fingerprint(&key.PublicKey)
	if err != nil || id != expected.RecipientDevice {
		return nil, errors.New("wrong recipient device")
	}
	var compact string
	if err = json.Unmarshal(envelope, &compact); err != nil {
		return nil, errors.New("invalid envelope")
	}
	obj, err := jose.ParseEncryptedCompact(compact, []jose.KeyAlgorithm{jose.ECDH_ES}, []jose.ContentEncryption{jose.A256GCM})
	if err != nil {
		return nil, err
	}
	ek, err := parsePrivate(k.Encryption)
	if err != nil {
		return nil, err
	}
	signed, err := obj.Decrypt(ek)
	if err != nil {
		return nil, err
	}
	sig, err := jose.ParseSignedCompact(string(signed), []jose.SignatureAlgorithm{jose.ES256})
	if err != nil {
		return nil, err
	}
	pub, err := publicKey(peer.SigningKey)
	if err != nil {
		return nil, err
	}
	plain, err := sig.Verify(pub)
	if err != nil {
		return nil, err
	}
	var got body
	if err = json.Unmarshal(plain, &got); err != nil {
		return nil, err
	}
	// PostgreSQL represents timestamps at microsecond precision; canonicalize on
	// submission, and compare instants without relying on location/monotonic fields.
	if !got.Header.ExpiresAt.Equal(expected.ExpiresAt) {
		return nil, errors.New("sealed expiry differs from operation")
	}
	got.Header.ExpiresAt = expected.ExpiresAt
	if got.Version != 1 || got.Header != expected || len(got.Payload) > MaxPayload || len(bytes.TrimSpace(got.Payload)) == 0 {
		return nil, fmt.Errorf("sealed content does not match expected operation")
	}
	return got.Payload, nil
}

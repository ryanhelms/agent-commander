package devicekeys

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func mustDevice(t *testing.T, user string) (*Keys, Public) {
	t.Helper()
	k, err := Generate()
	if err != nil {
		t.Fatal(err)
	}
	p, err := k.Public()
	if err != nil {
		t.Fatal(err)
	}
	p.User = user
	return k, p
}
func TestAuthenticatedEncryptionBindsOperationAndRecipient(t *testing.T) {
	a, alice := mustDevice(t, "alice")
	b, bob := mustDevice(t, "bob")
	c, other := mustDevice(t, "other")
	h := Header{Sender: alice.User, SenderDevice: alice.Device, Recipient: bob.User, RecipientDevice: bob.Device, Operation: "child-234", Resource: "docs", Action: "review.v1", Kind: "request", ExpiresAt: time.Now().UTC().Add(time.Hour).Truncate(time.Microsecond)}
	clear := json.RawMessage(`{"text":"private review material"}`)
	envelope, err := a.Seal(bob, h, clear)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(envelope, []byte("private review material")) {
		t.Fatal("wire leaked plaintext")
	}
	got, err := b.Open(alice, h, envelope)
	if err != nil || !bytes.Equal(got, clear) {
		t.Fatalf("round trip: %s %v", got, err)
	}
	for _, change := range []func(*Header){func(p *Header) { p.Action = "write.v1" }, func(p *Header) { p.Resource = "other" }, func(p *Header) { p.Operation = "another" }, func(p *Header) { p.Kind = "result" }, func(p *Header) { p.ExpiresAt = p.ExpiresAt.Add(time.Minute) }, func(p *Header) { p.Sender = "other" }, func(p *Header) { p.RecipientDevice = other.Device }} {
		bad := h
		change(&bad)
		if _, err = b.Open(alice, bad, envelope); err == nil {
			t.Fatal("accepted mismatched signed metadata")
		}
	}
	if _, err = c.Open(alice, h, envelope); err == nil {
		t.Fatal("other recipient opened operation")
	}
	impostor := h
	impostor.Sender = h.Sender
	impostor.SenderDevice = other.Device
	other.User = h.Sender
	if _, err = b.Open(other, impostor, envelope); err == nil {
		t.Fatal("accepted wrong signing key")
	}
	substitute := bob
	substitute.EncryptionKey = other.EncryptionKey
	if _, err = a.Seal(substitute, h, clear); err == nil {
		t.Fatal("accepted unbound encryption key")
	}
	if VerifyPin(alice, other) == nil {
		t.Fatal("silent replacement of trusted key")
	}
	wire := append([]byte(nil), envelope...)
	wire[len(wire)/2] ^= 1
	if _, err = b.Open(alice, h, wire); err == nil {
		t.Fatal("accepted corrupted envelope")
	}
	if _, err = a.Seal(bob, h, json.RawMessage(bytes.Repeat([]byte("x"), MaxPayload+1))); err == nil {
		t.Fatal("accepted oversized input")
	}
}
func TestExplicitDeviceTestStore(t *testing.T) {
	p := filepath.Join(t.TempDir(), "private")
	s, err := Directory(p)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Load(); !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
	if err = s.Save([]byte("secret")); err != nil {
		t.Fatal(err)
	}
	d, err := s.Load()
	if err != nil || string(d) != "secret" {
		t.Fatalf("load: %s %v", d, err)
	}
	if err = s.Delete(); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Load(); !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
	if err = os.Chmod(p, 0755); err != nil {
		t.Fatal(err)
	}
	if _, err = Directory(p); err == nil {
		t.Fatal("accepted unprotected directory")
	}
}

func TestCompletedReceiptCanBeReadAfterExecutionExpiry(t *testing.T) {
	sender, author := mustDevice(t, "sender")
	recipient, peer := mustDevice(t, "recipient")
	h := Header{Sender: author.User, SenderDevice: author.Device, Recipient: peer.User,
		RecipientDevice: peer.Device, Operation: "aged-operation", Resource: "repo",
		Action: "git.head", Kind: "request", ExpiresAt: time.Now().Add(-time.Minute)}
	value := json.RawMessage(`{"head":"recorded"}`)
	if _, err := sender.Seal(peer, h, value); err == nil {
		t.Fatal("expired action request accepted")
	}
	h.Kind = "result"
	wire, err := sender.Seal(peer, h, value)
	if err != nil {
		t.Fatal(err)
	}
	got, err := recipient.Open(author, h, wire)
	if err != nil || !bytes.Equal(got, value) {
		t.Fatalf("could not authenticate completed receipt: %v", err)
	}
}

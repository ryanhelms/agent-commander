package hostmode

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"path/filepath"

	"agentcommander.network/pilot/internal/bonjour"
)

// A host-mode relay advertises itself over Bonjour so Macs on the same LAN,
// or on a VPN that carries multicast, can find it. Advertising is on by
// default and skipped when the relay listens only on a tailnet or loopback
// address, where multicast does not reach. The TXT pin is a hint: clients still
// confirm or verify the key. See design/COMMANDER-NETWORK-DISCOVERY.md.

var (
	tailnetIPv4 = netip.MustParsePrefix("100.64.0.0/10")
	tailnetIPv6 = netip.MustParsePrefix("fd7a:115c:a1e0::/48")
)

// BonjourService describes the advertisement for a relay listening on addr.
// It returns a reason instead when the relay should not advertise.
func BonjourService(cfg Config, cert tls.Certificate, addr net.Addr) (bonjour.Service, string) {
	if cfg.NoAdvertise {
		return bonjour.Service{}, "advertising is turned off"
	}
	tcp, ok := addr.(*net.TCPAddr)
	if !ok || tcp.Port == 0 {
		return bonjour.Service{}, "the listen address has no TCP port"
	}
	if ip, ok := netip.AddrFromSlice(tcp.IP); ok && !ip.IsUnspecified() {
		ip = ip.Unmap()
		switch {
		case ip.IsLoopback():
			return bonjour.Service{}, "the relay listens only on loopback"
		case tailnetIPv4.Contains(ip) || tailnetIPv6.Contains(ip):
			return bonjour.Service{}, "the relay listens only on its tailnet address; tailnet discovery finds it by tag"
		}
	}
	if len(cert.Certificate) == 0 {
		return bonjour.Service{}, "the relay has no certificate"
	}
	leaf, err := x509.ParseCertificate(cert.Certificate[0])
	if err != nil {
		return bonjour.Service{}, "the relay certificate is unreadable"
	}
	sum := sha256.Sum256(leaf.RawSubjectPublicKeyInfo)
	name := bonjour.CleanName(cfg.Name)
	if name == "" {
		name = "Commander relay"
	}
	return bonjour.Service{Name: name, Port: tcp.Port, TXT: map[string]string{
		"v": "1", "name": name, "mode": "host",
		"pin": "sha256/" + base64.StdEncoding.EncodeToString(sum[:]),
	}}, ""
}

// SetAdvertise turns Bonjour advertising on or off for the next start.
func SetAdvertise(dir string, on bool) error {
	cfg, err := ReadConfig(dir)
	if err != nil {
		return err
	}
	cfg.NoAdvertise = !on
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return publishFile(filepath.Join(dir, "host.json"), append(data, '\n'), true)
}

// ParseOnOff reads an on/off flag value.
func ParseOnOff(v string) (bool, error) {
	switch v {
	case "on", "true", "yes":
		return true, nil
	case "off", "false", "no":
		return false, nil
	}
	return false, errors.New(`expected "on" or "off"`)
}

package hostmode

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

// GoogleIssuer is the sign-in provider a first-time host uses unless told otherwise.
const GoogleIssuer = "https://accounts.google.com"

// Setup is what the app sends to set a host up the first time. Every field but Admin may be
// empty: Suggest fills it from this Mac.
type Setup struct {
	Name      string   `json:"name,omitempty"`
	Hostnames []string `json:"hostnames,omitempty"`
	Issuer    string   `json:"issuer,omitempty"`
	ClientID  string   `json:"clientId,omitempty"`
	Admin     string   `json:"admin"`
}

// Suggestion is what this Mac offers for a first-time setup, shown before the person starts.
type Suggestion struct {
	Name      string   `json:"name"`
	Hostnames []string `json:"hostnames"`
	Issuer    string   `json:"issuer"`
	// ClientID is the Google Desktop client this Mac's network helper already signs in with.
	// Empty when the Mac has none, so the app asks for one.
	ClientID string `json:"clientId,omitempty"`
}

// Probe reaches outside the process for what a suggestion needs. Tests replace it.
type Probe struct {
	Hostname     func() (string, error)
	ComputerName func() string
	Tailscale    func() (dnsName string, ips []string)
	// NetworkDir is the network helper's state directory, which holds google-desktop-client.json.
	NetworkDir func() string
}

// SystemProbe reads this Mac.
var SystemProbe = Probe{
	Hostname: os.Hostname,
	ComputerName: func() string {
		out, err := command(2*time.Second, "scutil", "--get", "ComputerName")
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(out))
	},
	Tailscale:  tailscaleSelf,
	NetworkDir: networkDir,
}

func command(timeout time.Duration, name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	return exec.CommandContext(ctx, name, args...).Output()
}

// tailscaleSelf asks the Tailscale client (also the Headscale client) for this Mac's MagicDNS
// name and tailnet addresses. Nothing when it isn't installed or isn't connected.
func tailscaleSelf() (string, []string) {
	for _, bin := range []string{"tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"} {
		out, err := command(3*time.Second, bin, "status", "--json")
		if err != nil {
			continue
		}
		var status struct {
			Self struct {
				DNSName      string
				TailscaleIPs []string
			}
		}
		if json.Unmarshal(out, &status) != nil {
			continue
		}
		return strings.TrimSuffix(status.Self.DNSName, "."), status.Self.TailscaleIPs
	}
	return "", nil
}

func networkDir() string {
	if dir := os.Getenv("COMMANDER_NETWORK_STATE"); dir != "" {
		return dir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".agent-commander", "network")
}

func googleClientID(dir string) string {
	if dir == "" {
		return ""
	}
	data, err := os.ReadFile(filepath.Join(dir, "google-desktop-client.json"))
	if err != nil {
		return ""
	}
	var config struct {
		Installed struct {
			ClientID string `json:"client_id"`
		} `json:"installed"`
	}
	if json.Unmarshal(data, &config) != nil {
		return ""
	}
	return config.Installed.ClientID
}

// Suggest names the host after the Mac and serves every name friends could reach it by: the
// tailnet name first, since status builds the relay's address from the first one, then the LAN
// name, then the tailnet addresses.
func (p Probe) Suggest() Suggestion {
	s := Suggestion{Issuer: GoogleIssuer, Hostnames: []string{}}
	var local string
	if p.Hostname != nil {
		if name, err := p.Hostname(); err == nil {
			local = strings.TrimSuffix(name, ".")
		}
	}
	if p.ComputerName != nil {
		s.Name = p.ComputerName()
	}
	if s.Name == "" {
		s.Name, _, _ = strings.Cut(local, ".")
	}
	if s.Name == "" {
		s.Name = "My relay"
	}
	var dnsName string
	var ips []string
	if p.Tailscale != nil {
		dnsName, ips = p.Tailscale()
		dnsName = strings.TrimSuffix(dnsName, ".")
	}
	if local != "" && !strings.Contains(local, ".") {
		local += ".local"
	}
	for _, name := range append([]string{dnsName, local}, ips...) {
		if name != "" && validHostname(name) && !slices.Contains(s.Hostnames, name) {
			s.Hostnames = append(s.Hostnames, name)
		}
	}
	if len(s.Hostnames) == 0 {
		s.Hostnames = append(s.Hostnames, "localhost")
	}
	if p.NetworkDir != nil {
		s.ClientID = googleClientID(p.NetworkDir())
	}
	return s
}

// Configure writes host.json from a setup, with this Mac's suggestion for each empty field.
// It refuses to replace an existing configuration.
func Configure(dir string, setup Setup, p Probe) error {
	if _, err := os.Stat(filepath.Join(dir, "host.json")); err == nil {
		return errors.New("this relay is already set up")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	admin := strings.TrimSpace(setup.Admin)
	if admin == "" {
		return errors.New("enter your email: you are the relay's first admin")
	}
	suggestion := p.Suggest()
	cfg := Config{
		Name:      strings.TrimSpace(setup.Name),
		Listen:    ":443",
		Hostnames: setup.Hostnames,
		Issuer:    strings.TrimSpace(setup.Issuer),
		ClientID:  strings.TrimSpace(setup.ClientID),
		Admins:    []string{admin},
	}
	if cfg.Name == "" {
		cfg.Name = suggestion.Name
	}
	if len(cfg.Hostnames) == 0 {
		cfg.Hostnames = suggestion.Hostnames
	}
	if cfg.Issuer == "" {
		cfg.Issuer = suggestion.Issuer
	}
	if cfg.ClientID == "" && cfg.Issuer == suggestion.Issuer {
		cfg.ClientID = suggestion.ClientID
	}
	if cfg.ClientID == "" {
		return errors.New("enter the sign-in client ID: this Mac has no Google Desktop client to reuse")
	}
	if err := InitConfig(dir, cfg); err != nil {
		return err
	}
	if p.NetworkDir != nil {
		adoptLocalClientSecret(dir, p.NetworkDir(), cfg.ClientID)
	}
	return nil
}

// ReadSetup decodes one setup from the app.
func ReadSetup(data []byte) (Setup, error) {
	var setup Setup
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&setup); err != nil {
		return setup, errors.New("the setup Commander sent can't be read")
	}
	return setup, nil
}

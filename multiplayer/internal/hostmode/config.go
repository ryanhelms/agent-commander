// Package hostmode owns the private configuration and local services of a hosted relay.
package hostmode

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/mail"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
)

type Config struct {
	Name          string   `json:"name"`
	Listen        string   `json:"listen"`
	Hostnames     []string `json:"hostnames"`
	Issuer        string   `json:"issuer"`
	ClientID      string   `json:"client_id"`
	AllowedEmails []string `json:"allowed_emails"`
	Admins        []string `json:"admins"`
}

// DefaultDir is the host state directory: Application Support on macOS,
// /var/lib for root on Linux and the XDG data directory otherwise.
func DefaultDir() (string, error) {
	if runtime.GOOS == "linux" && os.Geteuid() == 0 {
		return "/var/lib/agent-commander/relay", nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	if runtime.GOOS == "darwin" {
		return filepath.Join(home, "Library", "Application Support", "Agent Commander", "relay"), nil
	}
	data := os.Getenv("XDG_DATA_HOME")
	if !filepath.IsAbs(data) {
		data = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(data, "agent-commander", "relay"), nil
}

var dnsLabel = regexp.MustCompile(`^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$`)

func validHostname(name string) bool {
	if net.ParseIP(name) != nil {
		return true
	}
	name = strings.TrimSuffix(name, ".")
	if len(name) > 253 {
		return false
	}
	for label := range strings.SplitSeq(name, ".") {
		if !dnsLabel.MatchString(label) {
			return false
		}
	}
	return true
}

func (c *Config) validate() error {
	if strings.TrimSpace(c.Name) == "" || len(c.Hostnames) == 0 || strings.TrimSpace(c.ClientID) == "" || len(c.Admins) == 0 {
		return errors.New("host configuration requires a name, hostname, OIDC client ID and admin email")
	}
	if c.Listen == "" {
		c.Listen = ":443"
	}
	if _, _, err := net.SplitHostPort(c.Listen); err != nil {
		return fmt.Errorf("invalid host listen address: %w", err)
	}
	for _, name := range c.Hostnames {
		if !validHostname(name) {
			return fmt.Errorf("invalid hostname or IP address %q", name)
		}
	}
	issuer, err := url.Parse(c.Issuer)
	if err != nil || issuer.Scheme != "https" || issuer.Hostname() == "" || issuer.User != nil || issuer.Fragment != "" {
		return errors.New("host configuration requires an HTTPS OIDC issuer")
	}
	if c.AllowedEmails == nil {
		c.AllowedEmails = []string{}
	}
	for _, email := range slices.Concat(c.AllowedEmails, c.Admins) {
		address, err := mail.ParseAddress(email)
		if err != nil || address.Address != email {
			return fmt.Errorf("invalid email address %q", email)
		}
	}
	return nil
}

func (c Config) PermittedEmails() []string {
	var emails []string
	seen := make(map[string]bool)
	for _, email := range slices.Concat(c.AllowedEmails, c.Admins) {
		key := strings.ToLower(email)
		if !seen[key] {
			seen[key] = true
			emails = append(emails, email)
		}
	}
	return emails
}

func ReadConfig(dir string) (Config, error) {
	var cfg Config
	file, err := os.Open(filepath.Join(dir, "host.json"))
	if err != nil {
		return cfg, err
	}
	defer file.Close()
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&cfg); err != nil {
		return cfg, err
	}
	if decoder.Decode(new(any)) != io.EOF {
		return cfg, errors.New("expected a single host configuration")
	}
	err = cfg.validate()
	return cfg, err
}

func InitConfig(dir string, cfg Config) error {
	if err := cfg.validate(); err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("host path %s must be a directory", dir)
	}
	if info.Mode().Perm() != 0700 {
		if err := os.Chmod(dir, 0700); err != nil {
			return err
		}
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return publishFile(filepath.Join(dir, "host.json"), append(data, '\n'), false)
}

// UpdateConfig adds certificate hostnames and, when listen is set, replaces the
// listen address of an existing configuration. The relay reissues its leaf
// certificate with the same key on the next start, so clients keep their pin.
func UpdateConfig(dir string, hostnames []string, listen string) error {
	cfg, err := ReadConfig(dir)
	if err != nil {
		return err
	}
	for _, name := range hostnames {
		if !slices.ContainsFunc(cfg.Hostnames, func(have string) bool { return strings.EqualFold(have, name) }) {
			cfg.Hostnames = append(cfg.Hostnames, name)
		}
	}
	if listen != "" {
		cfg.Listen = listen
	}
	if err := cfg.validate(); err != nil {
		return err
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return publishFile(filepath.Join(dir, "host.json"), append(data, '\n'), true)
}

// Stage private files on the same volume so readers always see a complete record.
func publishFile(path string, data []byte, replace bool) error {
	file, err := os.CreateTemp(filepath.Dir(path), ".relay-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	_, err = file.Write(data)
	if err = errors.Join(err, file.Close()); err != nil {
		return err
	}
	if replace {
		return os.Rename(file.Name(), path)
	}
	return os.Link(file.Name(), path)
}

// Locations of a relay provisioned as a Linux system service.
const (
	LinuxServiceAccount = "agent-commander"
	LinuxServiceBase    = "/var/lib/agent-commander"
	LinuxServiceDir     = LinuxServiceBase + "/relay"
	LinuxServiceBinary  = "/usr/local/bin/commander-relay"
)

// InitFlags returns the `host init` flags that recreate cfg.
func (c Config) InitFlags() []string {
	var flags []string
	if c.Name != "" {
		flags = append(flags, "--name", c.Name)
	}
	if c.Listen != "" {
		flags = append(flags, "--listen", c.Listen)
	}
	flags = append(flags, "--issuer", c.Issuer, "--client-id", c.ClientID)
	for _, h := range c.Hostnames {
		flags = append(flags, "--hostname", h)
	}
	for _, a := range c.Admins {
		flags = append(flags, "--admin", a)
	}
	for _, e := range c.AllowedEmails {
		flags = append(flags, "--allow-email", e)
	}
	return flags
}

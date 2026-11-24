// Package catalog reads published ACP registry metadata for adapter discovery.
package catalog

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"runtime"
	"strings"
	"time"
)

const DefaultURL = "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json"
const maxRegistryBytes = 8 << 20

type Snapshot struct {
	Source       string  `json:"source"`
	ResolvedURL  string  `json:"resolved_url"`
	SHA256       string  `json:"sha256"`
	Version      string  `json:"version"`
	HostPlatform string  `json:"host_platform"`
	Agents       []Agent `json:"agents"`
}

type Agent struct {
	ID                    string       `json:"id"`
	Name                  string       `json:"name"`
	Version               string       `json:"version"`
	Description           string       `json:"description,omitempty"`
	Repository            string       `json:"repository,omitempty"`
	Website               string       `json:"website,omitempty"`
	Authors               []string     `json:"authors,omitempty"`
	License               string       `json:"license,omitempty"`
	LicenseURL            string       `json:"license_url,omitempty"`
	PublisherVerification string       `json:"publisher_verification"`
	Distribution          Distribution `json:"distribution"`
}

type Distribution struct {
	Binary map[string]Binary `json:"binary,omitempty"`
	NPX    *Package          `json:"npx,omitempty"`
	UVX    *Package          `json:"uvx,omitempty"`
}

type Binary struct {
	Archive string            `json:"archive"`
	SHA256  string            `json:"sha256,omitempty"`
	Command string            `json:"cmd"`
	Args    []string          `json:"args,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
}

type Package struct {
	Package string            `json:"package"`
	Args    []string          `json:"args,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
}

func readURL(address string) (*url.URL, error) {
	target, err := url.Parse(address)
	if err != nil || target.Scheme != "https" || target.Hostname() == "" || target.User != nil || target.Fragment != "" {
		return nil, errors.New("catalog URL must be HTTPS, without credentials or a fragment")
	}
	return target, nil
}

func Read(ctx context.Context, address string) (Snapshot, error) {
	return read(ctx, httpsClient(15*time.Second), address)
}

func httpsClient(timeout time.Duration) *http.Client {
	return &http.Client{Timeout: timeout, CheckRedirect: func(next *http.Request, via []*http.Request) error {
		if len(via) >= 5 {
			return errors.New("too many catalog redirects")
		}
		_, err := readURL(next.URL.String())
		return err
	}}
}

func read(ctx context.Context, client *http.Client, address string) (Snapshot, error) {
	target, err := readURL(address)
	if err != nil {
		return Snapshot{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target.String(), nil)
	if err != nil {
		return Snapshot{}, err
	}
	req.Header.Set("Accept", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return Snapshot{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return Snapshot{}, fmt.Errorf("catalog request returned HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxRegistryBytes+1))
	if err != nil {
		return Snapshot{}, err
	}
	if len(body) > maxRegistryBytes {
		return Snapshot{}, errors.New("ACP registry exceeds 8 MiB")
	}
	return decode(target.String(), resp.Request.URL.String(), body)
}

var registryVersion = regexp.MustCompile(`^1\.[0-9]+\.[0-9]+$`)

func decode(source, resolved string, body []byte) (Snapshot, error) {
	var catalog Snapshot
	if err := json.Unmarshal(body, &catalog); err != nil {
		return Snapshot{}, fmt.Errorf("invalid ACP registry: %w", err)
	}
	if !registryVersion.MatchString(catalog.Version) || catalog.Agents == nil {
		return Snapshot{}, errors.New("expected an ACP registry v1 document with an agents array")
	}
	catalog.Source, catalog.ResolvedURL = source, resolved
	catalog.SHA256 = fmt.Sprintf("%x", sha256.Sum256(body))
	catalog.HostPlatform = hostPlatform()
	seen := make(map[string]bool, len(catalog.Agents))
	for i := range catalog.Agents {
		entry := &catalog.Agents[i]
		if strings.TrimSpace(entry.ID) == "" || strings.TrimSpace(entry.Name) == "" || strings.TrimSpace(entry.Version) == "" {
			return Snapshot{}, fmt.Errorf("ACP registry agent %d requires id, name and version", i)
		}
		if seen[entry.ID] {
			return Snapshot{}, fmt.Errorf("duplicate ACP registry ID %q", entry.ID)
		}
		seen[entry.ID] = true
		entry.PublisherVerification = "unverified"
	}
	return catalog, nil
}

func hostPlatform() string {
	arch := runtime.GOARCH
	switch arch {
	case "arm64":
		arch = "aarch64"
	case "amd64":
		arch = "x86_64"
	}
	return runtime.GOOS + "-" + arch
}

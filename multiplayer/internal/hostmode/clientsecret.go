package hostmode

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// A relay can hold its sign-in provider's installed-app client secret and
// hand it to devices in the pinned enrollment challenge, so no Mac needs a
// hand-copied Google Desktop OAuth file. Google documents installed-app
// secrets as non-confidential; PKCE protects the authorization code. The file
// is read on each challenge, so setting it needs no restart.
// See design/COMMANDER-NETWORK-DISCOVERY.md.

const clientSecretFile = "oauth-client-secret"

// ParseClientSecret reads either a Google Desktop OAuth JSON file or a bare
// secret. A JSON file must name clientID when it names a client at all.
func ParseClientSecret(data []byte, clientID string) (string, error) {
	const limit = 16 << 10
	if len(data) > limit {
		return "", errors.New("the client secret file is too large")
	}
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) > 0 && trimmed[0] == '{' {
		var file struct {
			Installed *struct {
				ClientID     string `json:"client_id"`
				ClientSecret string `json:"client_secret"`
			} `json:"installed"`
		}
		if err := json.Unmarshal(trimmed, &file); err != nil || file.Installed == nil {
			return "", errors.New(`expected a Google Desktop OAuth file with an "installed" client`)
		}
		if file.Installed.ClientID != "" && file.Installed.ClientID != clientID {
			return "", errors.New("the OAuth file is for a different client ID than this relay's")
		}
		trimmed = []byte(file.Installed.ClientSecret)
	}
	secret := string(trimmed)
	if secret == "" || len(secret) > 512 || strings.ContainsFunc(secret, func(r rune) bool { return r <= ' ' || r == 0x7f }) {
		return "", errors.New("the client secret is empty or malformed")
	}
	return secret, nil
}

// SetClientSecret stores the relay's installed-app client secret from r.
func SetClientSecret(dir string, r io.Reader) error {
	cfg, err := ReadConfig(dir)
	if err != nil {
		return err
	}
	data, err := io.ReadAll(io.LimitReader(r, 16<<10+1))
	if err != nil {
		return err
	}
	secret, err := ParseClientSecret(data, cfg.ClientID)
	if err != nil {
		return err
	}
	return publishFile(filepath.Join(dir, clientSecretFile), []byte(secret+"\n"), true)
}

// ClearClientSecret stops the relay handing out a client secret.
func ClearClientSecret(dir string) error {
	err := os.Remove(filepath.Join(dir, clientSecretFile))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// ClientSecret returns the stored secret, or "" when none is set or the file
// cannot be read.
func ClientSecret(dir string) string {
	data, err := os.ReadFile(filepath.Join(dir, clientSecretFile))
	if err != nil {
		return ""
	}
	secret, err := ParseClientSecret(data, "")
	if err != nil {
		return ""
	}
	return secret
}

// adoptLocalClientSecret copies the secret from this Mac's own Google Desktop
// OAuth file when it is for the relay's client, so a relay hosted on a Mac
// that already signs in needs no further setup.
func adoptLocalClientSecret(dir, networkDir, clientID string) {
	if networkDir == "" || clientID == "" {
		return
	}
	f, err := os.Open(filepath.Join(networkDir, "google-desktop-client.json"))
	if err != nil {
		return
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 16<<10+1))
	if err != nil || !bytes.Contains(data, []byte(`"client_id"`)) {
		return
	}
	if secret, err := ParseClientSecret(data, clientID); err == nil {
		_ = publishFile(filepath.Join(dir, clientSecretFile), []byte(secret+"\n"), true)
	}
}

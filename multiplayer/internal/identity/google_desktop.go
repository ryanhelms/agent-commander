package identity

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/url"
	"os"
	"strings"
	"syscall"
)

const googleTokenEndpoint = "https://oauth2.googleapis.com/token"

// googleDesktopSecret picks the installed-app secret for clientID: a matching
// local Desktop OAuth file when this Mac has one, otherwise the secret the
// relay supplied in its pinned enrollment challenge.
func (c Client) googleDesktopSecret(clientID, endpoint, relaySecret string) (string, error) {
	if endpoint != googleTokenEndpoint {
		u, err := url.Parse(endpoint)
		if !c.AllowLoopbackHTTP || err != nil || u.Scheme != "http" || !net.ParseIP(u.Hostname()).IsLoopback() {
			return "", errors.New("Google discovery supplied an unexpected token endpoint")
		}
	}
	secret, err := c.localGoogleDesktopSecret(clientID)
	if err != nil && validRelaySecret(relaySecret) {
		return relaySecret, nil
	}
	return secret, err
}

func validRelaySecret(s string) bool {
	return s != "" && len(s) <= 512 && !strings.ContainsFunc(s, func(r rune) bool { return r <= ' ' || r == 0x7f })
}

func (c Client) localGoogleDesktopSecret(clientID string) (string, error) {
	file, err := os.OpenFile(c.GoogleDesktopConfig, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return "", errors.New("Google sign-in requires the pilot operator to provision this Mac with Desktop OAuth credentials")
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return "", errors.New("Google Desktop OAuth configuration must be a private regular file")
	}
	const limit = 16 << 10
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	var config struct {
		Installed struct {
			ClientID     string `json:"client_id"`
			ClientSecret string `json:"client_secret"`
		} `json:"installed"`
	}
	if err != nil || len(data) > limit || json.Unmarshal(data, &config) != nil || config.Installed.ClientSecret == "" {
		return "", errors.New("Google Desktop OAuth configuration is invalid")
	}
	if config.Installed.ClientID != clientID {
		return "", errors.New("Google Desktop OAuth configuration does not match the relay's client ID")
	}
	return config.Installed.ClientSecret, nil
}

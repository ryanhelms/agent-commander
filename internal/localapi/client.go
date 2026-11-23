// Package localapi connects Commander clients to the per-user Unix socket.
package localapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type Paths struct {
	State  string
	Socket string
}

func Config() (Paths, error) {
	state := os.Getenv("AGENT_COMMANDER_HOME")
	if state == "" {
		base, err := os.UserConfigDir()
		if err != nil {
			return Paths{}, err
		}
		state = filepath.Join(base, "Agent Commander")
	}
	state, err := filepath.Abs(state)
	if err != nil {
		return Paths{}, err
	}
	socket := os.Getenv("AGENT_COMMANDER_SOCKET")
	if socket == "" {
		socket = filepath.Join(state, "service.sock")
	}
	socket, err = filepath.Abs(socket)
	return Paths{state, socket}, err
}

type Client struct {
	http  *http.Client
	token string
}

func New(socket, token string) *Client {
	dial := &net.Dialer{Timeout: 3 * time.Second}
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return dial.DialContext(ctx, "unix", socket)
	}}
	return &Client{http: &http.Client{Transport: transport, Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, token: token}
}

func Segment(s string) (string, error) {
	if s == "" || s == "." || s == ".." || strings.ContainsAny(s, "/\\?#%") {
		return "", errors.New("invalid or missing identifier")
	}
	return url.PathEscape(s), nil
}

func (c *Client) Do(ctx context.Context, method, path string, input any) (json.RawMessage, error) {
	if !strings.HasPrefix(path, "/v1/") {
		return nil, errors.New("expected a /v1/ API path")
	}
	var body io.Reader
	if input != nil {
		b, err := json.Marshal(input)
		if err != nil {
			return nil, err
		}
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://localhost"+path, body)
	if err != nil {
		return nil, err
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	if input != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("Commander service: %w", err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var result struct {
			Error string `json:"error"`
		}
		if json.Unmarshal(b, &result) == nil && result.Error != "" {
			return nil, fmt.Errorf("Commander API (%d): %s", resp.StatusCode, result.Error)
		}
		return nil, fmt.Errorf("Commander API (%s): %s", resp.Status, strings.TrimSpace(string(b)))
	}
	if !json.Valid(b) {
		return nil, errors.New("invalid JSON response from Commander service")
	}
	return b, nil
}

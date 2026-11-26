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

// ResponseError retains the status so callers can distinguish a refused
// operation from a temporary service failure.
type ResponseError struct {
	StatusCode int
	message    string
}

func (e *ResponseError) Error() string { return e.message }

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
	return c.exchange(c.http, ctx, method, path, input, nil)
}

// WaitWorkerControl shares the client's transport but bounds a server-side wait
// with its own timeout. Ordinary local API calls keep their shorter timeout.
func (c *Client) WaitWorkerControl(ctx context.Context, path string) (json.RawMessage, error) {
	client := *c.http
	client.Timeout = 30 * time.Second
	return c.exchange(&client, ctx, http.MethodGet, path, nil, nil)
}

// AwaitElicitation lets the service hold the addressed interaction until the
// user resolves it, the caller cancels it, or the service deadline expires.
func (c *Client) AwaitElicitation(ctx context.Context, path string, input any) (json.RawMessage, error) {
	client := *c.http
	client.Timeout = 0
	return c.exchange(&client, ctx, http.MethodPost, path, input, nil)
}

// Coordinator sends the actor binding to the local multiplayer device process.
// The daemon independently verifies it with the active Commander's private API.
func (c *Client) Coordinator(ctx context.Context, op, run, worker string, input any) (json.RawMessage, error) {
	switch op {
	case "discover", "submit", "receipt", "inbox":
	default:
		return nil, errors.New("unknown coordinator network operation")
	}
	if c.token == "" || run == "" || worker == "" {
		return nil, errors.New("managed coordinator credentials are required")
	}
	headers := http.Header{"X-Commander-Run": []string{run}, "X-Commander-Worker": []string{worker}}
	return c.exchange(c.http, ctx, http.MethodPost, "/coordinator/"+op, input, headers)
}

func (c *Client) exchange(client *http.Client, ctx context.Context, method, path string, input any, headers http.Header) (json.RawMessage, error) {
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
	for k, values := range headers {
		for _, value := range values {
			req.Header.Add(k, value)
		}
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	if input != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("Commander service: %w", err)
	}
	defer resp.Body.Close()
	var reader io.Reader = resp.Body
	const networkLimit = 4 << 20
	if headers != nil {
		reader = io.LimitReader(reader, networkLimit+1)
	}
	b, err := io.ReadAll(reader)
	if headers != nil && len(b) > networkLimit {
		return nil, errors.New("network daemon response exceeds 4 MiB")
	}
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var result struct {
			Error string `json:"error"`
		}
		if json.Unmarshal(b, &result) == nil && result.Error != "" {
			return nil, &ResponseError{resp.StatusCode, fmt.Sprintf("Commander API (%d): %s", resp.StatusCode, result.Error)}
		}
		return nil, &ResponseError{resp.StatusCode, fmt.Sprintf("Commander API (%s): %s", resp.Status, strings.TrimSpace(string(b)))}
	}
	if !json.Valid(b) {
		return nil, errors.New("invalid JSON response from Commander service")
	}
	return b, nil
}

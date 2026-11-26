package mcpbridge

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"
)

// deviceCoordinator sends the online and thread requests over the private network socket.
type deviceCoordinator struct {
	client *http.Client
	token  string
	run    string
	actor  string
}

func newDeviceCoordinator(socket, token, run, actor string) *deviceCoordinator {
	dialer := &net.Dialer{Timeout: 3 * time.Second}
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return dialer.DialContext(ctx, "unix", socket)
	}}
	return &deviceCoordinator{
		client: &http.Client{
			Transport: transport,
			Timeout:   15 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
		token: token, run: run, actor: actor,
	}
}

func (c *deviceCoordinator) post(ctx context.Context, verb string, body json.RawMessage) (json.RawMessage, error) {
	if verb != "online" && verb != "thread" {
		return nil, errors.New("unknown coordinator network operation")
	}
	if c.token == "" || c.run == "" || c.actor == "" {
		return nil, errors.New("managed coordinator credentials are required")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://localhost/coordinator/"+verb, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("X-Commander-Run", c.run)
	req.Header.Set("X-Commander-Worker", c.actor)
	resp, err := c.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	const limit = 4 << 20
	data, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if len(data) > limit {
		return nil, errors.New("network daemon response exceeds 4 MiB")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("Commander API (%s): %s", resp.Status, bytes.TrimSpace(data))
	}
	if !json.Valid(data) {
		return nil, errors.New("invalid JSON response from Commander service")
	}
	return data, nil
}

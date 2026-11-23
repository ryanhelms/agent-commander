package provider

import (
	"context"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestWorkerForwardRequiresItsOwnCredential(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "ac-relay-test-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(dir)
	socket := filepath.Join(dir, "owner")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	var calls atomic.Int32
	owner := http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Header.Get("Authorization") != "Bearer fixture-worker" {
			t.Error("worker forward reached the owner API without the scoped credential")
		}
		w.WriteHeader(http.StatusAccepted)
	})}
	defer owner.Close()
	go func() { _ = owner.Serve(listener) }()
	forward, closeForward, err := startWorkerForward(socket, "fixture-worker")
	if err != nil {
		t.Fatal(err)
	}
	defer closeForward()
	dialer := net.Dialer{Timeout: time.Second}
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return dialer.DialContext(ctx, "unix", forward)
	}}
	defer transport.CloseIdleConnections()
	client := http.Client{Transport: transport, Timeout: 2 * time.Second}
	cases := []struct {
		headers []string
		status  int
	}{
		{nil, http.StatusUnauthorized},
		{[]string{"Bearer another-worker"}, http.StatusUnauthorized},
		{[]string{"Bearer fixture-worker", "Bearer another-worker"}, http.StatusUnauthorized},
		{[]string{"Bearer fixture-worker"}, http.StatusAccepted},
	}
	for _, tc := range cases {
		req, err := http.NewRequest("POST", "http://localhost/v1/runs", strings.NewReader("{}"))
		if err != nil {
			t.Fatal(err)
		}
		for _, header := range tc.headers {
			req.Header.Add("Authorization", header)
		}
		response, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_, _ = io.Copy(io.Discard, response.Body)
		_ = response.Body.Close()
		if response.StatusCode != tc.status {
			t.Fatalf("got %d, want %d", response.StatusCode, tc.status)
		}
	}
	if calls.Load() != 1 {
		t.Fatalf("owner endpoint received %d calls, want one", calls.Load())
	}
}

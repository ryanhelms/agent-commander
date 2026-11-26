package mcpbridge

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func coordinatorWithTestDaemon(t *testing.T, handler http.HandlerFunc) *deviceCoordinator {
	t.Helper()
	// macOS temporary directory paths can exceed the Unix socket path limit.
	dir, err := os.MkdirTemp("/tmp", "ac-mcp-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	socket := filepath.Join(dir, "network.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	server := &httptest.Server{Listener: listener, Config: &http.Server{Handler: handler}}
	server.Start()
	t.Cleanup(server.Close)
	client := newDeviceCoordinator(socket, "test-token", "run-1", "coordinator-1")
	t.Cleanup(client.client.CloseIdleConnections)
	return client
}

func TestDeviceCoordinatorPost(t *testing.T) {
	for _, tc := range []struct{ verb, body, reply string }{
		{"online", `{}`, `{"ok":true,"data":{"contacts":[]}}`},
		{"thread", `{"request":"r1","text":""}`, `{"ok":true,"data":{"comments":[]}}`},
		{"board", `{"op":"claim","workspace":"w1","card":"c1"}`, `{"ok":true,"data":{"state":"claimed"}}`},
	} {
		t.Run(tc.verb, func(t *testing.T) {
			client := coordinatorWithTestDaemon(t, func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodPost || r.URL.RequestURI() != "/coordinator/"+tc.verb {
					t.Errorf("unexpected request: %s %s", r.Method, r.URL.RequestURI())
				}
				for key, want := range map[string]string{
					"Authorization":      "Bearer test-token",
					"X-Commander-Run":    "run-1",
					"X-Commander-Worker": "coordinator-1",
					"Content-Type":       "application/json",
				} {
					if got := r.Header.Get(key); got != want {
						t.Errorf("%s = %q, want %q", key, got, want)
					}
				}
				if body, err := io.ReadAll(r.Body); err != nil || string(body) != tc.body {
					t.Errorf("request body = %q, %v; want %q", body, err, tc.body)
				}
				io.WriteString(w, tc.reply)
			})
			got, err := client.post(t.Context(), tc.verb, json.RawMessage(tc.body))
			if err != nil || string(got) != tc.reply {
				t.Fatalf("reply = %s, %v; want %s", got, err, tc.reply)
			}
		})
	}
}

func TestDeviceCoordinatorRefusesUnknownVerb(t *testing.T) {
	client := coordinatorWithTestDaemon(t, func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("unknown verb reached the daemon: %s %s", r.Method, r.URL.Path)
	})
	_, err := client.post(t.Context(), "group-add", json.RawMessage(`{}`))
	if err == nil || err.Error() != "unknown coordinator network operation" {
		t.Fatalf("unexpected refusal: %v", err)
	}
}

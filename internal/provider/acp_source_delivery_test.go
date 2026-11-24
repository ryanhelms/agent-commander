package provider

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"
	"agentcommander/internal/localapi"
	"agentcommander/internal/service"
	"google.golang.org/protobuf/encoding/protojson"
)

type sourceTestLauncher chan service.LaunchSpec

func (l sourceTestLauncher) Launch(_ context.Context, s service.LaunchSpec) error { l <- s; return nil }
func (sourceTestLauncher) Stop(context.Context, string) error                     { return nil }

func TestACPSourceBurstDelivery(t *testing.T) {
	for _, name := range []string{"batch-retry", "legacy-fallback"} {
		t.Run(name, func(t *testing.T) {
			checkACPSourceBurst(t, name == "legacy-fallback")
		})
	}
}

func checkACPSourceBurst(t *testing.T, legacy bool) {
	t.Helper()
	// Keep the socket within the Darwin sockaddr_un path limit.
	dir, err := os.MkdirTemp("", "ac-src-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	launcher := make(sourceTestLauncher, 1)
	handler, err := service.New(dir, launcher)
	if err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(dir, "s")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	entered, release := make(chan struct{}), make(chan struct{})
	var first, releaseOnce sync.Once
	resume := func() { releaseOnce.Do(func() { close(release) }) }
	var mu sync.Mutex
	var attempts, largest int
	var committed []byte
	var retried bool
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/live-source") && !strings.HasSuffix(r.URL.Path, "/live-source/batch") {
			handler.ServeHTTP(w, r)
			return
		}
		first.Do(func() { close(entered); <-release })
		if strings.HasSuffix(r.URL.Path, "/batch") {
			mu.Lock()
			defer mu.Unlock()
			attempts++
			if legacy {
				http.NotFound(w, r)
				return
			}
			body, err := io.ReadAll(r.Body)
			var batch []service.LiveSourceUpdate
			if err != nil || len(body) > 2<<20 || json.Unmarshal(body, &batch) != nil ||
				len(batch) < 1 || len(batch) > service.LiveSourceBatchRecords {
				t.Error("invalid source batch on the wire")
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			r.Body = io.NopCloser(bytes.NewReader(body))
			largest = max(largest, len(batch))
			if len(batch) > 1 && committed == nil {
				// Let the actual service commit, then make the sender retry an
				// ambiguous acknowledgment. Owner history below verifies deduplication.
				ack := httptest.NewRecorder()
				handler.ServeHTTP(ack, r)
				if ack.Code != http.StatusOK {
					t.Errorf("source batch was rejected before retry: %d", ack.Code)
				}
				committed = body
				http.Error(w, "temporary response failure", http.StatusServiceUnavailable)
				return
			}
			if committed != nil && !retried {
				retried = true
				if !bytes.Equal(body, committed) {
					t.Error("the next batch changed before the unacknowledged batch was retried")
				}
			}
		}
		handler.ServeHTTP(w, r)
	})}
	go server.Serve(listener)
	t.Cleanup(func() { resume(); server.Close() })
	owner := localapi.New(socket, "")
	ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
	defer cancel()
	if _, err := owner.Do(ctx, "POST", "/v1/runs", map[string]string{"client": "codex", "task": "source delivery", "path": dir}); err != nil {
		t.Fatal(err)
	}
	var worker service.LaunchSpec
	select {
	case worker = <-launcher:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	path := "/v1/workers/" + worker.ID
	ref := &model.SessionRef{HarnessInstance: "codex-local", SessionId: "selected"}
	if _, err := owner.Do(ctx, "POST", path+"/native-session", service.NativeSession{HarnessInstance: ref.HarnessInstance, SessionID: ref.SessionId}); err != nil {
		t.Fatal(err)
	}
	p := newACPSourcePublisher()
	finish := p.publish(ctx, &api{localapi.New(socket, worker.Token)}, path, ref, &screen{})
	drain := sync.OnceFunc(func() { resume(); finish() })
	defer drain()
	const count = 67
	const turn = "turn-1"
	body := func(i int) []byte {
		return []byte(fmt.Sprintf(`{"sessionUpdate":"agent_message_chunk","messageId":"m","content":{"type":"text","text":"delta %d"}}`, i))
	}
	capture := func(i int) {
		p.capture(runtime.ACPUpdate{Session: ref, TurnID: turn, Cursor: strconv.Itoa(i), Body: body(i)})
	}
	capture(0)
	select {
	case <-entered:
	case <-ctx.Done():
		t.Fatal("publisher never reached the source endpoint")
	}
	// This callback runs under the SDK session lock. Exercise the full burst
	// before the first HTTP response is allowed to reach the sender.
	accepted := make(chan struct{})
	go func() {
		defer close(accepted)
		for i := 1; i < count; i++ {
			capture(i)
		}
	}()
	select {
	case <-accepted:
	case <-ctx.Done():
		resume()
		t.Fatal("source capture waited for the held HTTP response")
	}
	for i := range count {
		cursor := strconv.Itoa(i)
		link := p.take(cursor)
		if link == nil || link.Cursor != cursor || link.Source != "live" || link.MessageID != "m" || link.TurnID != turn {
			t.Errorf("missing or misbound source descriptor for %s: %+v", cursor, link)
		}
	}
	drain()
	raw, err := owner.Do(ctx, "GET", path+"/history?source=live&turnId="+turn+"&limit=128", nil)
	if err != nil {
		t.Fatal(err)
	}
	var history model.ReadHistoryResponse
	if err := protojson.Unmarshal(raw, &history); err != nil {
		t.Fatal(err)
	}
	if len(history.Observations) != count || history.GetNextCursor() != "" {
		t.Fatalf("retained %d of %d records, next cursor %q", len(history.Observations), count, history.GetNextCursor())
	}
	for i, item := range history.Observations {
		if item.Cursor != strconv.Itoa(i) || item.TurnId != turn || item.GetGap() != nil ||
			item.GetSession().GetSessionId() != ref.SessionId || item.GetSession().GetHarnessInstance() != ref.HarnessInstance ||
			!bytes.Equal(item.GetExtension().GetData(), body(i)) {
			t.Fatalf("wrong source at position %d: %v", i, item)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if legacy && attempts != 1 {
		t.Errorf("expected one fallback probe, got %d", attempts)
	}
	if !legacy && (!retried || largest < 2) {
		t.Errorf("expected an acknowledged retry of a multi-record batch, largest=%d retried=%v", largest, retried)
	}
	t.Logf("retained %d ordered cursors; batch attempts=%d largest=%d retried=%t", count, attempts, largest, retried)
}

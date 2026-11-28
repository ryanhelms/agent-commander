package actions

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type inboxWaitFixture struct {
	config  Config
	owner   *http.Server
	checked chan string
	calls   atomic.Int32
	binding atomic.Value
}

func newInboxWaitFixture(t *testing.T) *inboxWaitFixture {
	t.Helper()
	// Darwin Unix sockets have a shorter pathname limit than some test temp paths.
	dir, err := os.MkdirTemp("", "aci-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socket := filepath.Join(dir, "c.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	f := &inboxWaitFixture{
		config: Config{CommanderSocket: socket, StateDir: dir, Resources: []Resource{
			{ID: "one", Kind: "agent", Target: "worker-a", Run: "run-a", Coordinator: true},
			{ID: "two", Kind: "agent", Target: "worker-b", Run: "run-b", Coordinator: true},
		}},
		checked: make(chan string, 50),
	}
	f.binding.Store(localWorker{Role: "coordinator", RunStatus: "running"})
	f.owner = &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		worker, ok := strings.CutPrefix(r.URL.Path, "/v1/ag-ui/workers/")
		if !ok {
			http.NotFound(w, r)
			return
		}
		f.calls.Add(1)
		info := f.binding.Load().(localWorker)
		info.WorkerID = worker
		if info.RunID == "" {
			info.RunID = "run-" + strings.TrimPrefix(worker, "worker-")
		}
		_ = json.NewEncoder(w).Encode(info)
		select {
		case f.checked <- worker:
		default:
		}
	})}
	t.Cleanup(func() { _ = f.owner.Close() })
	go func() { _ = f.owner.Serve(listener) }()
	return f
}

type inboxWaitResult struct {
	box coordinatorMailbox
	err error
}

func runInboxWait(ctx context.Context, config func() Config, resource Resource, fallback time.Duration) <-chan inboxWaitResult {
	result := make(chan inboxWaitResult, 1)
	go func() {
		box, err := waitCoordinatorInbox(ctx, config, resource.Target, resource.Run, InboxQuery{WaitSeconds: 4}, fallback)
		result <- inboxWaitResult{box, err}
	}()
	return result
}

func awaitInboxCheck(t *testing.T, f *inboxWaitFixture, worker string) {
	t.Helper()
	limit := time.After(3 * time.Second)
	for {
		select {
		case got := <-f.checked:
			if got == worker {
				return
			}
		case <-limit:
			t.Fatalf("owner was never asked for %s", worker)
		}
	}
}

func awaitInboxResult(t *testing.T, result <-chan inboxWaitResult) inboxWaitResult {
	t.Helper()
	select {
	case got := <-result:
		return got
	case <-time.After(3 * time.Second):
		t.Fatal("the inbox wait did not return promptly")
		return inboxWaitResult{}
	}
}

// persistInboxNote represents a write from another process with no local wake.
func persistInboxNote(t *testing.T, cfg Config, resource Resource) string {
	t.Helper()
	path := mailboxPath(cfg, resource)
	if err := privateDir(filepath.Dir(path)); err != nil {
		t.Fatal(err)
	}
	note := coordinatorNote{ID: "saved", Peer: "alice", Resource: resource.ID, Text: "test", ReceivedAt: time.Now()}
	if err := save(path, coordinatorMailbox{Messages: []coordinatorNote{note}}); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestCoordinatorInboxWakesAllWaiters(t *testing.T) {
	f := newInboxWaitFixture(t)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	config := func() Config { return f.config }
	a, b := f.config.Resources[0], f.config.Resources[1]
	first := runInboxWait(ctx, config, a, time.Minute)
	second := runInboxWait(ctx, config, a, time.Minute)
	awaitInboxCheck(t, f, a.Target)
	awaitInboxCheck(t, f, a.Target)
	unrelated := runInboxWait(ctx, config, b, time.Minute)
	awaitInboxCheck(t, f, b.Target)

	req := Request{Peer: "alice", Payload: json.RawMessage(`{"text":"delivered"}`)}
	if _, err := coordinatorMessage(ctx, f.config, a, req, "sent", false); err != nil {
		t.Fatal(err)
	}
	for _, result := range []<-chan inboxWaitResult{first, second} {
		got := awaitInboxResult(t, result)
		if got.err != nil || len(got.box.Messages) != 1 || got.box.Messages[0].ID != "sent" {
			t.Fatal(got)
		}
	}
	cancel()
	if got := awaitInboxResult(t, unrelated); !errors.Is(got.err, context.Canceled) || len(got.box.Messages) != 0 {
		t.Fatal(got)
	}
	for _, resource := range []Resource{a, b} {
		path := mailboxPath(f.config, resource)
		coordinatorInboxWakes.mu.Lock()
		remaining := coordinatorInboxWakes.waiting[path]
		coordinatorInboxWakes.mu.Unlock()
		if remaining != nil {
			t.Fatalf("mailbox retained a subscription after all waits ended: %s", resource.ID)
		}
	}
}

func TestCoordinatorInboxWakeSurvivesSnapshotToWaitRace(t *testing.T) {
	registry := inboxWakeRegistry{waiting: make(map[string]*inboxWake)}
	first, releaseFirst := registry.subscribe("a")
	second, releaseSecond := registry.subscribe("a")
	unrelated, releaseUnrelated := registry.subscribe("b")
	defer releaseUnrelated()

	// Publish after the empty read and before either subscriber begins waiting.
	registry.publish("a")
	for _, wake := range []<-chan struct{}{first, second} {
		select {
		case <-wake:
		default:
			t.Fatal("the commit between snapshot and wait was lost")
		}
	}

	newGeneration, releaseNew := registry.subscribe("a")
	defer releaseNew()
	releaseFirst()
	releaseSecond()
	for _, wake := range []<-chan struct{}{unrelated, newGeneration} {
		select {
		case <-wake:
			t.Fatal("a new generation or separate mailbox woke for an old commit")
		default:
		}
	}
	registry.publish("a")
	select {
	case <-newGeneration:
	default:
		t.Fatal("retiring previous waiters removed the new subscription")
	}
}

func TestCoordinatorInboxRecoversPersistedNoteWithoutWake(t *testing.T) {
	f := newInboxWaitFixture(t)
	resource := f.config.Resources[0]
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	result := runInboxWait(ctx, func() Config { return f.config }, resource, inboxFallbackCheck)
	awaitInboxCheck(t, f, resource.Target)
	persistInboxNote(t, f.config, resource)
	got := awaitInboxResult(t, result)
	if got.err != nil || len(got.box.Messages) != 1 || got.box.Messages[0].ID != "saved" {
		t.Fatal(got)
	}

	// A fresh observer, such as after a helper restart, uses the durable cursor.
	box, err := CoordinatorInbox(ctx, func() Config { return f.config }, resource.Target, resource.Run, InboxQuery{AfterMessageID: "saved"})
	if err != nil || len(box.Messages) != 0 || box.Truncated {
		t.Fatal(box, err)
	}
}

func TestCoordinatorInboxRechecksBindingBeforeReturningWokenNote(t *testing.T) {
	for _, tc := range []struct {
		name string
		set  func(*inboxWaitFixture, *atomic.Bool)
		want error
	}{
		{"ended", func(f *inboxWaitFixture, _ *atomic.Bool) {
			f.binding.Store(localWorker{Role: "coordinator", RunStatus: "completed"})
		}, ErrDenied},
		{"rebound", func(f *inboxWaitFixture, _ *atomic.Bool) {
			f.binding.Store(localWorker{Role: "coordinator", RunID: "run-other", RunStatus: "running"})
		}, ErrDenied},
		{"unavailable", func(f *inboxWaitFixture, _ *atomic.Bool) { _ = f.owner.Close() }, ErrUnavailable},
		{"unenrolled", func(_ *inboxWaitFixture, removed *atomic.Bool) { removed.Store(true) }, errInboxNotConfigured},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newInboxWaitFixture(t)
			resource := f.config.Resources[0]
			var removed atomic.Bool
			config := func() Config {
				cfg := f.config
				if removed.Load() {
					cfg.Resources = nil
				}
				return cfg
			}
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			result := runInboxWait(ctx, config, resource, time.Minute)
			awaitInboxCheck(t, f, resource.Target)
			tc.set(f, &removed)
			path := persistInboxNote(t, f.config, resource)
			coordinatorInboxWakes.publish(path)
			got := awaitInboxResult(t, result)
			if !errors.Is(got.err, tc.want) || len(got.box.Messages) != 0 {
				t.Fatalf("got %+v, want %v with no private note", got, tc.want)
			}
		})
	}
}

func TestCoordinatorInboxIdleWaitBoundsOwnerChecks(t *testing.T) {
	f := newInboxWaitFixture(t)
	resource := f.config.Resources[0]
	box, err := CoordinatorInbox(t.Context(), func() Config { return f.config }, resource.Target, resource.Run, InboxQuery{WaitSeconds: 2})
	if err != nil || len(box.Messages) != 0 || box.Messages == nil {
		t.Fatal(box, err)
	}
	if got := f.calls.Load(); got < 1 || got > 3 {
		t.Fatalf("empty 2-second wait made %d owner checks; want at most 3", got)
	}
}

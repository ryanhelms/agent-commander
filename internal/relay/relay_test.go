package relay

import (
	"io"
	"net"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestReplaceInstancesKeepsUnchangedTunnelsAndRejectsStaleRegistration(t *testing.T) {
	alice := Instance{Host: "alice.example.com", CertificateSHA256: strings.Repeat("1", 64)}
	bob := Instance{Host: "bob.example.com", CertificateSHA256: strings.Repeat("2", 64)}
	r, err := New([]Instance{alice, bob})
	if err != nil {
		t.Fatal(err)
	}
	connect := func(instance *host) *session {
		t.Helper()
		left, right := net.Pipe()
		t.Cleanup(func() { _ = left.Close(); _ = right.Close() })
		s := newSession(newTunnelConn(left))
		if !r.register(instance, s) {
			t.Fatal("failed to register fixture tunnel")
		}
		return s
	}
	originalAlice, originalBob := r.routes.hosts[alice.Host], r.routes.hosts[bob.Host]
	aliceSession, bobSession := connect(originalAlice), connect(originalBob)
	mustBeOpen := func(s *session) {
		t.Helper()
		select {
		case <-s.conn.done:
			t.Fatal("unchanged tunnel was closed")
		default:
		}
	}
	mustBeClosed := func(s *session) {
		t.Helper()
		select {
		case <-s.conn.done:
		default:
			t.Fatal("displaced tunnel is still open")
		}
	}
	duplicatePin := bob
	duplicatePin.CertificateSHA256 = alice.CertificateSHA256
	if err := r.ReplaceInstances([]Instance{alice, duplicatePin}); err == nil {
		t.Fatal("duplicate pin accepted")
	}
	if err := r.ReplaceInstances(nil); err == nil {
		t.Fatal("missing inventory accepted")
	}
	mustBeOpen(aliceSession)
	mustBeOpen(bobSession)

	rotatedAlice := alice
	rotatedAlice.CertificateSHA256 = strings.Repeat("3", 64)
	if err := r.ReplaceInstances([]Instance{rotatedAlice, bob}); err != nil {
		t.Fatal(err)
	}
	mustBeClosed(aliceSession)
	mustBeOpen(bobSession)
	if r.routes.hosts[bob.Host].connected() != bobSession {
		t.Fatal("unchanged host lost its original session")
	}
	if r.register(originalAlice, aliceSession) {
		t.Fatal("a readiness probe from before rotation can still register")
	}

	rotatedSession := connect(r.routes.hosts[alice.Host])
	if err := r.ReplaceInstances([]Instance{}); err != nil {
		t.Fatal(err)
	}
	mustBeClosed(rotatedSession)
	mustBeClosed(bobSession)
	if err := r.ReplaceInstances([]Instance{alice}); err != nil {
		t.Fatal(err)
	}
	if r.register(originalAlice, aliceSession) {
		t.Fatal("a readiness probe from the former enrollment survived remove and re-add")
	}
	_ = connect(r.routes.hosts[alice.Host])
}

func TestRelayWriteDeadlineClosesBlockedClientAndPreservesQuietStream(t *testing.T) {
	releaseQuiet := make(chan struct{})
	slowStopped := make(chan struct{})
	var slowBytes atomic.Int64
	owner := http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		w.WriteHeader(http.StatusOK)
		if err := http.NewResponseController(w).Flush(); err != nil {
			return
		}
		switch req.URL.Path {
		case "/v1/blocked":
			defer close(slowStopped)
			chunk := make([]byte, 32<<10)
			for range 1024 {
				n, err := w.Write(chunk)
				slowBytes.Add(int64(n))
				if err != nil {
					return
				}
			}
		case "/v1/quiet":
			select {
			case <-releaseQuiet:
				_, _ = io.WriteString(w, "resumed after quiet interval")
			case <-req.Context().Done():
			}
		default:
			_, _ = io.WriteString(w, "first host ready")
		}
	})
	second := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "second host ready")
	})
	fixture := newRelayFixture(t, []http.Handler{owner, second})
	fixture.client.Transport.(*http.Transport).HTTP2 = &http.HTTP2Config{MaxReceiveBufferPerStream: 64 << 10}
	open := func(host int, path string) *http.Response {
		t.Helper()
		req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, fixture.endpoint(host)+path, nil)
		if err != nil {
			t.Fatal(err)
		}
		res, err := fixture.send(req)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = res.Body.Close() })
		if res.StatusCode != http.StatusOK || res.ProtoMajor != 2 {
			t.Fatalf("host %d returned %s over %s", host, res.Status, res.Proto)
		}
		return res
	}
	expectBody := func(res *http.Response, want string) {
		t.Helper()
		body, err := io.ReadAll(res.Body)
		if err != nil || string(body) != want {
			t.Fatalf("wanted %q, got %q, %v", want, body, err)
		}
	}
	before := time.Now()
	blocked := open(0, "/v1/blocked")
	quiet := open(0, "/v1/quiet")
	quietSince := time.Now()
	expectBody(open(1, "/v1/ready"), "second host ready")
	select {
	case <-slowStopped:
		if time.Since(before) < appWriteTimeout || slowBytes.Load() >= 4<<20 {
			t.Fatalf("blocked transfer stopped outside its flow-control budget: elapsed=%v, bytes=%d", time.Since(before), slowBytes.Load())
		}
	case <-time.After(appWriteTimeout + 3*time.Second):
		t.Fatal("blocked client retained its upstream response")
	}
	if _, err := io.Copy(io.Discard, blocked.Body); err == nil {
		t.Fatal("blocked client received a successful end to a truncated response")
	}
	host := fixture.proxy.routes.hosts[fixture.instances[0].Host].connected()
	for deadline := time.Now().Add(time.Second); host != nil && len(host.requests) > 1 && time.Now().Before(deadline); {
		time.Sleep(time.Millisecond)
	}
	if host == nil || len(host.requests) != 1 || fixture.proxy.interrupted.Load() != 1 {
		t.Fatal("the interrupted transfer did not free its slot and update telemetry")
	}

	timer := time.NewTimer(time.Until(quietSince.Add(appWriteTimeout + 250*time.Millisecond)))
	defer timer.Stop()
	select {
	case <-t.Context().Done():
		t.Fatal(t.Context().Err())
	case <-timer.C:
		close(releaseQuiet)
	}
	expectBody(quiet, "resumed after quiet interval")
	expectBody(open(0, "/v1/ready"), "first host ready")
	expectBody(open(1, "/v1/ready"), "second host ready")
}

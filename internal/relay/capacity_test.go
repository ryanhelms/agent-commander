package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// BenchmarkRelayCapacity measures a wave of 16 concurrent transfers per
// enrolled host. Both TLS legs and the multiplexed tunnel carry real traffic.
func BenchmarkRelayCapacity(b *testing.B) {
	for _, hostCount := range []int{1, 16, maxHosts} {
		b.Run(fmt.Sprintf("%d_hosts", hostCount), func(b *testing.B) {
			benchmarkRelayWave(b, hostCount)
		})
	}
}

func benchmarkRelayWave(b *testing.B, hostCount int) {
	const responseSize = 64 << 10
	upload := bytes.Repeat([]byte("p"), 1024)
	type wave struct {
		arrived chan struct{}
		release chan struct{}
	}
	var activeWave atomic.Pointer[wave]
	handlers := make([]http.Handler, hostCount)
	for i := range handlers {
		payload := bytes.Repeat([]byte{byte(i)}, responseSize)
		handlers[i] = http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			body, err := io.ReadAll(http.MaxBytesReader(w, req.Body, int64(len(upload))))
			if err != nil || !bytes.Equal(body, upload) {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			if current := activeWave.Load(); current != nil {
				current.arrived <- struct{}{}
				select {
				case <-current.release:
				case <-req.Context().Done():
					return
				}
			}
			_, _ = w.Write(payload)
		})
	}
	fixture := newRelayFixture(b, handlers)
	request := func(hostNumber int) (*http.Response, error) {
		input := bytes.NewReader(upload)
		req, err := http.NewRequestWithContext(b.Context(), http.MethodPost, fixture.endpoint(hostNumber)+"/v1/fixture", input)
		if err != nil {
			return nil, err
		}
		return fixture.send(req)
	}
	transfer := func(hostNumber int) error {
		res, err := request(hostNumber)
		if err != nil {
			return err
		}
		defer res.Body.Close()
		if res.StatusCode != http.StatusOK || res.ProtoMajor != 2 {
			return fmt.Errorf("host %d responded with %s over %s", hostNumber, res.Status, res.Proto)
		}
		var first [1]byte
		if _, err := io.ReadFull(res.Body, first[:]); err != nil {
			return err
		}
		remaining, err := io.Copy(io.Discard, res.Body)
		if err != nil {
			return err
		}
		if first[0] != byte(hostNumber) || remaining != responseSize-1 {
			return fmt.Errorf("host %d returned another host's payload or incomplete data", hostNumber)
		}
		return nil
	}
	// Establish the app-facing HTTP/2 connection for each enrolled host.
	for i := range handlers {
		if err := transfer(i); err != nil {
			b.Fatal(err)
		}
	}
	b.ReportAllocs()
	transfersPerWave := hostCount * maxStreams
	b.SetBytes(int64(transfersPerWave * responseSize))
	runWave := func(verifySaturation bool) error {
		current := &wave{arrived: make(chan struct{}, transfersPerWave), release: make(chan struct{})}
		activeWave.Store(current)
		defer activeWave.Store(nil)
		var work sync.WaitGroup
		failed := make(chan error, transfersPerWave)
		defer work.Wait()
		for i := range handlers {
			for range maxStreams {
				work.Go(func() {
					if err := transfer(i); err != nil {
						failed <- err
					}
				})
			}
		}
		waitErr := func() error {
			defer close(current.release)
			deadline := time.NewTimer(12 * time.Second)
			defer deadline.Stop()
			for range transfersPerWave {
				select {
				case <-current.arrived:
				case err := <-failed:
					return err
				case <-deadline.C:
					return fmt.Errorf("not all %d transfers reached the upstream concurrently", transfersPerWave)
				}
			}
			if !verifySaturation {
				return nil
			}
			res, err := request(0)
			if err != nil {
				return err
			}
			defer res.Body.Close()
			if res.StatusCode != http.StatusTooManyRequests {
				return fmt.Errorf("a saturated host accepted an extra transfer: %s", res.Status)
			}
			return nil
		}()
		if waitErr != nil {
			return waitErr
		}
		work.Wait()
		select {
		case err := <-failed:
			return err
		default:
			return nil
		}
	}
	if err := runWave(true); err != nil {
		b.Fatal(err)
	}
	for b.Loop() {
		if err := runWave(false); err != nil {
			b.Fatal(err)
		}
	}
	b.ReportMetric(float64(transfersPerWave)*float64(b.N)/b.Elapsed().Seconds(), "responses/s")
}

type relayFixture struct {
	proxy     *Relay
	client    *http.Client
	instances []Instance
}

func (f relayFixture) endpoint(hostNumber int) string {
	return "https://" + f.instances[hostNumber].Host
}

func (f relayFixture) send(req *http.Request) (*http.Response, error) {
	req.Header.Set("Authorization", "Bearer relay-test-fixture")
	return f.client.Do(req)
}

func newRelayFixture(t testing.TB, handlers []http.Handler) relayFixture {
	t.Helper()
	hostCount := len(handlers)
	instances := make([]Instance, hostCount)
	connectors := make([]tls.Certificate, hostCount)
	for i := range instances {
		cert := relayFixtureCertificate(t, i)
		connectors[i] = cert
		instances[i] = Instance{
			Host:              fmt.Sprintf("host-%d.example.com", i),
			CertificateSHA256: fmt.Sprintf("%x", sha256.Sum256(cert.Certificate[0])),
		}
	}
	proxy, err := New(instances)
	if err != nil {
		t.Fatal(err)
	}
	app := httptest.NewUnstartedServer(proxy)
	app.EnableHTTP2 = true
	app.StartTLS()
	t.Cleanup(app.Close)
	trust := x509.NewCertPool()
	trust.AddCert(app.Certificate())

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	listening := make(chan error, 1)
	go func() { listening <- proxy.Accept(ctx, listener, app.TLS.Certificates[0]) }()
	var tunnelWG sync.WaitGroup
	t.Cleanup(func() {
		cancel()
		if err := <-listening; err != nil {
			t.Error(err)
		}
		tunnelWG.Wait()
	})
	for i, cert := range connectors {
		tunnelWG.Go(func() {
			_ = Connect(ctx, listener.Addr().String(), &tls.Config{RootCAs: trust, Certificates: []tls.Certificate{cert}}, handlers[i])
		})
		// Enroll in order so the transfer measurement starts with all hosts
		// connected independently of the separate handshake backlog limit.
		host := proxy.routes.hosts[instances[i].Host]
		deadline := time.Now().Add(5 * time.Second)
		for host.connected() == nil {
			if time.Now().After(deadline) {
				t.Fatalf("connector %d did not become ready", i)
			}
			time.Sleep(time.Millisecond)
		}
	}

	transport := &http.Transport{
		ForceAttemptHTTP2: true,
		TLSClientConfig:   &tls.Config{RootCAs: trust},
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, app.Listener.Addr().String())
		},
	}
	t.Cleanup(transport.CloseIdleConnections)
	client := &http.Client{Transport: transport, Timeout: 20 * time.Second}
	return relayFixture{proxy: proxy, client: client, instances: instances}
}

func relayFixtureCertificate(t testing.TB, number int) tls.Certificate {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	cert := &x509.Certificate{
		SerialNumber: big.NewInt(int64(number + 1)),
		NotBefore:    now.Add(-time.Minute), NotAfter: now.Add(time.Hour),
		KeyUsage:    x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, public, private)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: private}
}

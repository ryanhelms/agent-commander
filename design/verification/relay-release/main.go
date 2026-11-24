// relay-release exercises two packaged relay binaries using disposable TLS
// identities and loopback listeners.
package main

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"agentcommander/internal/relay"
)

const (
	alice      = "alice.relay.example"
	bob        = "bob.relay.example"
	carol      = "carol.relay.example"
	bearer     = "Bearer synthetic-enrollment-secret"
	checkPath  = "/v1/synthetic-enrollment-route"
	streamPath = "/v1/synthetic-enrollment-stream"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func check(ok bool, detail string) {
	if !ok {
		panic(detail)
	}
}

func certificate(id int64, server bool) ([]byte, []byte, tls.Certificate) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	must(err)
	now := time.Now()
	cert := &x509.Certificate{
		SerialNumber: big.NewInt(id), NotBefore: now.Add(-time.Minute), NotAfter: now.Add(time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature,
	}
	if server {
		cert.DNSNames = []string{alice, bob, carol}
		cert.IPAddresses = []net.IP{net.IPv4(127, 0, 0, 1)}
		cert.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
		cert.IsCA = true
		cert.BasicConstraintsValid = true
		cert.KeyUsage |= x509.KeyUsageCertSign
	} else {
		cert.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}
	}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, public, private)
	must(err)
	encodedKey, err := x509.MarshalPKCS8PrivateKey(private)
	must(err)
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: encodedKey})
	pair, err := tls.X509KeyPair(certPEM, keyPEM)
	must(err)
	return certPEM, keyPEM, pair
}

func instance(name string, cert tls.Certificate) relay.Instance {
	return relay.Instance{Host: name, CertificateSHA256: fmt.Sprintf("%x", sha256.Sum256(cert.Certificate[0]))}
}

func address() string {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	must(err)
	defer l.Close()
	return l.Addr().String()
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: relay-release PREVIOUS_AGENTCTL CANDIDATE_AGENTCTL")
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	dir, err := os.MkdirTemp("", "enrollment-proof-")
	must(err)
	defer os.RemoveAll(dir)
	certPath, keyPath := filepath.Join(dir, "server.pem"), filepath.Join(dir, "server-key.pem")
	serverCert, serverKey, _ := certificate(1, true)
	must(os.WriteFile(certPath, serverCert, 0600))
	must(os.WriteFile(keyPath, serverKey, 0600))
	roots := x509.NewCertPool()
	check(roots.AppendCertsFromPEM(serverCert), "server trust")
	_, _, aliceOld := certificate(2, false)
	_, _, aliceNew := certificate(3, false)
	_, _, bobCert := certificate(4, false)
	_, _, carolCert := certificate(5, false)

	pub, tunnel, metrics := address(), address(), address()
	check(pub != tunnel && pub != metrics && tunnel != metrics, "fixture ports must be unique")
	configPath := filepath.Join(dir, "relay.json")
	writeConfig := func(instances []relay.Instance, metricsAddr string) {
		body, err := json.Marshal(map[string]any{
			"listen": pub, "certificate": certPath, "private_key": keyPath,
			"tunnel_listen": tunnel, "tunnel_certificate": certPath, "tunnel_private_key": keyPath,
			"metrics_listen": metricsAddr, "instances": instances,
		})
		must(err)
		must(os.WriteFile(configPath+".tmp", body, 0600))
		must(os.Rename(configPath+".tmp", configPath))
	}
	aOld, b, c := instance(alice, aliceOld), instance(bob, bobCert), instance(carol, carolCert)
	aNew := instance(alice, aliceNew)
	writeConfig([]relay.Instance{aOld, b}, metrics)
	logFile, err := os.Create(filepath.Join(dir, "relay.log"))
	must(err)
	defer logFile.Close()
	hashes := func(binary string) [32]byte { raw, err := os.ReadFile(binary); must(err); return sha256.Sum256(raw) }
	previousHash, candidateHash := hashes(os.Args[1]), hashes(os.Args[2])
	check(previousHash != candidateHash, "must exercise different release binaries")
	fmt.Printf("relay binaries previous=%x candidate=%x\n", previousHash, candidateHash)
	var cmd *exec.Cmd
	start := func(binary string) {
		cmd = exec.CommandContext(ctx, binary, "relay", configPath)
		cmd.Stdout, cmd.Stderr = logFile, logFile
		must(cmd.Start())
	}
	stop := func() {
		if cmd == nil {
			return
		}
		must(cmd.Process.Signal(syscall.SIGTERM))
		err := cmd.Wait()
		if err != nil && err.Error() != "signal: terminated" {
			panic(err)
		}
		cmd = nil
	}
	start(os.Args[1])
	defer stop()
	logText := func() string {
		body, err := os.ReadFile(logFile.Name())
		must(err)
		return string(body)
	}
	await := func(label string, condition func() bool) {
		until := time.Now().Add(5 * time.Second)
		for time.Now().Before(until) {
			if condition() {
				return
			}
			time.Sleep(15 * time.Millisecond)
		}
		panic("timed out: " + label + "\n" + logText())
	}
	reload := func(instances []relay.Instance, metricsAddr, logMarker string) {
		initialSize := len(logText())
		writeConfig(instances, metricsAddr)
		must(cmd.Process.Signal(syscall.SIGHUP))
		await(logMarker, func() bool { return strings.Contains(logText()[initialSize:], logMarker) })
	}
	transport := &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots}, DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, pub)
	}}
	defer transport.CloseIdleConnections()
	httpClient := &http.Client{Transport: transport, Timeout: 15 * time.Second}
	request := func(name, path, authority string) (*http.Response, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://"+name+path, nil)
		if err != nil {
			return nil, err
		}
		req.Host = authority
		req.Header.Set("Authorization", bearer)
		return httpClient.Do(req)
	}
	status := func(name, authority string) (int, string, error) {
		res, err := request(name, checkPath, authority)
		if err != nil {
			return 0, "", err
		}
		defer res.Body.Close()
		data, err := io.ReadAll(res.Body)
		return res.StatusCode, string(data), err
	}
	wantRoute := func(name string, want int, body string) {
		await(fmt.Sprintf("%s %d %s", name, want, body), func() bool {
			status, text, err := status(name, name)
			return err == nil && status == want && (body == "" || text == body)
		})
	}

	streamGate := make(chan struct{})
	connect := func(cert tls.Certificate, marker string) <-chan error {
		done := make(chan error, 1)
		go func() {
			done <- relay.Connect(ctx, tunnel, &tls.Config{RootCAs: roots, Certificates: []tls.Certificate{cert}},
				http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if r.Header.Get("Authorization") != bearer {
						http.Error(w, "wrong app credentials", 401)
						return
					}
					if r.URL.Path == streamPath {
						w.Header().Set("Content-Type", "text/event-stream")
						_, _ = fmt.Fprintln(w, "data: stream-begin-"+marker)
						_ = http.NewResponseController(w).Flush()
						select {
						case <-streamGate:
							_, _ = fmt.Fprintln(w, "data: stream-end-"+marker)
						case <-r.Context().Done():
						}
						return
					}
					_, _ = fmt.Fprint(w, marker)
				}))
		}()
		return done
	}
	expectClosed := func(label string, done <-chan error) {
		select {
		case <-done:
		case <-time.After(4 * time.Second):
			panic("connector remained open: " + label)
		}
	}
	expectRejected := func(label string, cert tls.Certificate) {
		dial := tls.Dialer{Config: &tls.Config{
			RootCAs: roots, Certificates: []tls.Certificate{cert},
			MinVersion: tls.VersionTLS13, NextProtos: []string{"commander-relay/1"},
		}}
		probe, cancel := context.WithTimeout(ctx, 4*time.Second)
		defer cancel()
		conn, err := dial.DialContext(probe, "tcp", tunnel)
		if err == nil {
			defer conn.Close()
			deadline, _ := probe.Deadline()
			must(conn.SetReadDeadline(deadline))
			// TLS 1.3 may report the server's client-certificate rejection on the
			// first read after the client has sent its part of the handshake.
			var b [1]byte
			_, err = conn.Read(b[:])
		}
		check(err != nil && strings.Contains(err.Error(), "remote error: tls:"),
			fmt.Sprintf("%s: expected rejection from the relay's TLS peer, got %v", label, err))
	}

	wantRoute(alice, 503, "")
	aliceFirst, bobFirst := connect(aliceOld, "alice-old"), connect(bobCert, "bob")
	wantRoute(alice, 200, "alice-old")
	wantRoute(bob, 200, "bob")
	fmt.Println("Previous executable authenticated both enrolled connectors")
	stop()
	expectClosed("previous release stopped Alice", aliceFirst)
	expectClosed("previous release stopped Bob", bobFirst)
	start(os.Args[2])
	wantRoute(alice, 503, "")
	aliceFirst, bobFirst = connect(aliceOld, "alice-old"), connect(bobCert, "bob")
	wantRoute(alice, 200, "alice-old")
	wantRoute(bob, 200, "bob")
	fmt.Println("Candidate executable authenticated original enrolled connectors")
	wantRoute(carol, 421, "")
	expectRejected("unenrolled carol", carolCert)
	response, err := request(bob, streamPath, bob)
	must(err)
	defer response.Body.Close()
	stream := bufio.NewReader(response.Body)
	first, err := stream.ReadString('\n')
	must(err)
	check(first == "data: stream-begin-bob\n", "Bob did not open its stream")

	reload([]relay.Instance{aOld, {Host: carol, CertificateSHA256: aOld.CertificateSHA256}}, metrics, "relay enrollment reload rejected")
	wantRoute(alice, 200, "alice-old")
	wantRoute(carol, 421, "")
	reload([]relay.Instance{aNew, b, c}, "", "settings require a restart")
	wantRoute(alice, 200, "alice-old")
	reload([]relay.Instance{aNew, b, c}, metrics, "relay enrollment reloaded (3 instances)")
	expectClosed("replaced alice certificate", aliceFirst)
	wantRoute(alice, 503, "")
	expectRejected("retired certificate reconnect", aliceOld)
	aliceSecond, carolFirst := connect(aliceNew, "alice-new"), connect(carolCert, "carol")
	wantRoute(alice, 200, "alice-new")
	wantRoute(carol, 200, "carol")
	code, _, err := status(carol, bob)
	must(err)
	check(code == 421, "SNI and authority mismatch routed to another tenant")
	close(streamGate)
	last, err := stream.ReadString('\n')
	must(err)
	check(last == "data: stream-end-bob\n", "reload interrupted the unchanged Bob stream")
	select {
	case <-bobFirst:
		panic("Bob's original connector ended")
	default:
	}

	reload([]relay.Instance{b, c}, metrics, "relay enrollment reloaded (2 instances)")
	expectClosed("revoked alice connector", aliceSecond)
	wantRoute(alice, 421, "")
	wantRoute(bob, 200, "bob")
	wantRoute(carol, 200, "carol")
	newest := hashes(configPath)
	stop()
	expectClosed("candidate shutdown released Bob", bobFirst)
	expectClosed("candidate shutdown released Carol", carolFirst)
	start(os.Args[1])
	check(hashes(configPath) == newest, "binary rollback changed the enrollment policy")
	wantRoute(bob, 503, "")
	wantRoute(alice, 421, "")
	expectRejected("original revoked Alice certificate after binary rollback", aliceOld)
	expectRejected("rotated revoked Alice certificate after binary rollback", aliceNew)
	bobFirst, carolFirst = connect(bobCert, "bob-rollback"), connect(carolCert, "carol-rollback")
	wantRoute(bob, 200, "bob-rollback")
	wantRoute(carol, 200, "carol-rollback")
	wantRoute(alice, 421, "")
	m, err := http.Get("http://" + metrics + "/metrics")
	must(err)
	metricData, err := io.ReadAll(m.Body)
	must(err)
	must(m.Body.Close())
	check(strings.Contains(string(metricData), "commander_relay_connected_hosts 2\n"), "incorrect connected count after rollback")
	fmt.Printf("Rolled back to previous executable while retaining SHA-256 %x of latest enrollment. Both revoked pins rejected, revoked hostname HTTP 421, both retained hosts authenticated and returned HTTP 200, connected hosts 2.\n", newest)
	reload([]relay.Instance{}, metrics, "relay enrollment reloaded (0 instances)")
	expectClosed("last revocation of Bob", bobFirst)
	expectClosed("last revocation of Carol", carolFirst)
	wantRoute(bob, 421, "")
	metricsResponse, err := http.Get("http://" + metrics + "/metrics")
	must(err)
	counts, err := io.ReadAll(metricsResponse.Body)
	_ = metricsResponse.Body.Close()
	must(err)
	check(strings.Contains(string(counts), "commander_relay_connected_hosts 0\n"), "metrics retained revoked connector")
	for _, marker := range []string{bearer, checkPath, streamPath} {
		check(!strings.Contains(logText(), marker) && !strings.Contains(string(counts), marker), "request data in relay telemetry")
	}
	fmt.Println("Linux SIGHUP verified invite, rejected invalid inventory and listener changes, rotated a connector, revoked all pins, and preserved the other tenant's original active stream.")
}

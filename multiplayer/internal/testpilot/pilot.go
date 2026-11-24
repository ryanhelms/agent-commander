package testpilot

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"agentcommander.network/pilot/internal/devicekeys"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Pilot struct {
	Edges        [2]string
	CAPath       string
	Roots        *x509.CertPool
	Issuer       string
	IssuerCAPath string
	IssuerRoots  *x509.CertPool
	DatabaseURL  string
	BrokerURL    string
}

func fixtureHTTP(roots *x509.CertPool) *http.Client {
	return &http.Client{Timeout: 15 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS13}}}
}

func (p *Pilot) OIDCHTTP() *http.Client { return fixtureHTTP(p.IssuerRoots) }
func (p *Pilot) Browser(subject string) func(string) error {
	return func(raw string) error {
		u, err := url.Parse(raw)
		if err != nil || u.Scheme+"://"+u.Host != p.Issuer || u.Path != "/authorize" {
			return errors.New("unexpected fixture authorization URL")
		}
		q := u.Query()
		q.Set("test_account", subject)
		u.RawQuery = q.Encode()
		httpc := p.OIDCHTTP()
		defer httpc.CloseIdleConnections()
		res, err := httpc.Get(u.String())
		if err != nil {
			return err
		}
		defer res.Body.Close()
		if res.StatusCode != 200 {
			return fmt.Errorf("test browser returned %d", res.StatusCode)
		}
		return nil
	}
}
func (p *Pilot) Client(t *testing.T, keys *devicekeys.Keys) *http.Client {
	t.Helper()
	cert, err := keys.TLSCertificate()
	if err != nil {
		t.Fatal(err)
	}
	client := fixtureHTTP(p.Roots)
	client.Transport.(*http.Transport).TLSClientConfig.Certificates = []tls.Certificate{cert}
	t.Cleanup(client.CloseIdleConnections)
	return client
}
func write(t *testing.T, path string, data []byte) string {
	t.Helper()
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	return path
}
func certificate(t *testing.T, dir string) (cert tls.Certificate, certPath, keyPath string, roots *x509.CertPool) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "pilot TLS fixture"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	crt := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	pemKey := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: raw})
	cert, err = tls.X509KeyPair(crt, pemKey)
	if err != nil {
		t.Fatal(err)
	}
	roots = x509.NewCertPool()
	roots.AppendCertsFromPEM(crt)
	return cert, write(t, filepath.Join(dir, "loopback.pem"), crt), write(t, filepath.Join(dir, "loopback-key.pem"), pemKey), roots
}
func fixtureBroker(t *testing.T) string {
	t.Helper()
	if uri := os.Getenv("PILOT_TEST_NATS_URL"); uri != "" {
		return uri
	}
	if os.Getenv("PILOT_TEST_DOCKER") != "1" {
		t.Skip("set PILOT_TEST_NATS_URL or PILOT_TEST_DOCKER=1 for an isolated authenticated JetStream broker")
	}
	password := randomID()
	name := "commander-test-" + strings.ToLower(randomID())
	cmd := exec.Command("docker", "run", "--rm", "--detach", "--name", name, "--publish", "127.0.0.1::4222", "nats:2.12-alpine", "-js", "--user", "pilot", "--pass", password)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("start NATS fixture: %v %s", err, out)
	}
	t.Cleanup(func() {
		if out, err := exec.Command("docker", "stop", "-t", "1", name).CombinedOutput(); err != nil {
			t.Errorf("stop fixture: %v %s", err, out)
		}
	})
	port, err := exec.Command("docker", "port", name, "4222/tcp").Output()
	if err != nil {
		t.Fatal(err)
	}
	return (&url.URL{Scheme: "nats", Host: strings.TrimSpace(string(port)), User: url.UserPassword("pilot", password)}).String()
}

// Start uses a dedicated schema and two independently executed relay binaries.
// Supply a disposable PostgreSQL database in PILOT_TEST_DATABASE_URL. A supplied
// PILOT_TEST_NATS_URL must identify a private broker account for this test.
func Start(t *testing.T) *Pilot {
	t.Helper()
	dsn := os.Getenv("PILOT_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set PILOT_TEST_DATABASE_URL and configure a disposable broker to run the network pilot")
	}
	t.Log("starting private network fixtures")
	broker := fixtureBroker(t)
	burl, err := url.Parse(broker)
	if err != nil || burl.User == nil {
		t.Fatal("PILOT_TEST_NATS_URL needs individual test credentials")
	}
	login := burl.User.Username()
	password, ok := burl.User.Password()
	if !ok {
		t.Fatal("broker password required")
	}
	burl.User = nil
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	admin, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(admin.Close)
	id := pgx.Identifier{"pilot_e2e_" + randomID()}.Sanitize()
	if _, err = admin.Exec(ctx, "CREATE SCHEMA "+id); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := admin.Exec(context.Background(), "DROP SCHEMA "+id+" CASCADE"); err != nil {
			t.Error(err)
		}
	})
	u, err := url.Parse(dsn)
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	q.Set("search_path", id)
	if q.Get("sslmode") == "" {
		q.Set("sslmode", "disable")
	}
	u.RawQuery = q.Encode()
	p := &Pilot{DatabaseURL: u.String(), BrokerURL: broker}
	dir := t.TempDir()
	_, crt, key, roots := certificate(t, dir)
	p.CAPath = crt
	p.Roots = roots
	issuer, issuerCA, _, issuerRoots := certificate(t, t.TempDir())
	p.Issuer = startIssuer(t, issuer)
	p.IssuerCAPath = issuerCA
	p.IssuerRoots = issuerRoots
	bin := os.Getenv("PILOT_TEST_RELAY_BIN")
	if bin == "" {
		_, current, _, ok := runtime.Caller(0)
		if !ok {
			t.Fatal("cannot locate multiplayer module")
		}
		bin = filepath.Join(dir, "commander-relay")
		buildCtx, stopBuild := context.WithTimeout(context.Background(), 5*time.Minute)
		defer stopBuild()
		build := exec.CommandContext(buildCtx, "go", "build", "-p", "2", "-o", bin, "./cmd/commander-relay")
		build.Dir = filepath.Join(filepath.Dir(current), "..", "..")
		t.Log("building relay executable")
		if out, err := build.CombinedOutput(); err != nil {
			t.Fatalf("build relay: %v %s", err, out)
		}
	}
	dbFile := write(t, filepath.Join(dir, "dsn"), []byte(p.DatabaseURL))
	brokerPass := write(t, filepath.Join(dir, "nats-password"), []byte(password))
	keys, err := devicekeys.Generate()
	if err != nil {
		t.Fatal(err)
	}
	hc := p.Client(t, keys)
	readyCtx, stopReady := context.WithTimeout(context.Background(), 2*time.Minute)
	defer stopReady()
	for i := range p.Edges {
		ln, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		addr := ln.Addr().String()
		_ = ln.Close()
		edge := fmt.Sprintf("pilot-%d", i+1)
		cfg := map[string]any{"edge": edge, "listen": addr, "certificate": crt, "private_key": key, "database_url_file": dbFile, "broker_urls": []string{burl.String()}, "broker_user": login, "broker_password_file": brokerPass, "issuer": p.Issuer, "client_id": "pilot-fixture", "issuer_ca": issuerCA, "loopback_test": true}
		raw, _ := json.Marshal(cfg)
		path := write(t, filepath.Join(dir, edge+".json"), raw)
		cmd := exec.Command(bin, "-config", path)
		var log bytes.Buffer
		cmd.Stdout = &log
		cmd.Stderr = &log
		cmd.Env = append(os.Environ(), "COMMANDER_EDGE_ID="+edge)
		if err = cmd.Start(); err != nil {
			t.Fatal(err)
		}
		done := make(chan error, 1)
		go func() { done <- cmd.Wait() }()
		t.Cleanup(func() {
			_ = cmd.Process.Signal(os.Interrupt)
			select {
			case <-done:
			case <-time.After(6 * time.Second):
				_ = cmd.Process.Kill()
				<-done
			}
		})
		t.Logf("waiting for %s", edge)
		p.Edges[i] = "https://" + addr
		ready := false
		for !ready {
			select {
			case err := <-done:
				done <- err
				t.Fatalf("edge exited: %v %s", err, log.String())
			case <-readyCtx.Done():
				t.Fatal("edge readiness timeout")
			default:
			}
			result, err := hc.Get(p.Edges[i] + "/ready")
			if err == nil {
				result.Body.Close()
				ready = result.StatusCode == 204
			}
			if !ready {
				time.Sleep(75 * time.Millisecond)
			}
		}
	}
	return p
}

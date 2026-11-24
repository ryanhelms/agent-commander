// commander-relay serves device enrollment and the multiplayer control plane on one TLS edge.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/dispatch"
	"agentcommander.network/pilot/internal/identity"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/nats-io/nats.go"
)

type config struct {
	Edge               string   `json:"edge"`
	Listen             string   `json:"listen"`
	Certificate        string   `json:"certificate"`
	PrivateKey         string   `json:"private_key"`
	DatabaseURLFile    string   `json:"database_url_file"`
	BrokerURLs         []string `json:"broker_urls"`
	BrokerUser         string   `json:"broker_user"`
	BrokerPasswordFile string   `json:"broker_password_file"`
	BrokerCA           string   `json:"broker_ca"`
	BrokerCertificate  string   `json:"broker_certificate"`
	BrokerKey          string   `json:"broker_key"`
	Replicas           int      `json:"replicas"`
	Issuer             string   `json:"issuer"`
	ClientID           string   `json:"client_id"`
	AllowedEmails      []string `json:"allowed_emails"`
	IssuerCA           string   `json:"issuer_ca"`
	// Only explicit IP loopback dependencies can use plaintext in an isolated rehearsal.
	LoopbackTest bool `json:"loopback_test"`
}

func readConfig(path string) (config, error) {
	var cfg config
	f, err := os.Open(path)
	if err != nil {
		return cfg, err
	}
	defer f.Close()
	dec := json.NewDecoder(io.LimitReader(f, 16385))
	dec.DisallowUnknownFields()
	if err = dec.Decode(&cfg); err != nil {
		return cfg, err
	}
	if err = dec.Decode(new(any)); err != io.EOF {
		return cfg, errors.New("expect a single edge configuration")
	}
	if edge := os.Getenv("COMMANDER_EDGE_ID"); edge != "" {
		cfg.Edge = edge
	}
	if cfg.Replicas == 0 {
		cfg.Replicas = 1
	}
	if !dispatch.ValidEdge(cfg.Edge) || cfg.Listen == "" || cfg.Replicas < 1 || cfg.Replicas > 5 {
		return cfg, errors.New("invalid edge id, listener or JetStream replica count")
	}
	return cfg, nil
}
func secretFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, 8193))
	if err != nil {
		return "", err
	}
	v := strings.TrimSpace(string(b))
	if v == "" || len(b) > 8192 {
		return "", errors.New("empty or oversized connection secret")
	}
	return v, nil
}
func roots(path string) (*x509.CertPool, error) {
	if path == "" {
		return nil, nil
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(content) {
		return nil, errors.New("invalid CA file")
	}
	return pool, nil
}
func loopback(host string) bool { ip := net.ParseIP(host); return ip != nil && ip.IsLoopback() }
func dialPool(ctx context.Context, cfg config) (*pgxpool.Pool, error) {
	raw, err := secretFile(cfg.DatabaseURLFile)
	if err != nil {
		return nil, err
	}
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" || (u.Scheme != "postgres" && u.Scheme != "postgresql") {
		return nil, errors.New("invalid database connection URL")
	}
	q := u.Query()
	// Deny libpq failover and query options that can override the verified target.
	if len(q["sslmode"]) != 1 || q.Has("host") || q.Has("hostaddr") || q.Has("service") || strings.Contains(u.Hostname(), ",") {
		return nil, errors.New("database URL must identify a single explicit TLS endpoint")
	}
	if q.Get("sslmode") != "verify-full" && !(cfg.LoopbackTest && loopback(u.Hostname()) && q.Get("sslmode") == "disable") {
		return nil, errors.New("database connection requires sslmode=verify-full")
	}
	p, err := pgxpool.New(ctx, raw)
	if err != nil {
		return nil, errors.New("database connection is invalid")
	}
	return p, nil
}
func connectBroker(cfg config) (*nats.Conn, error) {
	if len(cfg.BrokerURLs) == 0 {
		return nil, errors.New("at least one broker seed URL required")
	}
	scheme := ""
	for _, raw := range cfg.BrokerURLs {
		u, err := url.Parse(raw)
		if err != nil || u.Hostname() == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || strings.Contains(raw, ",") {
			return nil, errors.New("invalid broker seed URL")
		}
		if u.Scheme != "tls" && !(cfg.LoopbackTest && u.Scheme == "nats" && loopback(u.Hostname())) {
			return nil, errors.New("broker connection requires TLS")
		}
		if scheme != "" && scheme != u.Scheme {
			return nil, errors.New("mixed broker transports")
		}
		scheme = u.Scheme
	}
	password, err := secretFile(cfg.BrokerPasswordFile)
	if err != nil {
		return nil, err
	}
	if cfg.BrokerUser == "" {
		return nil, errors.New("broker user required")
	}
	opts := []nats.Option{nats.Name("commander-edge-" + cfg.Edge), nats.UserInfo(cfg.BrokerUser, password), nats.MaxReconnects(-1), nats.Timeout(4 * time.Second)}
	if scheme == "tls" {
		pool, err := roots(cfg.BrokerCA)
		if err != nil {
			return nil, err
		}
		t := &tls.Config{MinVersion: tls.VersionTLS13, RootCAs: pool}
		if cfg.BrokerCertificate != "" || cfg.BrokerKey != "" {
			cert, err := tls.LoadX509KeyPair(cfg.BrokerCertificate, cfg.BrokerKey)
			if err != nil {
				return nil, err
			}
			t.Certificates = []tls.Certificate{cert}
		}
		opts = append(opts, nats.Secure(t))
	}
	nc, err := nats.Connect(strings.Join(cfg.BrokerURLs, ","), opts...)
	if err != nil {
		return nil, errors.New("cannot authenticate to delivery broker")
	}
	return nc, nil
}

func serve(ctx context.Context, cfg config, listen net.Listener) error {
	cert, err := tls.LoadX509KeyPair(cfg.Certificate, cfg.PrivateKey)
	if err != nil {
		return err
	}
	startup, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	pool, err := dialPool(startup, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err = pool.Ping(startup); err != nil {
		return errors.New("cannot connect to multiplayer database")
	}
	nc, err := connectBroker(cfg)
	if err != nil {
		return err
	}
	defer nc.Close()
	ca, err := roots(cfg.IssuerCA)
	if err != nil {
		return err
	}
	httpClient := &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{Proxy: http.ProxyFromEnvironment, TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: ca}}}
	defer httpClient.CloseIdleConnections()
	auth, err := identity.New(startup, pool, identity.Config{AllowedEmails: cfg.AllowedEmails, Issuer: cfg.Issuer, ClientID: cfg.ClientID, HTTPClient: httpClient, AllowLoopbackHTTP: cfg.LoopbackTest})
	if err != nil {
		return errors.New("cannot initialize device identity; check issuer discovery and database settings")
	}
	store, err := control.New(startup, pool, cfg.Edge, auth.Authenticate, auth.DeviceActive)
	if err != nil {
		return fmt.Errorf("initialize control plane: %w", err)
	}
	auth.CanLookup = store.CanLookup
	if err = auth.SetRevocationHandler(startup, control.RevokeDevice); err != nil {
		return fmt.Errorf("reconcile revoked devices: %w", err)
	}
	mux := http.NewServeMux()
	auth.Register(mux)
	mux.Handle("/v1/", store.Handler())
	var brokerReady atomic.Bool
	mux.HandleFunc("GET /ready", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), time.Second)
		defer cancel()
		if !brokerReady.Load() || !nc.IsConnected() || pool.Ping(ctx) != nil {
			http.Error(w, "unavailable", 503)
			return
		}
		w.WriteHeader(204)
	})
	// The TLS handshake proves possession of a device's self-signed key. Enrollment
	// and each authenticated endpoint separately bind its fingerprint to an OIDC user.
	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 20 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 90 * time.Second, MaxHeaderBytes: 32768,
		TLSConfig: &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{cert}, ClientAuth: tls.RequireAnyClientCert,
			VerifyConnection: func(st tls.ConnectionState) error { _, err := identity.DeviceID(&st); return err }}, ErrorLog: log.New(io.Discard, "", 0)}
	runCtx, stop := context.WithCancel(ctx)
	defer stop()
	done := make(chan error, 2)
	go func() {
		done <- dispatch.Run(runCtx, nc, store, cfg.Edge, cfg.Replicas, func() { brokerReady.Store(true) })
	}()
	go func() { done <- srv.ServeTLS(listen, "", "") }()
	var first error
	received := 0
	select {
	case <-ctx.Done():
	case first = <-done:
		received++
	}
	stop()
	shutdown, finish := context.WithTimeout(context.Background(), 5*time.Second)
	defer finish()
	_ = srv.Shutdown(shutdown)
	_ = srv.Close()
	for ; received < 2; received++ {
		err = <-done
		if first == nil && err != nil && !errors.Is(err, http.ErrServerClosed) && !errors.Is(err, context.Canceled) {
			first = err
		}
	}
	if errors.Is(first, http.ErrServerClosed) || errors.Is(first, context.Canceled) {
		return nil
	}
	return first
}
func main() {
	f := flag.String("config", "", "path to edge JSON configuration")
	flag.Parse()
	cfg, err := readConfig(*f)
	if err != nil {
		log.Fatal(err)
	}
	ln, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		log.Fatal(err)
	}
	defer ln.Close()
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err = serve(ctx, cfg, ln); err != nil {
		log.Fatal(err)
	}
}

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
	Admins             []string `json:"admins"`
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
	httpClient := issuerClient(ca)
	defer httpClient.CloseIdleConnections()
	return serveRelay(ctx, listen, cert, pool, nc, relaySettings{
		edge: cfg.Edge, replicas: cfg.Replicas, mode: "edge", name: cfg.Edge,
		identity: identity.Config{AllowedEmails: cfg.AllowedEmails, Admins: cfg.Admins, Issuer: cfg.Issuer, ClientID: cfg.ClientID, HTTPClient: httpClient, AllowLoopbackHTTP: cfg.LoopbackTest},
	})
}

func issuerClient(ca *x509.CertPool) *http.Client {
	return &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{Proxy: http.ProxyFromEnvironment, TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: ca}}}
}

// Both deployments use the same identity, control store and dispatcher. Only
// the owner and transport of the PostgreSQL and NATS connections differ.
type relaySettings struct {
	edge, mode, name string
	replicas         int
	identity         identity.Config
}

func serveRelay(ctx context.Context, listen net.Listener, cert tls.Certificate, pool *pgxpool.Pool, nc *nats.Conn, cfg relaySettings) error {
	startup, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	auth, err := identity.New(startup, pool, cfg.identity)
	if err != nil {
		return errors.New("cannot initialize device identity; check issuer discovery and database settings")
	}
	store, err := control.New(startup, pool, cfg.edge, auth.Authenticate, auth.DeviceActive)
	if err != nil {
		return fmt.Errorf("initialize control plane: %w", err)
	}
	auth.CanLookup = store.CanLookup
	auth.CloseSession = control.CloseDeviceSession
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
	srv := relayServer(cert, cfg, mux, store.PublicSettings)
	runCtx, stop := context.WithCancel(ctx)
	defer stop()
	done := make(chan error, 2)
	pruned := make(chan struct{})
	go func() {
		defer close(pruned)
		tick := time.NewTicker(time.Hour)
		defer tick.Stop()
		for runCtx.Err() == nil {
			if err := store.PruneHistory(runCtx); err != nil && runCtx.Err() == nil {
				log.Printf("prune relay history: %v", err)
			}
			select {
			case <-runCtx.Done():
				return
			case <-tick.C:
			}
		}
	}()
	go func() {
		done <- dispatch.Run(runCtx, nc, store, cfg.edge, cfg.replicas, func() { brokerReady.Store(true) })
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
	<-pruned
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
func relayServer(cert tls.Certificate, cfg relaySettings, protected http.Handler, publicSettings func(context.Context) (control.PublicSettings, error)) *http.Server {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.EscapedPath() == "/v1/info" {
			settings, err := publicSettings(r.Context())
			if err != nil {
				http.Error(w, "membership unavailable", http.StatusServiceUnavailable)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Cache-Control", "no-store")
			_ = json.NewEncoder(w).Encode(map[string]any{
				"version": "1", "mode": cfg.mode, "name": cfg.name, "membership": settings.Membership,
				"adminContact": settings.AdminContact, "policy": settings.Policy,
				"issuer": cfg.identity.Issuer, "clientId": cfg.identity.ClientID,
			})
			return
		}
		// VerifyConnection checked every presented device certificate, including
		// on session resumption. Enforce possession before entering any other route.
		if r.TLS == nil || len(r.TLS.PeerCertificates) == 0 {
			http.Error(w, "device certificate required", http.StatusUnauthorized)
			return
		}
		protected.ServeHTTP(w, r)
	})
	return &http.Server{
		Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 20 * time.Second,
		WriteTimeout: 30 * time.Second, IdleTimeout: 90 * time.Second, MaxHeaderBytes: 32768,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{cert}, ClientAuth: tls.RequestClientCert,
			VerifyConnection: func(st tls.ConnectionState) error {
				if len(st.PeerCertificates) == 0 {
					return nil
				}
				_, err := identity.DeviceID(&st)
				return err
			},
		},
		ErrorLog: log.New(io.Discard, "", 0),
	}
}

func run(ctx context.Context, args []string) error {
	if len(args) > 0 && args[0] == "host" {
		return hostCommand(ctx, args[1:])
	}
	if len(args) > 0 && args[0] == "deploy" {
		return deployCommand(ctx, args[1:])
	}
	flags := flag.NewFlagSet("commander-relay", flag.ContinueOnError)
	path := flags.String("config", "", "path to edge JSON configuration")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *path == "" && flags.NArg() == 1 {
		*path = flags.Arg(0)
	} else if *path == "" || flags.NArg() != 0 {
		return errors.New("usage: commander-relay CONFIG.json | commander-relay host [init|install|uninstall|status|provision] [flags] | commander-relay deploy ...")
	}
	cfg, err := readConfig(*path)
	if err != nil {
		return err
	}
	ln, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		return err
	}
	defer ln.Close()
	return serve(ctx, cfg, ln)
}

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx, os.Args[1:]); err != nil && !errors.Is(err, flag.ErrHelp) {
		log.Fatal(err)
	}
}

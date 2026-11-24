package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/rand/v2"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"agentcommander/internal/hosted"
	"agentcommander/internal/relay"
)

type relayConnector struct {
	Address     string `json:"address"`
	Certificate string `json:"certificate"`
	PrivateKey  string `json:"private_key"`
	CA          string `json:"ca,omitempty"`
}

type hostedConfig struct {
	hosted.Config
	Relay *relayConnector `json:"relay,omitempty"`
}

type directHTTPS struct {
	server   *http.Server
	listener net.Listener
}

type hostedAccess struct {
	direct  *directHTTPS
	connect func(context.Context)
}

func prepareHosted(state string, handler http.Handler) (hostedAccess, error) {
	configPath := os.Getenv("AGENT_COMMANDER_HOSTED_CONFIG")
	if configPath == "" {
		return hostedAccess{}, nil
	}
	if err := checkHostedHTTPDebug(); err != nil {
		return hostedAccess{}, err
	}
	var config hostedConfig
	if err := readConfig(configPath, &config); err != nil {
		return hostedAccess{}, err
	}
	if config.Listen == "" && config.Relay == nil {
		return hostedAccess{}, errors.New("configure an HTTPS listener, a relay connector, or both")
	}
	gateway, err := hosted.New(config.Config, os.Getenv("AGENT_COMMANDER_OAUTH_INTROSPECTION_SECRET"), filepath.Join(state, "hosted-grants.json"))
	if err != nil {
		return hostedAccess{}, err
	}
	h := gateway.Handler(handler)
	var access hostedAccess
	if config.Relay != nil {
		connector, err := config.Relay.tlsConfig()
		if err != nil {
			return hostedAccess{}, err
		}
		access.connect = func(ctx context.Context) { maintainTunnel(ctx, config.Relay.Address, connector, h) }
	}
	if config.Listen == "" {
		return access, nil
	}
	cert, err := tls.LoadX509KeyPair(config.Certificate, config.PrivateKey)
	if err != nil {
		return hostedAccess{}, err
	}
	listener, err := net.Listen("tcp", config.Listen)
	if err != nil {
		return hostedAccess{}, err
	}
	access.direct = &directHTTPS{server: httpsServer(h, cert, tls.VersionTLS12), listener: listener}
	return access, nil
}

func (c relayConnector) tlsConfig() (*tls.Config, error) {
	host, port, err := net.SplitHostPort(c.Address)
	portNumber, portErr := strconv.ParseUint(port, 10, 16)
	if err != nil || host == "" || portErr != nil || portNumber == 0 {
		return nil, errors.New("relay connector address requires a host and numeric port")
	}
	cert, err := tls.LoadX509KeyPair(c.Certificate, c.PrivateKey)
	if err != nil {
		return nil, err
	}
	config := &tls.Config{ServerName: host, Certificates: []tls.Certificate{cert}}
	if c.CA != "" {
		ca, err := os.ReadFile(c.CA)
		if err != nil {
			return nil, err
		}
		config.RootCAs = x509.NewCertPool()
		if !config.RootCAs.AppendCertsFromPEM(ca) {
			return nil, errors.New("relay CA contains no PEM certificates")
		}
	}
	return config, nil
}

func maintainTunnel(ctx context.Context, address string, config *tls.Config, gateway http.Handler) {
	delay := time.Second
	for ctx.Err() == nil {
		started := time.Now()
		_ = relay.Connect(ctx, address, config, gateway)
		if time.Since(started) > 30*time.Second {
			delay = time.Second
		}
		timer := time.NewTimer(delay + rand.N(delay))
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
		delay = min(2*delay, 15*time.Second)
	}
}

func httpsServer(handler http.Handler, cert tls.Certificate, minVersion uint16) *http.Server {
	return &http.Server{
		Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second,
		IdleTimeout: 60 * time.Second, MaxHeaderBytes: 32 << 10,
		ErrorLog:  log.New(io.Discard, "", 0),
		TLSConfig: &tls.Config{MinVersion: minVersion, Certificates: []tls.Certificate{cert}},
	}
}

func checkHostedHTTPDebug() error {
	// The Go HTTP/2 package reads these flags at startup and can log decrypted
	// frames through the global logger, bypassing http.Server.ErrorLog.
	debug := os.Getenv("GODEBUG")
	if strings.Contains(debug, "http2debug=1") || strings.Contains(debug, "http2debug=2") {
		return errors.New("restart Commander with Go HTTP/2 debug logging disabled for hosted access or relay")
	}
	return nil
}

func readConfig(path string, target any) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return fmt.Errorf("invalid hosted or relay configuration: %w", err)
	}
	return nil
}

type relayConfig struct {
	relayListeners
	Instances []relay.Instance `json:"instances"`
}

type relayListeners struct {
	Listen            string `json:"listen"`
	Certificate       string `json:"certificate"`
	PrivateKey        string `json:"private_key"`
	TunnelListen      string `json:"tunnel_listen"`
	TunnelCertificate string `json:"tunnel_certificate"`
	TunnelPrivateKey  string `json:"tunnel_private_key"`
	MetricsListen     string `json:"metrics_listen,omitempty"`
}

func reloadRelayInstances(transport *relay.Relay, path string, listeners relayListeners) (int, error) {
	var candidate relayConfig
	if err := readConfig(path, &candidate); err != nil {
		return 0, err
	}
	if candidate.relayListeners != listeners {
		return 0, errors.New("relay listener and TLS settings require a restart")
	}
	if err := transport.ReplaceInstances(candidate.Instances); err != nil {
		return 0, err
	}
	return len(candidate.Instances), nil
}

type preparedRelay struct {
	config                   relayConfig
	transport                *relay.Relay
	public, tunnels, metrics *net.TCPAddr
	publicTLS, tunnelTLS     tls.Certificate
}

func prepareRelay(path string) (preparedRelay, error) {
	var prepared preparedRelay
	if err := checkHostedHTTPDebug(); err != nil {
		return prepared, err
	}
	config := &prepared.config
	if err := readConfig(path, config); err != nil {
		return prepared, err
	}
	if config.Listen == "" || config.TunnelListen == "" {
		return prepared, errors.New("relay requires separate public HTTPS and connector listener addresses")
	}
	var err error
	prepared.transport, err = relay.New(config.Instances)
	if err != nil {
		return prepared, err
	}
	prepared.public, err = net.ResolveTCPAddr("tcp", config.Listen)
	if err != nil {
		return prepared, fmt.Errorf("relay public address: %w", err)
	}
	prepared.tunnels, err = net.ResolveTCPAddr("tcp", config.TunnelListen)
	if err != nil {
		return prepared, fmt.Errorf("relay connector address: %w", err)
	}
	if prepared.public.Port != 0 && prepared.public.String() == prepared.tunnels.String() {
		return prepared, errors.New("relay public and connector addresses must be distinct")
	}
	if config.MetricsListen != "" {
		host, _, err := net.SplitHostPort(config.MetricsListen)
		if err != nil || !net.ParseIP(host).IsLoopback() {
			return prepared, errors.New("relay metrics address must use a loopback IP")
		}
		prepared.metrics, err = net.ResolveTCPAddr("tcp", config.MetricsListen)
		if err != nil {
			return prepared, fmt.Errorf("relay metrics address: %w", err)
		}
	}
	prepared.publicTLS, err = tls.LoadX509KeyPair(config.Certificate, config.PrivateKey)
	if err != nil {
		return prepared, fmt.Errorf("relay public TLS key pair: %w", err)
	}
	prepared.tunnelTLS, err = tls.LoadX509KeyPair(config.TunnelCertificate, config.TunnelPrivateKey)
	if err != nil {
		return prepared, fmt.Errorf("relay connector TLS key pair: %w", err)
	}
	return prepared, nil
}

func serveRelay(ctx context.Context, path string) error {
	prepared, err := prepareRelay(path)
	if err != nil {
		return err
	}
	transport := prepared.transport
	public, err := net.ListenTCP("tcp", prepared.public)
	if err != nil {
		return err
	}
	defer public.Close()
	tunnels, err := net.ListenTCP("tcp", prepared.tunnels)
	if err != nil {
		return err
	}
	defer tunnels.Close()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	server := httpsServer(transport, prepared.publicTLS, tls.VersionTLS13)
	defer server.Close()
	result := make(chan error, 3)
	if prepared.metrics != nil {
		listener, err := net.ListenTCP("tcp", prepared.metrics)
		if err != nil {
			return err
		}
		defer listener.Close()
		mux := http.NewServeMux()
		mux.HandleFunc("GET /metrics", transport.Metrics)
		metrics := &http.Server{
			Handler: mux, ReadHeaderTimeout: 3 * time.Second, WriteTimeout: 3 * time.Second,
			MaxHeaderBytes: 8 << 10, ErrorLog: log.New(io.Discard, "", 0),
		}
		defer metrics.Close()
		go func() { result <- metrics.Serve(listener) }()
	}
	reload := make(chan os.Signal, 1)
	signal.Notify(reload, syscall.SIGHUP)
	defer signal.Stop(reload)
	go func() { result <- transport.Accept(ctx, tunnels, prepared.tunnelTLS) }()
	go func() { result <- server.ServeTLS(public, "", "") }()
	for {
		select {
		case <-ctx.Done():
			return nil
		case err := <-result:
			return err
		case <-reload:
			count, err := reloadRelayInstances(transport, path, prepared.config.relayListeners)
			if err != nil {
				log.Print("relay enrollment reload rejected: ", err)
				continue
			}
			log.Printf("relay enrollment reloaded (%d instances)", count)
		}
	}
}

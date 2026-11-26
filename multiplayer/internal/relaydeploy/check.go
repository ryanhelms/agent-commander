package relaydeploy

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"time"

	"agentcommander.network/pilot/internal/device"
)

// CheckResult is what a connection check found.
type CheckResult struct {
	URL            string `json:"url"`
	TLS            string `json:"tls"`
	Pin            string `json:"pin"`
	Relay          string `json:"relay"`
	Name           string `json:"name"`
	Issuer         string `json:"issuer"`
	DeviceReady    int    `json:"device_ready"`
	AnonymousReady any    `json:"anonymous_ready"`
}

// Check does what Agent Commander does when it adds a server: it pins the
// server's key, reads /v1/info, then confirms that /ready answers a device
// certificate with HTTP 204 and refuses a client without one. address, when
// set, is dialled instead of resolving the URL's host.
func Check(ctx context.Context, raw, pin, address string) (CheckResult, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" {
		return CheckResult{}, errors.New("expected an https:// relay URL")
	}
	port := u.Port()
	if port == "" {
		port = "443"
	}
	dialAddr := net.JoinHostPort(u.Hostname(), port)
	if address != "" {
		dialAddr = net.JoinHostPort(address, port)
	}
	seen := ""
	client := func(cert *tls.Certificate) *http.Client {
		cfg := &tls.Config{MinVersion: tls.VersionTLS13, ServerName: u.Hostname(), InsecureSkipVerify: true,
			VerifyConnection: func(cs tls.ConnectionState) error {
				if len(cs.PeerCertificates) == 0 {
					return errors.New("the server sent no certificate")
				}
				got := device.SPKIPin(cs.PeerCertificates[0])
				if pin != "" && got != pin {
					return fmt.Errorf("server pin mismatch: expected %s, received %s", pin, got)
				}
				seen = got
				return nil
			}}
		if cert != nil {
			cfg.Certificates = []tls.Certificate{*cert}
		}
		dialer := &net.Dialer{Timeout: 10 * time.Second}
		return &http.Client{Timeout: 15 * time.Second, Transport: &http.Transport{TLSClientConfig: cfg, ForceAttemptHTTP2: false,
			DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
				return dialer.DialContext(ctx, network, dialAddr)
			}}}
	}
	get := func(c *http.Client, path string) (*http.Response, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.Scheme+"://"+u.Host+path, nil)
		if err != nil {
			return nil, err
		}
		return c.Do(req)
	}

	var info device.RelayInfo
	var tlsVersion string
	deadline := time.Now().Add(60 * time.Second)
	for {
		resp, err := get(client(nil), "/v1/info")
		if err == nil {
			tlsVersion = tls.VersionName(resp.TLS.Version)
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
			resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				return CheckResult{}, fmt.Errorf("/v1/info returned HTTP %d", resp.StatusCode)
			}
			if err := json.Unmarshal(body, &info); err != nil {
				return CheckResult{}, fmt.Errorf("/v1/info: %w", err)
			}
			break
		}
		if pin != "" && seen == "" && errors.Is(err, context.Canceled) || time.Now().After(deadline) {
			return CheckResult{}, err
		}
		select {
		case <-ctx.Done():
			return CheckResult{}, ctx.Err()
		case <-time.After(time.Second):
		}
	}
	pin = seen
	cert, err := deviceCertificate()
	if err != nil {
		return CheckResult{}, err
	}
	resp, err := get(client(&cert), "/ready")
	if err != nil {
		return CheckResult{}, fmt.Errorf("device-authenticated /ready: %w", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		return CheckResult{}, fmt.Errorf("device-authenticated /ready returned HTTP %d", resp.StatusCode)
	}
	var anonymous any = "refused"
	if resp, err := get(client(nil), "/ready"); err == nil {
		resp.Body.Close()
		if resp.StatusCode == http.StatusNoContent {
			return CheckResult{}, errors.New("/ready answered a client without a device certificate")
		}
		anonymous = resp.StatusCode
	}
	return CheckResult{URL: raw, TLS: tlsVersion, Pin: seen, Relay: info.Mode + " " + info.Version, Name: info.Name,
		Issuer: info.Issuer, DeviceReady: http.StatusNoContent, AnonymousReady: anonymous}, nil
}

// deviceCertificate makes a self-signed P-256 client certificate, as Agent
// Commander devices present.
func deviceCertificate() (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 62))
	if err != nil {
		return tls.Certificate{}, err
	}
	tmpl := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "Commander device"},
		NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(24 * time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
		BasicConstraintsValid: true}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, nil
}

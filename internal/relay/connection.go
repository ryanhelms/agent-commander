// Package relay forwards authorized Commander HTTPS requests over a host-initiated TLS connection.
package relay

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"sync"
	"time"
)

const (
	probePath    = "/relay/ready"
	tunnelOrigin = "http://commander"
	maxStreams   = 16
)

func protocols() *http.Protocols {
	p := new(http.Protocols)
	p.SetUnencryptedHTTP2(true)
	return p
}

func http2Limits() *http.HTTP2Config {
	return &http.HTTP2Config{
		MaxConcurrentStreams:          maxStreams,
		MaxReceiveBufferPerConnection: 256 << 10,
		MaxReceiveBufferPerStream:     64 << 10,
		SendPingTimeout:               10 * time.Second,
		PingTimeout:                   5 * time.Second,
		WriteByteTimeout:              8 * time.Second,
	}
}

// Retain the authenticated TLS channel while HTTP servers negotiate inner HTTP/2.
// Embedding net.Conn keeps the inner HTTP implementation from negotiating TLS again.
type tunnelConn struct {
	net.Conn
	done chan struct{}
	once sync.Once
}

func newTunnelConn(conn net.Conn) *tunnelConn {
	return &tunnelConn{Conn: conn, done: make(chan struct{})}
}

func (c *tunnelConn) Close() error {
	c.once.Do(func() { close(c.done) })
	return c.Conn.Close()
}

type tunnelListener struct {
	conn     *tunnelConn
	accepted bool
}

func (l *tunnelListener) Accept() (net.Conn, error) {
	if !l.accepted {
		l.accepted = true
		return l.conn, nil
	}
	<-l.conn.done
	return nil, net.ErrClosed
}

func (l *tunnelListener) Addr() net.Addr { return l.conn.LocalAddr() }
func (l *tunnelListener) Close() error   { return l.conn.Close() }

// Connect serves the hosted gateway on one authenticated outbound connection.
func Connect(ctx context.Context, address string, config *tls.Config, gateway http.Handler) error {
	config = config.Clone()
	config.MinVersion = tls.VersionTLS13
	config.NextProtos = []string{"commander-relay/1"}
	dialer := tls.Dialer{Config: config, NetDialer: &net.Dialer{Timeout: 5 * time.Second}}
	raw, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return err
	}
	conn := newTunnelConn(raw)
	defer conn.Close()
	state := raw.(*tls.Conn).ConnectionState()
	if state.NegotiatedProtocol != config.NextProtos[0] {
		return errors.New("relay did not negotiate the Commander tunnel")
	}
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	server := &http.Server{
		Protocols: protocols(), HTTP2: http2Limits(),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second,
		ErrorLog: log.New(io.Discard, "", 0),
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method == http.MethodGet && r.URL.Path == probePath {
				w.WriteHeader(http.StatusNoContent)
				return
			}
			if r.Context().Err() != nil {
				return
			}
			// The gateway receives the outer TLS state from this connector.
			r.TLS = &state
			gateway.ServeHTTP(w, r)
		}),
	}
	defer server.Close()
	return server.Serve(&tunnelListener{conn: conn})
}

package device

import (
	"io"
	"net"
	"sync"
	"testing"
)

// faultProxy is a TCP relay between a device and a relay edge. TLS passes
// through untouched; faults act on bytes, like a sleeping laptop or a
// broken network would.
type faultProxy struct {
	ln     net.Listener
	target string

	mu        sync.Mutex
	blackhole bool // forward device→relay, discard relay→device
	outage    bool // refuse new connections
	conns     map[net.Conn]struct{}
}

func newFaultProxy(t *testing.T, target string) *faultProxy {
	t.Helper()
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	p := &faultProxy{ln: ln, target: target, conns: map[net.Conn]struct{}{}}
	t.Cleanup(func() { ln.Close(); p.dropAll() })
	go p.serve()
	return p
}

func (p *faultProxy) addr() string { return p.ln.Addr().String() }

func (p *faultProxy) serve() {
	for {
		c, err := p.ln.Accept()
		if err != nil {
			return
		}
		p.mu.Lock()
		out := p.outage
		p.mu.Unlock()
		if out {
			c.Close()
			continue
		}
		go p.pipe(c)
	}
}

func (p *faultProxy) pipe(c net.Conn) {
	s, err := net.Dial("tcp4", p.target)
	if err != nil {
		c.Close()
		return
	}
	p.mu.Lock()
	p.conns[c], p.conns[s] = struct{}{}, struct{}{}
	p.mu.Unlock()
	defer func() {
		p.mu.Lock()
		delete(p.conns, c)
		delete(p.conns, s)
		p.mu.Unlock()
		c.Close()
		s.Close()
	}()
	go func() { io.Copy(s, c); s.Close() }()
	buf := make([]byte, 32<<10)
	for {
		n, err := s.Read(buf)
		if n > 0 {
			p.mu.Lock()
			drop := p.blackhole
			p.mu.Unlock()
			if !drop {
				if _, werr := c.Write(buf[:n]); werr != nil {
					return
				}
			}
		}
		if err != nil {
			return
		}
	}
}

func (p *faultProxy) set(blackhole, outage bool) {
	p.mu.Lock()
	p.blackhole, p.outage = blackhole, outage
	p.mu.Unlock()
}

// dropAll resets every open connection, as a network change or wake does.
func (p *faultProxy) dropAll() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for c := range p.conns {
		c.Close()
	}
}

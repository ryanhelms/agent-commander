package sshlink

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"sync"
	"testing"
	"time"
)

// The simulation measures wrapper framing under fixed propagation delay. It
// uses a bounded queue so a writer can send another frame while one is in flight.
type delayedFrame struct {
	data []byte
	at   time.Time
}

type delayedPipe struct {
	in, out      chan delayedFrame
	closed, peer chan struct{}
	delay        time.Duration
	closeOnce    sync.Once
	pending      []byte
}

func newDelayedPipe(rtt time.Duration) (*delayedPipe, *delayedPipe) {
	in, out := make(chan delayedFrame, 32), make(chan delayedFrame, 32)
	left, right := make(chan struct{}), make(chan struct{})
	return &delayedPipe{in: in, out: out, closed: left, peer: right, delay: rtt / 2},
		&delayedPipe{in: out, out: in, closed: right, peer: left, delay: rtt / 2}
}

func (p *delayedPipe) Write(data []byte) (int, error) {
	frame := delayedFrame{bytes.Clone(data), time.Now().Add(p.delay)}
	select {
	case <-p.closed:
		return 0, io.ErrClosedPipe
	case <-p.peer:
		return 0, io.ErrClosedPipe
	case p.out <- frame:
		return len(data), nil
	}
}

func (p *delayedPipe) Read(output []byte) (int, error) {
	if len(p.pending) == 0 {
		var frame delayedFrame
		select {
		case <-p.closed:
			return 0, io.ErrClosedPipe
		case frame = <-p.in:
		case <-p.peer:
			select {
			case frame = <-p.in:
			default:
				return 0, io.EOF
			}
		}
		time.Sleep(time.Until(frame.at))
		p.pending = frame.data
	}
	n := copy(output, p.pending)
	p.pending = p.pending[n:]
	return n, nil
}

func (p *delayedPipe) Close() error {
	p.closeOnce.Do(func() { close(p.closed) })
	return nil
}

func BenchmarkPersistentACPLink(b *testing.B) {
	const size = 512 << 10
	payload := bytes.Repeat([]byte("literal data\n$x."), size/16)
	for _, rtt := range []time.Duration{1, 10, 50, 100} {
		for _, window := range []bool{false, true} {
			b.Run(fmt.Sprintf("%dms/window=%t", rtt, window), func(b *testing.B) {
				b.SetBytes(int64(len(payload)))
				b.ReportAllocs()
				for range b.N {
					ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
					client, server := newDelayedPipe(rtt * time.Millisecond)
					host := NewHost(ctx, io.Discard, bytes.NewReader(payload))
					end := make(chan error, 1)
					go func() {
						end <- host.Serve(server)
						_ = server.Close()
					}()
					local, input := io.Pipe()
					var got bytes.Buffer
					dial := func(context.Context) (io.ReadWriteCloser, error) { return client, nil }
					err := RunWithOptions(ctx, local, &got, dial, nil, Options{PreferWindow: window})
					_ = input.Close()
					_ = local.Close()
					cancel()
					if err != nil || !bytes.Equal(got.Bytes(), payload) {
						b.Fatalf("transfer of %d bytes: %v", got.Len(), err)
					}
					if err := <-end; err != nil {
						b.Fatal(err)
					}
				}
			})
		}
	}
}

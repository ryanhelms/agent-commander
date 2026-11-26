package sshlink

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"sync"
	"time"
)

const (
	windowVersion = 2
	windowChunks  = (512 << 10) / chunkSize
)

// Frames carry independent cumulative acknowledgements and at most one data
// chunk. A link may be replaced while the endpoint still owns both cursors.
type windowFrame struct {
	Ack   uint64  `json:"ack"`
	Data  *packet `json:"data,omitempty"`
	Ended bool    `json:"ended,omitempty"`
	Error string  `json:"error,omitempty"`
}

type windowEndpoint struct {
	source <-chan []byte
	target io.Writer

	mu          sync.Mutex
	changed     chan struct{}
	pending     []*packet
	sentThrough uint64
	acked       uint64
	received    uint64
	sourceEnded bool
	failure     string
}

func newWindowEndpoint(source <-chan []byte, target io.Writer) *windowEndpoint {
	return &windowEndpoint{source: source, target: target, changed: make(chan struct{})}
}

func (e *windowEndpoint) signal() {
	close(e.changed)
	e.changed = make(chan struct{})
}

func (e *windowEndpoint) acknowledge(sequence uint64) bool {
	if sequence < e.acked || sequence > e.sentThrough {
		return false
	}
	if count := int(sequence - e.acked); count != 0 {
		copy(e.pending, e.pending[count:])
		clear(e.pending[len(e.pending)-count:])
		e.pending = e.pending[:len(e.pending)-count]
		e.acked = sequence
		e.signal()
	}
	return true
}

func (h *Host) serveWindow(stream io.ReadWriter, in *bufio.Scanner, out *json.Encoder, handshake request) error {
	link, ok := stream.(io.Closer)
	if !ok {
		return out.Encode(response{Error: "persistent ACP window requires a closable stream"})
	}
	if h.window == nil {
		h.window = newWindowEndpoint(h.output, h.input)
	}
	e := h.window
	e.mu.Lock()
	reply := response{InputAck: e.received, WindowVersion: windowVersion, Error: e.failure}
	if handshake.Input != nil || !e.acknowledge(handshake.OutputAck) {
		reply.Error = "invalid persistent ACP window cursor"
	}
	e.mu.Unlock()
	if err := out.Encode(reply); err != nil || reply.Error != "" {
		return err
	}
	err := e.run(h.ctx, link, in, out, true)
	if errors.Is(err, io.EOF) {
		return nil
	}
	return err
}

func attachWindow(ctx context.Context, stream io.Closer, in *bufio.Scanner, out *json.Encoder, e *windowEndpoint, connected func(bool)) error {
	e.mu.Lock()
	position := e.received
	e.mu.Unlock()
	if err := out.Encode(request{OutputAck: position, WindowVersion: windowVersion}); err != nil || !in.Scan() {
		return nil
	}
	var reply response
	if err := json.Unmarshal(in.Bytes(), &reply); err != nil {
		return err
	}
	if reply.Error != "" {
		return errors.New(reply.Error)
	}
	e.mu.Lock()
	ok := reply.WindowVersion == windowVersion && reply.Output == nil && !reply.Ended && e.acknowledge(reply.InputAck)
	e.mu.Unlock()
	if !ok {
		return errors.New("invalid persistent ACP window reconnect")
	}
	connected(true)
	return e.run(ctx, stream, in, out, false)
}

func (e *windowEndpoint) run(ctx context.Context, stream io.Closer, in *bufio.Scanner, out *json.Encoder, host bool) error {
	ctx, cancel := context.WithCancel(ctx)
	sent := make(chan error, 1)
	e.mu.Lock()
	sentAck := e.received
	e.mu.Unlock()
	go func() {
		sent <- e.send(ctx, out, host, sentAck)
		_ = stream.Close()
	}()
	readErr := e.receive(in)
	cancel()
	_ = stream.Close()
	sendErr := <-sent
	if readErr != nil {
		return readErr
	}
	return sendErr
}

func (e *windowEndpoint) receive(in *bufio.Scanner) error {
	for in.Scan() {
		var frame windowFrame
		if err := json.Unmarshal(in.Bytes(), &frame); err != nil {
			return err
		}
		if frame.Error != "" {
			return errors.New(frame.Error)
		}
		e.mu.Lock()
		if !e.acknowledge(frame.Ack) {
			e.mu.Unlock()
			return errors.New("invalid persistent ACP acknowledgement")
		}
		record := frame.Data
		if record == nil {
			e.mu.Unlock()
			if frame.Ended {
				return io.EOF
			}
			continue
		}
		if frame.Ended || record.Sequence != e.received+1 || len(record.Data) == 0 || len(record.Data) > chunkSize {
			e.mu.Unlock()
			return errors.New("invalid persistent ACP data sequence")
		}
		e.mu.Unlock()

		count, err := e.target.Write(record.Data)
		e.mu.Lock()
		if err != nil || count != len(record.Data) {
			e.failure = "persistent ACP endpoint did not accept a complete chunk"
			e.signal()
			e.mu.Unlock()
			return errors.New("persistent ACP endpoint did not accept a complete chunk")
		}
		e.received = record.Sequence
		e.signal()
		e.mu.Unlock()
	}
	return nil // loss of the link allows a reconnect to the same endpoint
}

func (e *windowEndpoint) send(ctx context.Context, out *json.Encoder, host bool, sentAck uint64) error {
	// The handshake independently confirmed both cursors before this link.
	e.mu.Lock()
	cursor := e.acked
	e.mu.Unlock()
	heartbeat := time.NewTicker(10 * time.Second)
	defer heartbeat.Stop()
	for ctx.Err() == nil {
		e.mu.Lock()
		var frame windowFrame
		frame.Ack, frame.Error = e.received, e.failure
		frame.Ended = e.sourceEnded && len(e.pending) == 0
		if cursor < e.acked {
			cursor = e.acked
		}
		if offset := int(cursor - e.acked); offset < len(e.pending) {
			frame.Data = e.pending[offset]
			cursor = frame.Data.Sequence
			e.sentThrough = max(e.sentThrough, cursor)
		}
		var source <-chan []byte
		if !e.sourceEnded && len(e.pending) < windowChunks {
			source = e.source
		}
		changed := e.changed
		e.mu.Unlock()

		if frame.Ended && !host {
			return io.EOF
		}
		if frame.Data != nil || frame.Ack != sentAck || frame.Error != "" || frame.Ended {
			if err := out.Encode(frame); err != nil {
				return nil // retry pending data over the replacement connection
			}
			if frame.Ended || frame.Error != "" {
				return io.EOF
			}
			sentAck = frame.Ack
			continue
		}
		select {
		case <-ctx.Done():
			return nil
		case <-changed:
		case <-heartbeat.C:
			if err := out.Encode(frame); err != nil {
				return nil
			}
		case data, ok := <-source:
			e.mu.Lock()
			if ok {
				sequence := e.acked + uint64(len(e.pending)) + 1
				e.pending = append(e.pending, &packet{Sequence: sequence, Data: data})
			} else {
				e.sourceEnded = true
			}
			e.mu.Unlock()
		}
	}
	return nil
}

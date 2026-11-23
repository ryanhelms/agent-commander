// Package sshlink keeps one adapter's input and output attached across SSH
// connections. An endpoint restart ends continuity. Transcripts are owned by
// the adapter and are never written by this package.
package sshlink

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
	"time"
)

const chunkSize = 32 << 10

type packet struct {
	Sequence uint64 `json:"sequence"`
	Data     []byte `json:"data"`
}

type request struct {
	OutputAck uint64  `json:"output_ack"`
	Input     *packet `json:"input,omitempty"`
}

type response struct {
	InputAck uint64  `json:"input_ack"`
	Output   *packet `json:"output,omitempty"`
	Ended    bool    `json:"ended,omitempty"`
	Error    string  `json:"error,omitempty"`
}

// Host owns the original adapter streams. Serve may be called again for a
// replacement connection. It never calls an adapter launcher.
type Host struct {
	input  io.Writer
	output <-chan []byte

	mu        sync.Mutex
	inputAck  uint64
	lastInput []byte
	writing   *packet
	written   chan bool
	outputAck uint64
	inFlight  *packet
	ended     bool
	failure   string
}

func NewHost(ctx context.Context, input io.Writer, output io.Reader) *Host {
	return &Host{input: input, output: readChunks(ctx, output)}
}

func readChunks(ctx context.Context, stream io.Reader) <-chan []byte {
	chunks := make(chan []byte)
	go func() {
		defer close(chunks)
		buffer := make([]byte, chunkSize)
		for {
			n, err := stream.Read(buffer)
			if n > 0 {
				select {
				case chunks <- bytes.Clone(buffer[:n]):
				case <-ctx.Done():
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()
	return chunks
}

func newScanner(stream io.Reader) *bufio.Scanner {
	scanner := bufio.NewScanner(stream)
	scanner.Buffer(make([]byte, 4096), 2*chunkSize)
	return scanner
}

// Serve processes a single link until the link ends. The Host retains its
// cursors so a replacement link can resolve an incomplete exchange.
func (h *Host) Serve(stream io.ReadWriter) error {
	in, out := newScanner(stream), json.NewEncoder(stream)
	for in.Scan() {
		var req request
		if err := json.Unmarshal(in.Bytes(), &req); err != nil {
			return fmt.Errorf("invalid SSH link frame: %w", err)
		}
		reply := h.exchange(req)
		if err := out.Encode(reply); err != nil {
			return err
		}
		if reply.Ended || reply.Error != "" {
			return nil
		}
	}
	return in.Err()
}

func (h *Host) exchange(req request) response {
	h.mu.Lock()
	defer h.mu.Unlock()

	if h.failure != "" {
		return response{Error: h.failure}
	}
	if h.writing != nil {
		select {
		case ok := <-h.written:
			if !ok {
				h.failure = "original adapter did not accept a complete input chunk"
				return response{Error: h.failure}
			}
			h.inputAck, h.lastInput = h.writing.Sequence, h.writing.Data
			h.writing = nil
		default:
		}
	}
	if h.inFlight != nil && req.OutputAck == h.inFlight.Sequence {
		h.outputAck, h.inFlight = req.OutputAck, nil
	}
	if req.OutputAck != h.outputAck {
		return response{Error: "output cursor does not match the original host endpoint"}
	}
	if p := req.Input; p != nil {
		if len(p.Data) == 0 || len(p.Data) > chunkSize {
			return response{Error: "invalid SSH input chunk"}
		}
		switch {
		case h.writing == nil && p.Sequence == h.inputAck+1:
			// Keep servicing output while the adapter reads input. A partial
			// write poisons the endpoint and is never attempted again.
			h.writing, h.written = p, make(chan bool, 1)
			go func(done chan<- bool) {
				n, err := h.input.Write(p.Data)
				done <- err == nil && n == len(p.Data)
			}(h.written)
		case h.writing != nil && p.Sequence == h.writing.Sequence && bytes.Equal(p.Data, h.writing.Data):
			// An acknowledgement can only follow the original write.
		case p.Sequence == h.inputAck && bytes.Equal(p.Data, h.lastInput):
			// The original write succeeded even if its acknowledgement was lost.
		default:
			return response{Error: "input cursor does not match the original host endpoint"}
		}
	}
	if h.inFlight == nil && !h.ended {
		select {
		case data, ok := <-h.output:
			if ok {
				h.inFlight = &packet{Sequence: h.outputAck + 1, Data: data}
			} else {
				h.ended = true
			}
		default:
		}
	}
	return response{InputAck: h.inputAck, Output: h.inFlight, Ended: h.ended}
}

type Dial func(context.Context) (io.ReadWriteCloser, error)

// Run relays one local adapter connection. A canceled context or EOF on the
// local adapter input ends the relay. Dial must only attach to the original
// Host. changed reports a transition after a successful exchange or link loss.
func Run(ctx context.Context, input io.Reader, output io.Writer, dial Dial, changed func(bool)) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	local := readChunks(ctx, input)
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	var req request
	var inputAck uint64
	connected := false
	setConnected := func(next bool) {
		if connected != next {
			connected = next
			if changed != nil {
				changed(next)
			}
		}
	}
	defer setConnected(false)
	for ctx.Err() == nil {
		err := func() error {
			stream, err := dial(ctx)
			if err != nil {
				return nil
			}
			defer stream.Close()
			unblock := context.AfterFunc(ctx, func() { _ = stream.Close() })
			defer unblock()
			in, out := newScanner(stream), json.NewEncoder(stream)
			for ctx.Err() == nil {
				if req.Input == nil {
					select {
					case b, ok := <-local:
						if !ok {
							return io.EOF
						}
						req.Input = &packet{Sequence: inputAck + 1, Data: b}
					default:
					}
				}
				if err := out.Encode(req); err != nil || !in.Scan() {
					return nil
				}
				var reply response
				if err := json.Unmarshal(in.Bytes(), &reply); err != nil {
					return fmt.Errorf("invalid SSH link response: %w", err)
				}
				if reply.Error != "" {
					return errors.New(reply.Error)
				}
				setConnected(true)
				switch {
				case req.Input != nil && reply.InputAck == req.Input.Sequence:
					inputAck, req.Input = reply.InputAck, nil
				case reply.InputAck != inputAck:
					return errors.New("host acknowledged an unexpected input sequence")
				}
				if p := reply.Output; p != nil {
					if p.Sequence != req.OutputAck+1 || len(p.Data) == 0 || len(p.Data) > chunkSize {
						return errors.New("host returned an unexpected output sequence")
					}
					n, err := output.Write(p.Data)
					if err != nil {
						return err
					}
					if n != len(p.Data) {
						return io.ErrShortWrite
					}
					req.OutputAck = p.Sequence
				}
				if reply.Ended {
					return io.EOF
				}
				if req.Input != nil && reply.Output == nil {
					select {
					case <-ctx.Done():
					case <-tick.C:
					}
				}
				if req.Input == nil && reply.Output == nil {
					select {
					case <-ctx.Done():
					case <-tick.C:
					case b, ok := <-local:
						if !ok {
							return io.EOF
						}
						req.Input = &packet{Sequence: inputAck + 1, Data: b}
					}
				}
			}
			return ctx.Err()
		}()
		setConnected(false)
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
		retry := time.NewTimer(time.Second)
		select {
		case <-ctx.Done():
		case <-retry.C:
		}
		retry.Stop()
	}
	return ctx.Err()
}

package sshlink

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"testing"
	"time"
)

func TestReconnectDoesNotRepeatAdapterInput(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	adapterOutput, sendOutput := io.Pipe()
	defer adapterOutput.Close()
	defer sendOutput.Close()
	var written bytes.Buffer
	host := NewHost(ctx, &written, adapterOutput)
	localInput, sendInput := io.Pipe()
	defer localInput.Close()
	defer sendInput.Close()

	links := 0
	dial := func(context.Context) (io.ReadWriteCloser, error) {
		links++
		client, server := net.Pipe()
		go func(first bool) {
			defer server.Close()
			var stream io.ReadWriter = server
			if first {
				stream = dropInputAcknowledgement{server}
			}
			_ = host.Serve(stream)
		}(links == 1)
		return client, nil
	}
	var displayed bytes.Buffer
	events := make(chan bool, 8)
	done := make(chan error, 1)
	go func() {
		done <- Run(ctx, localInput, &displayed, dial, func(state bool) { events <- state })
	}()
	expectState := func(expected bool) {
		t.Helper()
		select {
		case state := <-events:
			if state != expected {
				t.Fatalf("connection state = %t, want %t", state, expected)
			}
		case <-ctx.Done():
			t.Fatal("timed out waiting for connection transition")
		}
	}
	expectState(true)
	if _, err := io.WriteString(sendInput, "question reply"); err != nil {
		t.Fatal(err)
	}
	expectState(false)
	expectState(true)
	if _, err := io.WriteString(sendOutput, "received original answer"); err != nil {
		t.Fatal(err)
	}
	sendOutput.Close()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	host.mu.Lock()
	defer host.mu.Unlock()
	if written.String() != "question reply" || displayed.String() != "received original answer" || links != 2 {
		t.Fatalf("input = %q, output = %q, links = %d", &written, &displayed, links)
	}
}

type dropInputAcknowledgement struct{ net.Conn }

func (stream dropInputAcknowledgement) Write(data []byte) (int, error) {
	var reply response
	if err := json.Unmarshal(data, &reply); err != nil {
		return 0, err
	}
	if reply.InputAck > 0 {
		return 0, errors.New("injected link loss after original adapter write")
	}
	return stream.Conn.Write(data)
}

func TestOutputRemainsAvailableUntilAcknowledged(t *testing.T) {
	output := make(chan []byte, 1)
	output <- []byte("one chunk")
	close(output)
	host := Host{input: io.Discard, output: output}
	initial := host.exchange(request{})
	retry := host.exchange(request{})
	if initial.Output == nil || retry.Output != initial.Output {
		t.Fatalf("lost output awaiting acknowledgement: %+v, %+v", initial, retry)
	}
	if final := host.exchange(request{OutputAck: 1}); !final.Ended || final.Output != nil {
		t.Fatalf("replayed acknowledged output: %+v", final)
	}
}

func TestPartialAdapterWriteCannotBeRetried(t *testing.T) {
	input := &shortAdapterWriter{}
	host := &Host{input: input}
	req := request{Input: &packet{Sequence: 1, Data: []byte("a chunk")}}
	first := host.exchange(req)
	if first.InputAck != 0 {
		t.Fatal("input acknowledged before the write finished")
	}
	deadline := time.Now().Add(time.Second)
	for first.Error == "" && time.Now().Before(deadline) {
		first = host.exchange(req)
		time.Sleep(time.Millisecond)
	}
	retry := host.exchange(req)
	if first.Error == "" || retry.Error != first.Error || input.calls != 1 {
		t.Fatalf("partial write was retried or lost: %d calls, %+v, %+v", input.calls, first, retry)
	}
}

type shortAdapterWriter struct{ calls int }

func (w *shortAdapterWriter) Write(data []byte) (int, error) {
	w.calls++
	return len(data) / 2, io.ErrShortWrite
}

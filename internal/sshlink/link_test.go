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

func TestWindowedReconnectDoesNotRepeatAdapterInput(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
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
			var stream net.Conn = server
			if first {
				stream = dropWindowAcknowledgement{server}
			}
			_ = host.Serve(stream)
		}(links == 1)
		return client, nil
	}
	events := make(chan bool, 8)
	expectState := func(want bool) {
		t.Helper()
		select {
		case got := <-events:
			if got != want {
				t.Fatalf("connection state = %t, want %t", got, want)
			}
		case <-ctx.Done():
			t.Fatal("timed out waiting for connection transition")
		}
	}

	var displayed bytes.Buffer
	done := make(chan error, 1)
	go func() {
		done <- RunWithOptions(ctx, localInput, &displayed, dial, func(connected bool) {
			events <- connected
		}, Options{PreferWindow: true})
	}()
	expectState(true)
	if _, err := io.WriteString(sendInput, "addressed answer"); err != nil {
		t.Fatal(err)
	}
	expectState(false)
	expectState(true)
	payload := bytes.Repeat([]byte("literal newline\n and $ value\x00"), 20_000)
	if _, err := sendOutput.Write(payload); err != nil {
		t.Fatal(err)
	}
	sendOutput.Close()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if written.String() != "addressed answer" || !bytes.Equal(displayed.Bytes(), payload) || links != 2 {
		t.Fatalf("input %q, output bytes %d, links %d", &written, displayed.Len(), links)
	}
}

type dropWindowAcknowledgement struct{ net.Conn }

func (stream dropWindowAcknowledgement) Write(data []byte) (int, error) {
	var frame windowFrame
	if err := json.Unmarshal(data, &frame); err != nil {
		return 0, err
	}
	if frame.Ack > 0 {
		return 0, errors.New("injected loss after confirmed remote write")
	}
	return stream.Conn.Write(data)
}

func TestWindowOfferFallsBackToLegacyHost(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	client, server := net.Pipe()
	defer server.Close()
	output, endOutput := io.Pipe()
	defer output.Close()
	defer endOutput.Close()
	go func() {
		defer server.Close()
		var req request
		in, out := json.NewDecoder(server), json.NewEncoder(server)
		_ = in.Decode(&req)
		_ = out.Encode(response{Output: &packet{Sequence: 1, Data: []byte("legacy")}})
		_ = in.Decode(&req)
		_ = out.Encode(response{Ended: req.OutputAck == 1})
	}()
	var displayed bytes.Buffer
	err := RunWithOptions(ctx, output, &displayed, func(context.Context) (io.ReadWriteCloser, error) {
		return client, nil
	}, nil, Options{PreferWindow: true})
	if err != nil || displayed.String() != "legacy" {
		t.Fatalf("legacy result %q, error %v", &displayed, err)
	}
}

func TestWindowedPartialAdapterWriteStaysUnresolved(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	adapterOutput, sendOutput := io.Pipe()
	defer adapterOutput.Close()
	defer sendOutput.Close()
	adapterInput := &shortAdapterWriter{}
	host := NewHost(ctx, adapterInput, adapterOutput)
	localInput, sendInput := io.Pipe()
	defer localInput.Close()
	defer sendInput.Close()
	var links int
	accept := make(chan struct{}, 1)
	dial := func(context.Context) (io.ReadWriteCloser, error) {
		links++
		client, server := net.Pipe()
		go func() {
			accept <- struct{}{}
			_ = host.Serve(server)
			<-accept
			_ = server.Close()
		}()
		return client, nil
	}
	done := make(chan error, 1)
	go func() {
		done <- RunWithOptions(ctx, localInput, io.Discard, dial, nil, Options{PreferWindow: true})
	}()
	if _, err := io.WriteString(sendInput, "irrecoverably partial answer"); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err == nil || err.Error() != "persistent ACP endpoint did not accept a complete chunk" {
		t.Fatalf("partial result = %v", err)
	}
	if adapterInput.calls != 1 || links > 2 {
		t.Fatalf("partial input attempted %d times across %d links", adapterInput.calls, links)
	}
}

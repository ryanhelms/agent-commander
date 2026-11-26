package hostmode

import (
	"context"
	"testing"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go/jetstream"
)

func TestHostBrokerRestoresDeliveries(t *testing.T) {
	dir := t.TempDir()
	start := func(t *testing.T) jetstream.JetStream {
		t.Helper()
		nc, stop, err := StartBroker(dir)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(stop)
		srv, ok := nc.Opts.InProcessServer.(*server.Server)
		if !ok || srv.Addr() != nil {
			t.Fatal("host broker must use an in-process connection with no client listener")
		}
		js, err := jetstream.New(nc)
		if err != nil {
			t.Fatal(err)
		}
		return js
	}

	const subject = "commander.v1.delivery"
	const stream = "COMMANDER_DELIVERIES_V1"
	const child = "child-123"
	var seq uint64
	if !t.Run("publish", func(t *testing.T) {
		js := start(t)
		ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
		defer cancel()
		_, err := js.CreateStream(ctx, jetstream.StreamConfig{
			Name: stream, Subjects: []string{subject}, Storage: jetstream.FileStorage, Replicas: 1,
		})
		if err != nil {
			t.Fatal(err)
		}
		ack, err := js.Publish(ctx, subject, []byte(child))
		if err != nil {
			t.Fatal(err)
		}
		seq = ack.Sequence
	}) {
		return
	}
	t.Run("restart", func(t *testing.T) {
		js := start(t)
		ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
		defer cancel()
		s, err := js.Stream(ctx, stream)
		if err != nil {
			t.Fatal(err)
		}
		msg, err := s.GetMsg(ctx, seq)
		if err != nil {
			t.Fatal(err)
		}
		if msg.Subject != subject || string(msg.Data) != child {
			t.Fatalf("wrong delivery after restart: %q on %q", msg.Data, msg.Subject)
		}
	})
}

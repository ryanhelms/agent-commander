// Package dispatch publishes durable child IDs and wakes the edge holding a recipient lease.
package dispatch

import (
	"context"
	"errors"
	"fmt"
	"log"
	"regexp"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

type Store interface {
	PumpOne(context.Context, func(context.Context, string) error) (bool, error)
	Route(context.Context, string) (string, string, error)
	WakeDevice(string)
}

var edgeName = regexp.MustCompile("^[a-zA-Z0-9_-]{1,64}$")

func ValidEdge(id string) bool { return edgeName.MatchString(id) }

// Each replica runs the same three roles. A persisted child is always readable
// on reconnect, even if the recipient moved just as an edge received a wakeup.
func Run(ctx context.Context, nc *nats.Conn, store Store, edge string, replicas int, ready func()) error {
	if !ValidEdge(edge) || replicas < 1 || replicas > 5 {
		return errors.New("invalid edge ID or JetStream replica count")
	}
	js, err := jetstream.New(nc)
	if err != nil {
		return err
	}
	stream, err := js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
		Name: "COMMANDER_DELIVERIES_V1", Subjects: []string{"commander.v1.delivery"},
		Retention: jetstream.WorkQueuePolicy, Storage: jetstream.FileStorage,
		Replicas: replicas, MaxAge: 7 * 24 * time.Hour, MaxMsgSize: 512, Duplicates: 2 * time.Minute,
	})
	if err != nil {
		return fmt.Errorf("initialize delivery stream: %w", err)
	}
	consumer, err := stream.CreateOrUpdateConsumer(ctx, jetstream.ConsumerConfig{
		Durable: "commander_dispatchers_v1", AckPolicy: jetstream.AckExplicitPolicy,
		AckWait: 30 * time.Second, MaxAckPending: 256,
	})
	if err != nil {
		return fmt.Errorf("initialize delivery consumer: %w", err)
	}
	sub, err := nc.Subscribe("commander.v1.edge."+edge, func(m *nats.Msg) {
		if len(m.Data) > 0 && len(m.Data) <= 256 {
			store.WakeDevice(string(m.Data))
		}
	})
	if err != nil {
		return err
	}
	defer sub.Unsubscribe()
	if err = nc.FlushTimeout(5 * time.Second); err != nil {
		return err
	}
	cc, err := consumer.Consume(func(m jetstream.Msg) {
		task, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		owner, dev, err := store.Route(task, string(m.Data()))
		if err == nil && owner != "" {
			if !ValidEdge(owner) {
				_ = m.Term()
				return
			}
			if err = nc.Publish("commander.v1.edge."+owner, []byte(dev)); err == nil {
				err = nc.FlushWithContext(task)
			}
		}
		if err != nil {
			_ = m.NakWithDelay(time.Second)
			return
		}
		_ = m.Ack()
	}, jetstream.PullMaxMessages(16))
	if err != nil {
		return err
	}
	defer cc.Stop()
	ready()
	publish := func(ctx context.Context, id string) error {
		_, err := js.Publish(ctx, "commander.v1.delivery", []byte(id), jetstream.WithMsgID(id))
		return err
	}
	for ctx.Err() == nil {
		workctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		sent, err := store.PumpOne(workctx, publish)
		cancel()
		if sent && err == nil {
			continue
		}
		delay := 250 * time.Millisecond
		if err != nil {
			delay = time.Second
			if ctx.Err() == nil {
				log.Print("delivery outbox pending; retry scheduled")
			}
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(delay):
		}
	}
	return nil
}

package hostmode

import (
	"errors"
	"os"
	"path/filepath"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
)

// StartBroker opens a private JetStream store and connects via an in-memory
// connection. The returned function closes the client before stopping the broker.
func StartBroker(dir string) (*nats.Conn, func(), error) {
	store := filepath.Join(dir, "nats")
	if err := os.MkdirAll(store, 0700); err != nil {
		return nil, nil, err
	}
	s, err := server.NewServer(&server.Options{
		JetStream: true, StoreDir: store, DontListen: true, NoSigs: true,
	})
	if err != nil {
		return nil, nil, err
	}
	go s.Start()
	stop := func() {
		s.Shutdown()
		s.WaitForShutdown()
	}
	if !s.ReadyForConnections(10 * time.Second) {
		stop()
		return nil, nil, errors.New("embedded JetStream broker did not start")
	}
	nc, err := nats.Connect("", nats.InProcessServer(s), nats.Name("commander-host"))
	if err != nil {
		stop()
		return nil, nil, err
	}
	return nc, func() {
		nc.Close()
		stop()
	}, nil
}

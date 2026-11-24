//go:build pilotfixture

package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// The inspector runs on the backbone with the same scoped permissions as edge-a.
func streamProbe() error {
	ca, err := os.ReadFile("/run/relay/ca.pem")
	if err != nil {
		return err
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(ca) {
		return fmt.Errorf("invalid broker CA")
	}
	keys, err := tls.LoadX509KeyPair("/run/relay/workload.pem", "/run/relay/workload.key")
	if err != nil {
		return err
	}
	pw, err := os.ReadFile("/run/relay/broker-password")
	if err != nil {
		return err
	}
	nc, err := nats.Connect("tls://nats-a:4222,tls://nats-b:4222,tls://nats-c:4222", nats.Name("rehearsal-quorum-probe"), nats.Timeout(2*time.Second), nats.UserInfo("edge-a", strings.TrimSpace(string(pw))), nats.Secure(&tls.Config{MinVersion: tls.VersionTLS13, RootCAs: roots, Certificates: []tls.Certificate{keys}}))
	if err != nil {
		return err
	}
	defer nc.Close()
	js, err := jetstream.New(nc)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	stream, err := js.Stream(ctx, "COMMANDER_DELIVERIES_V1")
	if err != nil {
		return err
	}
	info, err := stream.Info(ctx)
	if err != nil {
		return err
	}
	if info.Config.Replicas != 3 || info.Cluster == nil || info.Cluster.Leader == "" {
		return fmt.Errorf("delivery stream has no three-replica leader")
	}
	ack, err := js.Publish(ctx, "commander.v1.delivery", []byte("rehearsal-probe-"+random()))
	if err != nil {
		return err
	}
	current := 1
	for _, p := range info.Cluster.Replicas {
		if p.Current && !p.Offline {
			current++
		}
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{"leader": info.Cluster.Leader, "replicas": info.Config.Replicas, "current": current, "sequence": ack.Sequence})
}

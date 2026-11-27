// commander-directory serves the opt-in public list of Commander relays.
// See design/COMMANDER-NETWORK-DISCOVERY.md, "Public directory".
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"agentcommander.network/pilot/internal/directory"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "commander-directory:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	fs := flag.NewFlagSet("commander-directory", flag.ContinueOnError)
	listen := fs.String("listen", ":443", "HTTPS listen address")
	cert := fs.String("cert", "", "TLS certificate chain (PEM) for the directory's public name")
	key := fs.String("key", "", "TLS private key (PEM)")
	state := fs.String("state", "", "JSON file that keeps listings across restarts")
	plain := fs.Bool("plain-http", false, "serve plain HTTP behind a TLS-terminating proxy on the same host")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if !*plain && (*cert == "" || *key == "") {
		return errors.New("--cert and --key are required unless --plain-http is set")
	}
	s := &directory.Server{State: *state, Log: log.Printf}
	if err := s.Load(); err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		t := time.NewTicker(10 * time.Minute)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				s.Prune()
			}
		}
	}()
	srv := &http.Server{
		Addr: *listen, Handler: s.Handler(),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 20 * time.Second, WriteTimeout: 40 * time.Second,
		IdleTimeout: 90 * time.Second, MaxHeaderBytes: 16384,
	}
	errc := make(chan error, 1)
	go func() {
		log.Printf("commander-directory listening on %s", *listen)
		if *plain {
			errc <- srv.ListenAndServe()
		} else {
			errc <- srv.ListenAndServeTLS(*cert, *key)
		}
	}()
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return srv.Shutdown(shutdown)
	}
}

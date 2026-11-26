package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"

	"agentcommander.network/pilot/internal/hostmode"
	"agentcommander.network/pilot/internal/identity"
)

func hostCommand(ctx context.Context, args []string) error {
	defaultDir, err := hostmode.DefaultDir()
	if err != nil {
		return err
	}
	flags := flag.NewFlagSet("commander-relay host", flag.ContinueOnError)
	dir := flags.String("dir", defaultDir, "host state directory")
	if err := flags.Parse(args); err != nil {
		return err
	}
	action := flags.Arg(0)
	var cfg hostmode.Config
	if action == "configure" {
		flags.StringVar(&cfg.Listen, "listen", "", "replace the HTTPS listen address")
		flags.Func("add-hostname", "add a certificate DNS name or IP (repeatable)", func(value string) error {
			cfg.Hostnames = append(cfg.Hostnames, value)
			return nil
		})
	}
	if action == "init" || action == "provision" {
		flags.StringVar(&cfg.Name, "name", "", "display name")
		flags.StringVar(&cfg.Listen, "listen", ":443", "HTTPS listen address")
		flags.StringVar(&cfg.Issuer, "issuer", "", "OIDC issuer URL")
		flags.StringVar(&cfg.ClientID, "client-id", "", "OIDC client ID")
		add := func(dst *[]string) func(string) error {
			return func(value string) error {
				*dst = append(*dst, value)
				return nil
			}
		}
		flags.Func("hostname", "certificate DNS name or IP (repeatable)", add(&cfg.Hostnames))
		flags.Func("allow-email", "allowed email (repeatable)", add(&cfg.AllowedEmails))
		flags.Func("admin", "administrator email (repeatable)", add(&cfg.Admins))
	}
	binary := ""
	if action == "provision" {
		binary = flags.Arg(1)
		if binary == "" {
			return errors.New("usage: commander-relay host provision BINARY [init flags]")
		}
		if err := flags.Parse(flags.Args()[2:]); err != nil {
			return err
		}
		if flags.NArg() != 0 {
			return fmt.Errorf("unexpected host argument %q", flags.Arg(0))
		}
	} else if flags.NArg() > 0 {
		if err := flags.Parse(flags.Args()[1:]); err != nil {
			return err
		}
		if flags.NArg() != 0 {
			return fmt.Errorf("unexpected host argument %q", flags.Arg(0))
		}
	}
	path, err := filepath.Abs(*dir)
	if err != nil {
		return err
	}
	switch action {
	case "init":
		return hostmode.InitConfig(path, cfg)
	case "configure":
		return hostmode.UpdateConfig(path, cfg.Hostnames, cfg.Listen)
	case "install":
		return hostmode.Install(path)
	case "provision":
		return hostmode.Provision(binary, cfg, func(msg string) { fmt.Fprintln(os.Stderr, "==>", msg) })
	case "uninstall":
		return hostmode.Uninstall()
	case "status":
		return hostmode.Status(path, os.Stdout)
	case "":
		client := issuerClient(nil)
		defer client.CloseIdleConnections()
		return serveHost(ctx, path, client)
	default:
		return fmt.Errorf("unknown host subcommand %q", action)
	}
}

func serveHost(ctx context.Context, dir string, client *http.Client) (err error) {
	cfg, err := hostmode.ReadConfig(dir)
	if err != nil {
		return fmt.Errorf("read host configuration (create it with commander-relay host init): %w", err)
	}
	ln, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		return err
	}
	defer ln.Close()
	lock, err := hostmode.LockHost(dir, ln.Addr())
	if err != nil {
		return err
	}
	defer lock.Close()
	cert, err := hostmode.EnsureTLS(dir, cfg.Hostnames)
	if err != nil {
		return fmt.Errorf("load host TLS identity: %w", err)
	}
	pg, err := hostmode.StartPostgres(ctx, dir)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, pg.Close()) }()
	nc, closeBroker, err := hostmode.StartBroker(dir)
	if err != nil {
		return err
	}
	defer closeBroker()

	runCtx, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)
	go func() {
		select {
		case <-pg.Done():
			cancel(errors.Join(errors.New("host PostgreSQL exited"), pg.Err()))
		case <-runCtx.Done():
		}
	}()
	err = serveRelay(runCtx, ln, cert, pg.Pool, nc, relaySettings{
		edge: "host", replicas: 1, mode: "host", name: cfg.Name,
		identity: identity.Config{AllowedEmails: cfg.AllowedEmails, Admins: cfg.Admins, Issuer: cfg.Issuer, ClientID: cfg.ClientID, HTTPClient: client},
	})
	if cause := context.Cause(runCtx); cause != nil && ctx.Err() == nil {
		return errors.Join(err, cause)
	}
	return err
}

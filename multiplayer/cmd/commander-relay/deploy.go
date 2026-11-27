package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"agentcommander.network/hostkit/sshx"
	"agentcommander.network/pilot/internal/relaydeploy"
)

const deployUsage = `usage:
  commander-relay deploy docker|systemd DESTINATION --hostname NAME --issuer URL --client-id ID --admin EMAIL [options]
  commander-relay deploy docker DESTINATION --tailnet-login-server URL --tailnet-auth-key-file KEY --issuer URL --client-id ID --admin EMAIL
  commander-relay deploy status docker|systemd DESTINATION
  commander-relay deploy remove docker|systemd DESTINATION
  commander-relay deploy connect https://relay.example.org [--pin sha256/...] [--address ADDR]
SSH options: --ssh-port N, -i KEY, -o NAME=VALUE (repeatable).`

type multi []string

func (m *multi) String() string     { return strings.Join(*m, ",") }
func (m *multi) Set(v string) error { *m = append(*m, v); return nil }

// sshFlags adds the SSH options remote.py accepted.
func sshFlags(fs *flag.FlagSet) func() []string {
	port := fs.String("ssh-port", "", "SSH port")
	identity := fs.String("i", "", "SSH private key")
	fs.String("identity", "", "SSH private key (alias of -i)")
	var options multi
	fs.Var(&options, "o", "extra ssh -o option; repeatable")
	fs.Var(&options, "ssh-option", "extra ssh -o option; repeatable")
	return func() []string {
		out := []string{"-o", "ConnectTimeout=15"}
		if *port != "" {
			out = append(out, "-p", *port)
		}
		id := *identity
		if f := fs.Lookup("identity"); id == "" && f != nil {
			id = f.Value.String()
		}
		if id != "" {
			out = append(out, "-i", id, "-o", "IdentitiesOnly=yes")
		}
		for _, o := range options {
			out = append(out, "-o", o)
		}
		return out
	}
}

// parseInterleaved parses flags that may come before or after positional
// arguments, as argparse did.
func parseInterleaved(fs *flag.FlagSet, args []string) ([]string, error) {
	var positional []string
	for {
		if err := fs.Parse(args); err != nil {
			return nil, err
		}
		if fs.NArg() == 0 {
			return positional, nil
		}
		positional = append(positional, fs.Arg(0))
		args = fs.Args()[1:]
	}
}

func deployCommand(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New(deployUsage)
	}
	switch args[0] {
	case "connect":
		fs := flag.NewFlagSet("deploy connect", flag.ContinueOnError)
		fs.SetOutput(io.Discard)
		pin := fs.String("pin", "", "expected server pin")
		address := fs.String("address", "", "address to dial instead of resolving the URL's host")
		pos, err := parseInterleaved(fs, args[1:])
		if err != nil || len(pos) != 1 {
			return errors.New(deployUsage)
		}
		res, err := relaydeploy.Check(ctx, pos[0], *pin, *address)
		if err != nil {
			return err
		}
		return printJSON(res)
	case "status", "remove":
		fs := flag.NewFlagSet("deploy "+args[0], flag.ContinueOnError)
		fs.SetOutput(io.Discard)
		opts := sshFlags(fs)
		pos, err := parseInterleaved(fs, args[1:])
		if err != nil || len(pos) != 2 {
			return errors.New(deployUsage)
		}
		target := sshx.Target{Destination: pos[1], Options: opts()}
		var text string
		if args[0] == "status" {
			text, err = relaydeploy.Status(ctx, pos[0], target)
		} else {
			text, err = relaydeploy.Remove(ctx, pos[0], target)
		}
		if err != nil {
			return err
		}
		fmt.Println(text)
		return nil
	}
	fs := flag.NewFlagSet("deploy", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	opts := sshFlags(fs)
	var o relaydeploy.Options
	var hostnames, admins, allow, tags multi
	fs.Var(&hostnames, "hostname", "DNS name or IP clients use; the first forms the URL; repeatable")
	fs.StringVar(&o.Config.Issuer, "issuer", "", "HTTPS OIDC issuer")
	fs.StringVar(&o.Config.ClientID, "client-id", "", "OIDC client ID of the desktop app")
	fs.StringVar(&o.ClientSecretFile, "client-secret-file", "", "Google Desktop OAuth file or bare installed-app secret the relay hands to devices at sign-in")
	fs.Var(&admins, "admin", "administrator email; repeatable")
	fs.Var(&allow, "allow-email", "allowed member email; repeatable")
	fs.StringVar(&o.Config.Name, "name", "", "display name; defaults to the first hostname")
	fs.IntVar(&o.Port, "port", 443, "public TCP port")
	fs.StringVar(&o.Bind, "bind", "", "bind address on the server")
	fs.BoolVar(&o.NoConnect, "no-connect", false, "skip the connection check")
	fs.StringVar(&o.PublicURL, "public-url", "", "URL clients use when a proxy or port mapping changes it")
	fs.StringVar(&o.ConnectAddress, "connect-address", "", "address to dial for the check")
	fs.StringVar(&o.Binary, "binary", "", "prebuilt Linux commander-relay for systemd mode")
	fs.StringVar(&o.Module, "module", "", "multiplayer module directory; found from the working directory by default")
	t := relaydeploy.Tailnet{Hostname: "agent-relay", LocalPort: 18443, Image: relaydeploy.TailscaleImage}
	fs.StringVar(&t.LoginServer, "tailnet-login-server", "", "Headscale or Tailscale control URL")
	fs.StringVar(&t.AuthKeyFile, "tailnet-auth-key-file", "", "pre-auth key file for the first join; otherwise TS_AUTHKEY")
	fs.StringVar(&t.Hostname, "tailnet-hostname", t.Hostname, "tailnet node name")
	fs.Var(&tags, "tailnet-tag", "tag to advertise; repeatable")
	fs.IntVar(&t.LocalPort, "tailnet-local-port", t.LocalPort, "loopback port behind tailscale serve")
	fs.StringVar(&t.Image, "tailnet-image", t.Image, "sidecar image")
	pos, err := parseInterleaved(fs, args)
	if err != nil || len(pos) != 2 {
		return errors.New(deployUsage)
	}
	if o.Config.Issuer == "" || o.Config.ClientID == "" || len(admins) == 0 {
		return errors.New("--issuer, --client-id and at least one --admin are required")
	}
	o.Mode = pos[0]
	o.Target = sshx.Target{Destination: pos[1], Options: opts()}
	o.Config.Hostnames, o.Config.Admins, o.Config.AllowedEmails = hostnames, admins, allow
	if t.LoginServer != "" {
		t.Tags = tags
		o.Tailnet = &t
	}
	if o.Module == "" && (o.Mode == "docker" || o.Binary == "") {
		if o.Module, err = findModule(); err != nil {
			return err
		}
	}
	o.Log = func(msg string) { fmt.Fprintln(os.Stderr, "==>", msg) }
	res, err := relaydeploy.Deploy(ctx, o)
	if res.URL != "" {
		_ = printJSON(res)
	}
	return err
}

// findModule locates the multiplayer module from the working directory: it
// or an ancestor, or a multiplayer directory beside one.
func findModule() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		for _, candidate := range []string{dir, filepath.Join(dir, "multiplayer")} {
			data, err := os.ReadFile(filepath.Join(candidate, "go.mod"))
			if err == nil && strings.HasPrefix(string(data), "module agentcommander.network/pilot\n") {
				return candidate, nil
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", errors.New("run from the repository, or pass --module with the multiplayer directory")
		}
		dir = parent
	}
}

func printJSON(v any) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

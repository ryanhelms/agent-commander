package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"agentcommander/internal/buildinfo"
	"agentcommander/internal/headless"
)

const hostUsage = `usage:
  On the server:
    agentctl host install [--sudo-linger] [--timeout DURATION] [--source FILE --version V]
    agentctl host doctor
    agentctl host status | rollback | remove
  From the Mac:
    agentctl host releases
    agentctl host deploy DESTINATION [--version V] [--force] [--sudo-linger] [--install-prerequisites]
    agentctl host status | rollback | remove DESTINATION
  DESTINATION is an OpenSSH destination such as ops@server or a host alias.`

// hostCommand runs a host subcommand. Without a destination it acts on this
// machine; with one it acts on that SSH host.
func hostCommand(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New(hostUsage)
	}
	verb, rest := args[0], args[1:]
	if remote, err := remoteHostCommand(ctx, verb, rest); remote {
		return err
	}
	layout, err := headless.DefaultLayout()
	if err != nil {
		return err
	}
	var report headless.Report
	switch verb {
	case "install":
		fs := flag.NewFlagSet("host install", flag.ContinueOnError)
		fs.SetOutput(io.Discard)
		sudoLinger := fs.Bool("sudo-linger", false, "enable linger with passwordless sudo")
		timeout := fs.Duration("timeout", 30*time.Second, "health wait")
		source := fs.String("source", "", "install this agentctl binary instead of the running one")
		version := fs.String("version", "", "the release tag of --source")
		if err := fs.Parse(rest); err != nil || fs.NArg() != 0 || (*source == "") != (*version == "") {
			return errors.New(hostUsage)
		}
		if *source == "" {
			exe, err := os.Executable()
			if err != nil {
				return err
			}
			*source, *version = exe, buildinfo.Current()
		}
		layout.SudoLinger = *sudoLinger
		report = layout.Install(ctx, headless.Options{Source: *source, Version: *version, Timeout: *timeout})
	case "doctor":
		if len(rest) != 0 {
			return errors.New(hostUsage)
		}
		report = layout.Doctor(ctx)
	case "status":
		report = layout.Status(ctx)
	case "rollback":
		report = layout.Rollback(ctx, 30*time.Second)
	case "remove":
		report = layout.Remove()
	default:
		return errors.New(hostUsage)
	}
	return printReport(report)
}

func printReport(report headless.Report) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(report); err != nil {
		return err
	}
	if !report.OK {
		return reportError(report)
	}
	return nil
}

func reportError(report headless.Report) error {
	for _, s := range report.Steps {
		if s.Required && !s.OK {
			if s.Fix != "" {
				return fmt.Errorf("%s: %s (fix: %s)", s.Step, s.Detail, s.Fix)
			}
			return fmt.Errorf("%s: %s", s.Step, s.Detail)
		}
	}
	return errors.New("the operation did not complete")
}

// remoteHostCommand handles the Mac-side forms. It reports false when verb
// and args name a local operation.
func remoteHostCommand(ctx context.Context, verb string, args []string) (bool, error) {
	switch verb {
	case "releases", "deploy":
		return true, errors.New("agentctl host " + verb + " is not available yet")
	case "status", "rollback", "remove":
		if len(args) == 1 {
			return true, errors.New("agentctl host " + verb + " DESTINATION is not available yet")
		}
	}
	return false, nil
}

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

	"agentcommander.network/hostkit/release"
	"agentcommander.network/hostkit/sshx"

	"agentcommander/internal/buildinfo"
	"agentcommander/internal/headless"
	"agentcommander/internal/hostdeploy"
)

const hostUsage = `usage:
  On the server:
    agentctl host install [--sudo-linger] [--timeout DURATION] [--source FILE --version V]
    agentctl host doctor
    agentctl host status | rollback | remove
    agentctl host version
  From the Mac:
    agentctl host releases [--repo OWNER/NAME]
    agentctl host deploy DESTINATION [--version V] [--force] [--sudo-linger] [--install-prerequisites]
                         [--archive FILE --sums SHA256SUMS]
    agentctl host status | rollback | remove DESTINATION
  DESTINATION is an OpenSSH destination such as ops@server or a host alias.
  SSH options: --ssh-port N, -i KEY, -F CONFIG, -o NAME=VALUE.`

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
	case "version":
		enc := json.NewEncoder(os.Stdout)
		return enc.Encode(map[string]any{"version": buildinfo.Current(), "api": buildinfo.APIVersion})
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
	case "releases":
		fs, src := releaseFlags("host releases")
		if err := fs.Parse(args); err != nil || fs.NArg() != 0 {
			return true, errors.New(hostUsage)
		}
		return true, listReleases(ctx, *src)
	case "deploy":
		fs, src := releaseFlags("host deploy")
		version := fs.String("version", "", "release tag; default the newest release with headless assets")
		force := fs.Bool("force", false, "deploy even when the API version differs")
		sudoLinger := fs.Bool("sudo-linger", false, "enable linger with passwordless sudo on the server")
		prereq := fs.Bool("install-prerequisites", false, "install git, tmux and curl with the server's package manager")
		archive := fs.String("archive", "", "deploy this local headless archive instead of a release")
		sums := fs.String("sums", "", "SHA256SUMS for --archive")
		target, err := parseTarget(fs, args)
		if err != nil {
			return true, err
		}
		if (*archive == "") != (*sums == "") {
			return true, errors.New("--archive and --sums go together")
		}
		result := hostdeploy.Deploy(ctx, hostdeploy.Options{Target: target, Source: *src, Version: *version,
			Archive: *archive, Sums: *sums, Force: *force, SudoLinger: *sudoLinger, InstallPrerequisites: *prereq,
			Progress: func(s headless.Step) {
				mark := "ok"
				if !s.OK {
					mark = "--"
					if s.Required {
						mark = "!!"
					}
				}
				fmt.Fprintf(os.Stderr, "%s %-14s %s\n", mark, s.Step, s.Detail)
			}})
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		if err := enc.Encode(result); err != nil {
			return true, err
		}
		if !result.OK {
			return true, fmt.Errorf("deploy to %s failed", target.Destination)
		}
		return true, nil
	case "status", "rollback", "remove":
		if len(args) == 0 {
			return false, nil
		}
		fs := flag.NewFlagSet("host "+verb, flag.ContinueOnError)
		target, err := parseTarget(fs, args)
		if err != nil {
			return true, err
		}
		report, err := hostdeploy.Remote(ctx, target, verb)
		if err != nil {
			return true, err
		}
		return true, printReport(report)
	}
	return false, nil
}

func releaseFlags(name string) (*flag.FlagSet, *release.Source) {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	src := &release.Source{}
	fs.StringVar(&src.Repo, "repo", envOr("AGENT_COMMANDER_REPO", hostdeploy.DefaultRepo), "GitHub repository owner/name")
	fs.StringVar(&src.Mirror, "mirror", os.Getenv("AGENT_COMMANDER_RELEASE_MIRROR"), "read releases from this directory or URL")
	return fs, src
}

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

// parseTarget reads ssh options and one destination. Flags may come before
// or after the destination.
func parseTarget(fs *flag.FlagSet, args []string) (sshx.Target, error) {
	fs.SetOutput(io.Discard)
	var options []string
	addOpt := func(flagName string) func(string) error {
		return func(v string) error { options = append(options, flagName, v); return nil }
	}
	fs.Func("ssh-port", "SSH port", addOpt("-p"))
	fs.Func("i", "SSH identity file", addOpt("-i"))
	fs.Func("F", "SSH config file", addOpt("-F"))
	fs.Func("o", "SSH option NAME=VALUE", addOpt("-o"))
	var destination string
	for {
		if err := fs.Parse(args); err != nil {
			return sshx.Target{}, errors.New(hostUsage)
		}
		if fs.NArg() == 0 {
			break
		}
		if destination != "" {
			return sshx.Target{}, errors.New(hostUsage)
		}
		destination, args = fs.Arg(0), fs.Args()[1:]
	}
	if destination == "" {
		return sshx.Target{}, errors.New(hostUsage)
	}
	return sshx.Target{Destination: destination, Options: options}, nil
}

func listReleases(ctx context.Context, src release.Source) error {
	all, err := src.List(ctx)
	if err != nil {
		return err
	}
	type row struct {
		Tag        string   `json:"tag"`
		Prerelease bool     `json:"prerelease"`
		Published  string   `json:"published"`
		Headless   []string `json:"headless"`
	}
	rows := []row{}
	for _, r := range all {
		var arches []string
		for _, arch := range []string{"amd64", "arm64"} {
			if r.Has(hostdeploy.ArchiveName(arch), "SHA256SUMS") {
				arches = append(arches, arch)
			}
		}
		if len(arches) > 0 {
			rows = append(rows, row{r.Tag, r.Prerelease, r.PublishedAt.Format("2006-01-02"), arches})
		}
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(rows)
}

# Headless Commander on Linux

Status: accepted, 2026-11-26. Tracked in [issue #50](https://github.com/ryanhelms/agent-commander/issues/50). Part of milestone M4 in the [MVP plan](../MVP-PLAN.md).

## Goal

A developer runs the Commander service, with no app, on a Linux server and supervises it from Agent Commander on their Mac. There are two ways to install it:

1. **One line on the server.** Run a single command that comes from the GitHub repository. It installs the latest release, or a release you name.
2. **From Agent Commander.** The app or `agentctl` lists the repository's GitHub releases. It deploys, upgrades or rolls back any of them to an SSH host, with no manual steps.

Deploying is a product feature, written in Go. The Python relay deploy tool (`multiplayer/deploy/remote/remote.py`) moves to the same Go code and is then removed.

## What exists today

| Piece | State |
| --- | --- |
| `agentctl serve` | The full Commander service. Nothing in it builds only on macOS, but it has never run as a long-lived service on Linux. |
| `agentctl-linux-amd64` and `-arm64` | Built by `packaging/relay-release.py` and placed inside the relay archives. They are not published as release assets of their own. |
| SSH workers | The Mac's service starts Claude on an SSH host, through `internal/sshlink` and a reverse Unix socket. The service itself stays on the Mac. |
| `hostmode.Install` | The relay's supervisor adapters (launchd, systemd, Docker), in `multiplayer/internal/hostmode`. Go's `internal` rule stops `cmd/agentctl` from importing them, so the systemd adapter moves to a shared package first. |
| `remote.py` | Python. Deploys `commander-relay host` over SSH as a systemd service or a Docker container, with an optional tailnet sidecar. |
| GitHub releases | `build.yml` publishes prereleases from `v*-*` tags. None are published yet. |

## Constraint: the repository is private

The repository is private, so its release assets need a GitHub credential to download. An anonymous `curl … | sh` fails with HTTP 404. Choose one of these before building the one-liner:

| Option | One-liner on the server | Trade-off |
| --- | --- | --- |
| **A. Publish headless assets publicly** (a public `agent-commander-releases` repository, or make this one public) | `curl -fsSL https://github.com/ryanhelms/agent-commander-releases/releases/latest/download/install.sh \| sh` | Simplest. The binaries become public. Source stays private. |
| **B. Use the server's `gh` login** | `gh release download -R ryanhelms/agent-commander -p install.sh -O - \| sh` | Works now. The server needs `gh` and a login with read access. |
| **C. Push from the Mac only** | none on the server; `agentctl host deploy user@server` on the Mac | The server needs no GitHub access or token. There is no server-side one-liner. |

**Decision: support both B and C.** C is built first, because it needs no change to the repository's access and keeps tokens off servers. B is the server one-liner while the repository is private. When the repository becomes public, A replaces B with the same `install.sh`. Only the download step changes: `install.sh` uses `gh release download` when `gh` is logged in and falls back to an anonymous HTTPS download, so it already works for A.

## Release assets

Add these assets to each release built by `build.yml`, and list them in `SHA256SUMS`:

- `agent-commander-headless-linux-amd64.tar.gz` and `agent-commander-headless-linux-arm64.tar.gz`. Each holds the static `agentctl` binary, the systemd unit template and a `VERSION` file that records the Commander version and the API version.
- `install.sh`. This is the only part not written in Go, because a new server has no Go binary yet. It is short POSIX `sh` that does four things: detect the architecture, download the archive and `SHA256SUMS`, verify the checksum, and run `agentctl host install`. Everything after that runs in Go.

Also add a GitHub artifact attestation for each archive (`actions/attest-build-provenance`). Then a checksum file taken from the same release is not the only proof that a release is genuine, and `gh attestation verify` can check it.

## Commands

All of these live in `agentctl`, under one `host` command group. Each one runs on the Mac and acts on the server over the system OpenSSH client, so it keeps the user's host aliases, jump hosts and keys.

```sh
agentctl host releases                      # list GitHub releases with headless assets
agentctl host deploy ops@server             # install or upgrade to the latest release
agentctl host deploy ops@server --version v0.2.0-pilot.3
agentctl host status ops@server             # version, service state, API version, prerequisites
agentctl host rollback ops@server           # switch back to the previous installed version
agentctl host remove ops@server             # stop and remove the unit; keep the state directory
```

These commands run on the server itself. `install.sh` calls the first one:

```sh
agentctl host install [--version V]         # install from the local archive and start the unit
agentctl host doctor                        # check tmux, Node, Claude Code, the ACP adapter and the Claude login
```

`deploy` does these steps in order:

1. Read the release list through the GitHub REST API. Use the user's `gh` login or a token stored in the Keychain. List prereleases, because every release is a prerelease today.
2. Download the archive for the server's architecture. Verify `SHA256SUMS` and the attestation.
3. Check that the release's API version is compatible with this Mac's app. Refuse an incompatible release unless `--force` is given.
4. Stream the archive to the server over SSH standard input. Unpack it into `~/.local/share/agent-commander/versions/<version>/`.
5. Run `agentctl host doctor` on the server. Report what is missing. Do not install system packages without `--install-prerequisites`.
6. Switch the `current` link to the new version, restart the unit, and wait for the service to report healthy.
7. If it is not healthy, switch back to the previous version and report the failure.

Each step reports a result, the same way the tray's **Add server** check reports DNS, TCP, TLS, relay and sign-in. The app can then show the steps as they run.

## On the server

- **Unit.** A systemd user unit, `agent-commander.service`, runs `agentctl serve` as the SSH user. Claude's login, tmux sessions and project checkouts all belong to that user. Linger (`loginctl enable-linger`) keeps the service running after the user logs out. This needs `sudo` once, and `deploy` asks before it runs it.
- **State.** `~/.local/share/agent-commander/`. Deploying, upgrading and rolling back never touch run state. Rollback keeps the old version's files, because running workers may still use them. This follows the ACP binary activation rule in [PATTERN-DECISIONS.md](PATTERN-DECISIONS.md).
- **Prerequisites.** tmux, Node 24, Claude Code and the pinned `claude-agent-acp` adapter. Codex is optional. The adapter installs through the existing ACP package adapter with hashed, pinned packages. The Claude sign-in stays manual: `doctor` says when it is missing, and the user runs `claude` once on the server.

## Connecting the Mac to a headless Commander

The MVP serves one user over local connections and SSH tunnels. Use the same here:

1. **SSH-forwarded Unix socket (first increment).** The app forwards the server's `AGENT_COMMANDER_SOCKET` to a local socket over SSH and talks to it as it talks to the local service. This needs no new authentication. While SSH is down, the server keeps running workers and holds pending questions.
2. **Through a relay (later).** The headless service runs `agentctl relay` and connects out to a Commander relay. The app reaches it with the existing OAuth scopes. This needs no inbound port, and other people can share access.

The app shows a headless host as its own entry, next to the local service, with its version and connection state. This is new interface work. It goes to the frontend agent, and DESIGN.md gets updated in the same change.

## Port the relay deploy to Go

Move `remote.py deploy|status|remove|connect` into `commander-relay deploy …`. Share one Go package, `internal/hostdeploy`, with `agentctl host`. That package handles SSH transport, release selection, checksum and attestation checks, and step reports. The supervisor adapters move out of `multiplayer/internal/hostmode` to a package that both binaries can import. `connect` reuses the Go probe that the tray already runs, instead of the Python copy. Port `testhosts/rehearse.py` to a Go test that uses the existing Docker test hosts. Remove `remote.py` once the Go version handles systemd, Docker and the tailnet sidecar.

The other Python build scripts (`packaging/*.py`, `multiplayer/deploy/prepare.py`, the rehearsal lab) are build tooling, not product features, and stay out of scope.

## Increments

1. **Headless service on Linux.** `agentctl serve` under a systemd user unit, plus `host install` and `host doctor`. Test it in the Linux Docker host from [ssh-worker.md](verification/ssh-worker.md).
2. **Release assets.** Headless archives, `install.sh`, checksums and attestations in `build.yml`. Publish one prerelease.
3. **Mac-driven deploy.** `agentctl host releases|deploy|status|rollback|remove`, with the compatibility check and automatic rollback.
4. **Connect.** The app reaches a headless host through an SSH-forwarded socket and shows it as a host. This includes the frontend design work.
5. **Relay deploy in Go.** `commander-relay deploy` on `internal/hostdeploy`. Remove `remote.py`.
6. **Server one-liner.** `install.sh` through `gh release download` (option B). It needs no further change when the repository becomes public.

## Decisions

- **Made:** release access supports B (`gh` on the server) and C (push from the Mac). A follows when the repository becomes public.
- **Made:** headless hosts are part of milestone M4 in the [MVP plan](../MVP-PLAN.md).

## Not in scope

- macOS servers (a launchd version of the same unit).
- More than one user on one headless service.
- Automatic upgrades with no user action. `deploy` always runs because a person or a coordinator asked for it.

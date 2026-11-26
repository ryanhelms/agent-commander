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
| `remote.py` | Was Python. Now `commander-relay deploy`, in Go. |
| GitHub releases | `build.yml` publishes prereleases from `v*-*` tags. v0.1.0-pilot.4 was the first. |

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

The workflow does not request GitHub artifact attestations: GitHub refuses them for private repositories owned by a personal account. Request them with `actions/attest-build-provenance` if the repository becomes public. A deploy verifies an attestation with `gh attestation verify` when one exists, and otherwise relies on `SHA256SUMS`.

`build.yml` builds each binary with `-ldflags "-X agentcommander/internal/buildinfo.Version=TAG"`. `go run ./packaging/headless` checks that each binary is a static Linux executable for its architecture and stamped with the tag, then writes reproducible archives.

**"Latest" and prereleases.** `gh release download` without a tag fetches GitHub's latest release, which never includes a prerelease. The workflow publishes every pilot as a prerelease. After checking a pilot, mark it as the latest release so the one-liner without a tag finds it (see [RELEASING.md](RELEASING.md)). To install a pilot that is not marked latest, name its tag:

```sh
gh release download v0.1.0-pilot.5 -R ryanhelms/agent-commander -p install.sh -O - | sh -s -- v0.1.0-pilot.5
```

Without a version argument, `install.sh` installs the newest `v*` release that is not a draft, prereleases included. It reads the list through `gh api`, which older `gh` releases such as 2.23 in Debian 12 support.

## Commands

All of these live in `agentctl`, under one `host` command group. Each one runs on the Mac and acts on the server over the system OpenSSH client, so it keeps the user's host aliases, jump hosts and keys.

```sh
agentctl host releases                      # list GitHub releases with headless assets
agentctl host deploy ops@server             # install or upgrade to the newest release
agentctl host deploy ops@server --version v0.2.0-pilot.3
agentctl host deploy ops@server --archive FILE --sums SHA256SUMS   # a local build
agentctl host status ops@server             # version, service state, API version, linger
agentctl host rollback ops@server           # switch back to the previous installed version
agentctl host remove ops@server             # stop and remove the unit; keep versions and state
```

SSH options pass through as `--ssh-port N`, `-i KEY`, `-F CONFIG` and `-o NAME=VALUE`. `--repo` and `AGENT_COMMANDER_REPO` choose another repository. `--mirror` and `AGENT_COMMANDER_RELEASE_MIRROR` read releases from a directory or URL laid out as `releases.json` plus `TAG/ASSET`, for offline installs and tests.

These commands run on the server itself. `install.sh` and `deploy` call them:

```sh
agentctl host install [--source FILE --version V] [--sudo-linger]   # install and start the unit
agentctl host doctor                        # check tmux, git, Node, Claude Code, the ACP adapter and the Claude sign-in
agentctl host version                       # this binary's version and API version
agentctl host status | rollback | remove
```

`deploy` does these steps in order:

1. Read the release list through the GitHub REST API. Use the user's `gh` login or a token stored in the Keychain. List prereleases, because every release is a prerelease today.
2. Download the archive for the server's architecture. Verify `SHA256SUMS`, and the attestation when one exists.
3. Check that the release's API version is compatible with this Mac's app. Refuse an incompatible release unless `--force` is given.
4. Stream the archive to the server over SSH standard input. Unpack it into `~/.local/share/agent-commander/versions/<version>/`.
5. Run `agentctl host doctor` on the server. Report what is missing. Do not install system packages without `--install-prerequisites`, which installs git, tmux and curl with apt or dnf. Node, Claude Code and the adapter have their own installers, and `doctor` names them.
6. Have the installed `agentctl` (or the new one on a first install) run `host install --source NEW --version V`. It switches the `current` link, restarts the unit and waits for the service to report the new version.
7. If it is not healthy, it switches back to the previous version, and `deploy` reports the failure.

Each step reports a result, the same way the tray's **Add server** check reports DNS, TCP, TLS, relay and sign-in. The app can then show the steps as they run.

## On the server

- **Unit.** A systemd user unit, `agent-commander.service`, runs `agentctl serve` as the SSH user. Claude's login, tmux sessions and project checkouts all belong to that user. `KillMode=process` makes a restart stop only `agentctl`, so tmux sessions and workers survive an upgrade. The unit records the installing shell's `PATH`, with `~/.local/bin` first, because noninteractive SSH sessions often leave it out. Linger (`loginctl enable-linger`) keeps the service running after the user logs out. It usually needs `sudo` once; `--sudo-linger` allows passwordless `sudo` for it.
- **Versions.** `~/.local/share/agent-commander/versions/<version>/agentctl`, with `current` and `previous` links and `~/.local/bin/agentctl` pointing at the current one. The three newest versions, plus `current` and `previous`, stay on disk.
- **State.** The normal Commander state directory, `~/.config/Agent Commander`, so `agentctl` on the server reaches the service with no settings. Deploying, upgrading and rolling back never touch run state. Rollback keeps the old version's files, because running workers may still use them. This follows the ACP binary activation rule in [PATTERN-DECISIONS.md](PATTERN-DECISIONS.md).
- **Prerequisites.** tmux, Node 24, Claude Code and the pinned `claude-agent-acp` adapter. Codex is optional. The adapter installs through the existing ACP package adapter with hashed, pinned packages. The Claude sign-in stays manual: `doctor` says when it is missing, and the user runs `claude` once on the server.

## Connecting the Mac to a headless Commander

The MVP serves one user over local connections and SSH tunnels. Use the same here:

1. **SSH-forwarded Unix socket (first increment).** The app forwards the server's `AGENT_COMMANDER_SOCKET` to a local socket over SSH and talks to it as it talks to the local service. This needs no new authentication. While SSH is down, the server keeps running workers and holds pending questions.
2. **Through a relay (later).** The headless service runs `agentctl relay` and connects out to a Commander relay. The app reaches it with the existing OAuth scopes. This needs no inbound port, and other people can share access.

The app shows a headless host as its own entry, next to the local service, with its version and connection state. This is new interface work. It goes to the frontend agent, and DESIGN.md gets updated in the same change.

## Port the relay deploy to Go

`remote.py deploy|status|remove|connect` is now `commander-relay deploy MODE DESTINATION`, `deploy status`, `deploy remove` and `deploy connect`, in `multiplayer/internal/relaydeploy`. The shared packages are in the `hostkit` module: `sshx` for SSH transport, `release` for GitHub releases and checksums, and `systemd` for the unit writer. `agentctl host` and `commander-relay deploy` both use them. `systemd-install.sh` is now `commander-relay host provision`, which runs on the server as root. The connection check uses Go's TLS client and the device package's pin function instead of OpenSSL. `testhosts/rehearse.py` is now `go run ./deploy/remote/testhosts`, with the same three modes. `remote.py`, `rehearse.py` and `systemd-install.sh` are removed.

The other Python build scripts (`packaging/*.py`, `multiplayer/deploy/prepare.py`, the rehearsal lab) are build tooling, not product features, and stay out of scope.

## Increments

1. **Headless service on Linux.** `agentctl serve` under a systemd user unit, plus `host install` and `host doctor`. Test it in the Linux Docker host from [ssh-worker.md](verification/ssh-worker.md).
2. **Release assets.** Headless archives, `install.sh` and checksums in `build.yml`. Publish one prerelease.
3. **Mac-driven deploy.** `agentctl host releases|deploy|status|rollback|remove`, with the compatibility check and automatic rollback.
4. **Connect.** The app reaches a headless host through an SSH-forwarded socket and shows it as a host. This includes the frontend design work.
5. **Relay deploy in Go.** `commander-relay deploy` on the shared `hostkit` packages. Remove `remote.py`.
6. **Server one-liner.** `install.sh` through `gh release download` (option B). It needs no further change when the repository becomes public.

## Decisions

- **Made:** release access supports B (`gh` on the server) and C (push from the Mac). A follows when the repository becomes public.
- **Made:** headless hosts are part of milestone M4 in the [MVP plan](../MVP-PLAN.md).

## Not in scope

- macOS servers (a launchd version of the same unit).
- More than one user on one headless service.
- Automatic upgrades with no user action. `deploy` always runs because a person or a coordinator asked for it.

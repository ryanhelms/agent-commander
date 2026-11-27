# Changelog

This file records user-facing changes in each Agent Commander release. Entries use [Semantic Versioning](https://semver.org/) and the [Keep a Changelog](https://keepachangelog.com/) format.

## [Unreleased]

### Added

- See the relays near you at the top of the network tray and in Add server: each relay found on your tailnet or local network, how it admits people, and a checklist that walks you through joining it. A new relay marks the menu bar icon and posts one notification, which you can turn off on the Network tab.

### Fixed

- Coordinators can now see who is online, read request threads and work the shared task board. Commander registered these network tools but denied them to every managed coordinator.

### Removed

- Releases no longer request build attestations for the headless archives. GitHub refuses them for this private repository; `SHA256SUMS` still protects the downloads.

## [0.1.0-pilot.5] - 2026-11-26


### Fixed

- `install.sh` without a version now finds the newest release with older `gh` releases, such as 2.23 in Debian 12, and ignores the build-input releases.

## [0.1.0-pilot.4] - 2026-11-26


### Added

- Discover provider sessions in the current workspace, reattach verified inactive workers, and attach a file reference or snapshot to a follow-up.
- Provide a scoped live ACP source subscription with cursor expiration and recovery.
- Offer opt-in ACP v2, local peer reuse, negotiated system prompts, scoped MCP-over-ACP and ACP session activities for compatibility testing.
- Start and stop the relay on this Mac from the network tray's Hosting page, see its address and fingerprint, and add it as a server in one step. A Mac that has never hosted asks only for your email before the first start.
- Add a host menu to the main window's toolbar to start or stop hosting, copy the relay address, and connect to a server.
- Run the Commander service headless on a Linux server. `agentctl host install` installs it as a systemd user unit, keeps earlier versions and switches back when a new version does not report healthy. `agentctl host doctor` lists what the server still needs.
- Publish the headless service for Linux amd64 and arm64 with each release, with `install.sh` for a one-line install on the server: `gh release download TAG -R ryanhelms/agent-commander -p install.sh -O - | sh -s -- TAG`.
- Deploy, upgrade, check, roll back and remove the headless service from a Mac with `agentctl host releases|deploy|status|rollback|remove DESTINATION`. A deploy verifies the checksum and any build attestation, refuses an incompatible API version and rolls back a version that does not become healthy.
- `agentctl host connect DESTINATION` forwards a headless host's service socket to this Mac over SSH and reconnects after a drop. `agentctl host list` shows the hosts this Mac deployed to.
- A Hosts place in Agents › Workspace lists This Mac and each headless host. Choosing a host points the whole app at its service through `agentctl host connect`; Use This Mac returns to the local service.
- Add Restart Agent Commander to the app menu, and `make reload` and `make dev` to rebuild and reopen the app, and optionally restart the local service and relay, after a source change.

### Changed

- `commander-relay deploy` replaces `remote.py` for deploying a relay over SSH, with the same Docker, systemd and tailnet modes. `commander-relay host provision` replaces `systemd-install.sh`, and `go run ./deploy/remote/testhosts` replaces `rehearse.py`. The deploying Mac no longer needs Python or OpenSSL.
- `/v1/health` also reports the service's version and API version.
- Publish first structured ACP text promptly, wake workers when owner controls change, and build a single replay index for stopped conversations.
- Negotiate a windowed persistent SSH connection with compatible endpoints and preserve the legacy connection for older endpoints.

### Fixed

- Retire unanswered ACP permissions on interrupt and preserve the original session for explicit follow-ups after protocol stop outcomes.
- Verify the advertised Opus configuration before prompting managed Claude workers.

## [0.1.0-pilot.3] - 2026-11-24


### Added

- Show local Claude activity, availability, and recovery status in the cockpit.
- Resize the floating picture-in-picture panel and restore its last size.

### Changed

- Default to Pretty consoles and show ACP activity and pending approvals inline.
- Document the private multiplayer pilot deployment on Fabric GKE.

## [0.1.0-pilot.2] - 2026-11-24


### Added

- Added workspace-scoped Linear issue tools for authorized MCP actors through the connector registry.

### Fixed

- Google pilot sign-in uses operator-provisioned Desktop OAuth credentials for the PKCE exchange on the Mac.
- Relay sign-out clears a device's presence lease with its credentials, while pending work waits for its next sign-in.

## [0.1.0-pilot.1] - 2026-11-24


### Added

- Added a native macOS cockpit with independent console and formatted conversation views, harness accents, and a single-instance option.
- Added the multiplayer tray for Google sign-in, exact-handle discovery, friendship, presence, directional sharing grants, and revocation.
- Added the Go relay pilot with two edges, mutual TLS, and durable encrypted one-to-many delivery.
- Added coordinator messages, shared worker results, and scoped GitHub operations for pilot repositories.
- Added a private pilot build and release workflow with a universal macOS app, Linux relay downloads, checksums, and versioned release notes.

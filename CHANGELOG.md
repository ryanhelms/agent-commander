# Changelog

This file records user-facing changes in each Agent Commander release. Entries use [Semantic Versioning](https://semver.org/) and the [Keep a Changelog](https://keepachangelog.com/) format.

## [Unreleased]

### Added

- Discover provider sessions in the current workspace, reattach verified inactive workers, and attach a file reference or snapshot to a follow-up.
- Provide a scoped live ACP source subscription with cursor expiration and recovery.
- Offer opt-in ACP v2, local peer reuse, negotiated system prompts, scoped MCP-over-ACP and ACP session activities for compatibility testing.
- Run the Commander service headless on a Linux server. `agentctl host install` installs it as a systemd user unit, keeps earlier versions and switches back when a new version does not report healthy. `agentctl host doctor` lists what the server still needs.
- Publish the headless service for Linux amd64 and arm64 with each release, with `install.sh` for a one-line install on the server: `gh release download TAG -R ryanhelms/agent-commander -p install.sh -O - | sh -s -- TAG`.
- Deploy, upgrade, check, roll back and remove the headless service from a Mac with `agentctl host releases|deploy|status|rollback|remove DESTINATION`. A deploy verifies the checksum and any build attestation, refuses an incompatible API version and rolls back a version that does not become healthy.
- `agentctl host connect DESTINATION` forwards a headless host's service socket to this Mac over SSH and reconnects after a drop. `agentctl host list` shows the hosts this Mac deployed to.
- A Hosts place in Agents › Workspace lists This Mac and each headless host. Choosing a host points the whole app at its service through `agentctl host connect`; Use This Mac returns to the local service.

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

# Changelog

This file records user-facing changes in each Agent Commander release. Entries use [Semantic Versioning](https://semver.org/) and the [Keep a Changelog](https://keepachangelog.com/) format.

## [Unreleased]

### Added

- Discover provider sessions in the current workspace, reattach verified inactive workers, and attach a file reference or snapshot to a follow-up.
- Provide a scoped live ACP source subscription with cursor expiration and recovery.
- Offer opt-in ACP v2, local peer reuse, negotiated system prompts, scoped MCP-over-ACP and ACP session activities for compatibility testing.
- Add Restart Agent Commander to the app menu, and `make reload` and `make dev` to rebuild and reopen the app after a source change.

### Changed

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

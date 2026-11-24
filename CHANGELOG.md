# Changelog

This file records user-facing changes in each Agent Commander release. Entries use [Semantic Versioning](https://semver.org/) and the [Keep a Changelog](https://keepachangelog.com/) format.

## [Unreleased]

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

# Increment 1 contract: Connect

This is the working contract between the device agent (`commander-network`), the host-mode relay (`commander-relay host`) and the tray. Scope comes from [the spec](COMMANDER-NETWORK-SERVERS.md), increment 1.

## Device agent: server list

The daemon keeps a list of servers in `<state>/servers.json` (state defaults to `~/.agent-commander/network`, mode 0700; file 0600). It runs one relay connection per server whose `autoConnect` is true.

```json
{"servers": [{
  "id": "s-3f2a9c1d",
  "url": "https://ryan-mac.tail.internal",
  "name": "ryan-mac",
  "favorite": true,
  "autoConnect": true,
  "pin": "sha256/BASE64-SPKI-HASH or empty when the system trusts the certificate",
  "addedAt": "2026-11-25T18:00:00Z",
  "lastUsedAt": "2026-11-25T18:05:00Z"
}]}
```

- Each server's private files live in `<state>/servers/<id>/` (policies, submissions). Keychain items stay keyed by the relay URL hash, as today.
- `google-desktop-client.json` stays in `<state>/` and serves every server whose relay names that client ID.
- When `servers.json` doesn't exist and `COMMANDER_NETWORK_RELAY` is set, the daemon adds that relay as the first server. The old built-in default relay is no longer added.

## Trust

- A relay certificate the system trusts is accepted, and `pin` stays empty.
- Otherwise the connection succeeds only when the SHA-256 of the leaf certificate's SubjectPublicKeyInfo matches `pin`.
- When a pinned server presents a different key, its state becomes `certChanged` and it stops connecting until the person accepts the new pin with `server-trust`.

## Tray verbs

The tray still calls `commander-network tray VERB` with a JSON object on stdin. Existing verbs (`status`, `login`, `logout`, `profile`, `search`, `request`, `accept`, `grant`, `revoke`, `resource-add`, `repo-credential`, …) take an extra `"server": "<id>"` field and act on that server. They return the same shapes as today.

New verbs:

| Verb | Input | Output |
|---|---|---|
| `servers` | `{}` | `{"servers": [ServerSummary]}`, ordered favorites first, then by `lastUsedAt`, newest first |
| `server-probe` | `{"url": "host, host:port or https://host:port"}` | `Probe` |
| `server-add` | `{"url": "...", "name": "optional", "pin": "from the probe, or empty"}` | `ServerSummary` |
| `server-update` | `{"server": "id", "name"?: "...", "favorite"?: bool, "autoConnect"?: bool}` | `ServerSummary` |
| `server-remove` | `{"server": "id"}` | `{}`; also signs out and deletes that server's Keychain item and files |
| `server-trust` | `{"server": "id", "pin": "..."}` | `ServerSummary` |

`ServerSummary`:

```json
{"id": "s-3f2a9c1d", "url": "https://ryan-mac.tail.internal", "name": "ryan-mac",
 "favorite": true, "autoConnect": true, "pin": "sha256/...", "lastUsedAt": "...",
 "state": "signedOut | connecting | online | offline | certChanged | error",
 "signedIn": true, "handle": "ryan", "lastSeen": "...", "error": "",
 "friendsOnline": 2, "incoming": 1}
```

`Probe` lists each step in order. A failed step ends the probe.

```json
{"url": "https://ryan-mac.tail.internal",
 "steps": [
   {"step": "dns", "ok": true, "detail": "100.64.0.1"},
   {"step": "tcp", "ok": true, "detail": "100.64.0.1:443 in 4 ms"},
   {"step": "tls", "ok": true, "detail": "not trusted by the system; confirm fingerprint", "pin": "sha256/...", "fingerprint": "AB:CD:...", "systemTrusted": false},
   {"step": "relay", "ok": true, "detail": "commander-relay host"},
   {"step": "signin", "ok": true, "detail": "https://accounts.google.com", "clientId": "…apps.googleusercontent.com", "clientConfigured": true}
 ]}
```

The relay answers `GET /v1/info` without a client certificate: `{"version": "...", "mode": "host|edge", "issuer": "...", "clientId": "...", "name": "..."}`.

## Host mode relay

`commander-relay host` runs a complete relay as one process on this Mac:

- **Storage:** bundled PostgreSQL binaries (`COMMANDER_PG_BIN`, defaulting to the app bundle's `Contents/Resources/postgres/bin`). It initializes a cluster in `<host>/postgres` on first run and connects over a Unix socket in `<host>/run`. It never listens on TCP.
- **Broker:** NATS JetStream embedded in the process, with no network listener.
- **TLS:** on first run it creates a private CA and a certificate for the host names and IP addresses it serves, such as the MagicDNS name and the tailnet IP. Clients pin it on first use.
- **Config:** `<host>/host.json` holds the name, listen address (default `:443`), host names, issuer, client ID, allowed emails and admins. The first admin is the person who creates it.
- **Paths:** `<host>` defaults to `~/Library/Application Support/Agent Commander/relay`.
- **launchd:** `commander-relay host install` writes and loads `~/Library/LaunchAgents/local.agentcommander.relay.plist`; `commander-relay host uninstall` removes it.
- **Tray:** `commander-relay host --json status|install|uninstall` prints one line for the app: `{"ok": true, "host": {"state": "unconfigured|stopped|starting|running", "installed": bool, "name", "url", "pin", "dir", "log"}}`, or `{"ok": false, "error": "..."}` with a non-zero exit. `starting` means the launch agent is installed and the relay doesn't hold its lock yet. The tray's Hosting page and the main window's host menu run it to start, stop and read the relay.

## Tray (frontend)

The tray follows the Fable design artifact for increment 1: add a server with the staged health check and pin confirmation, a server list with favorites and recents and per-server state, friends grouped by server, the certificate-changed state, and sign-in per server.

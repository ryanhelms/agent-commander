# Commander network: relay discovery

Status: proposal, 2026-11-27. Tracked in [#75](https://github.com/ryanhelms/agent-commander/issues/75). Builds on [Servers](COMMANDER-NETWORK-SERVERS.md) and [relays over a tailnet](COMMANDER-NETWORK-TAILNET.md).

## Goal

A person opens the network tray and sees every running relay they could join: on their tailnet, on the LAN, on another VPN, or in a public directory on bytedesk.ai. Each relay says what joining needs. The tray does every step it can by itself and asks the person only for what it cannot: a confirmation, a browser sign-in, or an admin's approval.

Today a relay is added by typing its URL or opening an invite link, and the tailnet section lists peers tagged `tag:relay`. Every Mac also needs a Google Desktop OAuth file copied by hand before it can sign in.

## How a relay is secured

Four independent layers protect a relay. Discovery changes how a person finds a relay. It does not remove any layer.

| Layer | What protects it | Where it lives |
| --- | --- | --- |
| Reachability | The network: a tailnet (WireGuard with node keys and the tailnet's ACLs), a LAN, another VPN or the public internet. | Network operator |
| Relay identity | The relay runs its own CA and terminates TLS itself. The device pins the leaf's SPKI on first use. A changed certificate blocks the connection and asks the person. | `commander-relay`, device server list |
| Device identity | Each Mac holds a device key in its Keychain and presents a client certificate. Every route except `GET /v1/info` and `GET /ready` refuses a connection without one. A lost Mac is revoked on its own. | `relayServer` in `cmd/commander-relay`, `internal/device` |
| Person and membership | Browser sign-in to the relay's OpenID Connect issuer (Google today) with PKCE binds the person to the device key. The relay then applies its membership mode: `open`, `allowlist` or `invite`. Admins manage members, invites and policy. | `internal/identity`, `internal/control/membership.go` |

Payloads between people are end-to-end encrypted and checked against current grants at the recipient. See [Multiplayer relay architecture](MULTIPLAYER-RELAY.md#identity-contents-and-authority).

`GET /v1/info` is public to anyone who can reach the relay. It returns the relay's name, mode, membership mode, admin contact, policy summary, OIDC issuer and client ID. Discovery uses it to label each relay.

## What a person needs to join a relay

1. **A route to it.** Be on the same tailnet, LAN or VPN, or use a relay with a public address.
2. **Trust in its certificate.** Confirm the fingerprint once. For a relay found on your tailnet, the tray confirms it for you (see [Trust](#trust)).
3. **An account with its sign-in provider.** Today, a Google account, and for the current Google client, a place on its test-user list.
4. **Admission.** An `open` relay admits anyone the provider accepts. An `allowlist` relay admits listed emails. An `invite` relay needs an invite code or an admin's approval.

After this proposal, the Mac no longer needs the Google Desktop OAuth file, and step 4 has a Request access button.

## Decisions

| Topic | Decision |
| --- | --- |
| Sources | Tailnet peers tagged `tag:relay`, Bonjour `_agentcommander._tcp` on every interface, the bytedesk.ai public directory, and invite links. |
| Scanning | None. A relay is found only when it advertises itself. No port or subnet sweeps. |
| List | Every relay found, with a badge: **Open**, **Allowlist**, **Invite only**, **Added**, **Unreachable**. |
| Trust | Pin without a prompt when found on the tailnet and the node checks out. Confirm the fingerprint everywhere else. |
| Sign-in configuration | The relay hands out its public OAuth client configuration. No file on any Mac. |
| Directory listing | Opt-in by the relay admin. The relay registers itself and sends heartbeats. |
| Tailnet join | One click: the tray opens the Headscale or Tailscale sign-in page in the browser. |
| Background | Discovery runs while the app runs. A new relay badges the tray icon and posts a macOS notification. |
| No access | **Request access** sends a membership request. Relay admins approve or deny it from their tray. |
| Hosting | A host-mode relay advertises on the tailnet and over Bonjour by default. Public listing is opt-in. |
| Join guide | A checklist per relay that completes itself and names the one step left for the person. |

## Discovery sources

The device agent gathers candidates from every source, merges them by certificate pin (and by URL when a pin is not known yet), and probes each with `GET /v1/info`.

| Source | How it finds relays | What it supplies |
| --- | --- | --- |
| Tailnet | `tailscale status --json`, peers tagged `tag:relay` (exists as `tailnet-relays`). | MagicDNS name, tailnet addresses, online state |
| Bonjour | `NWBrowser` (or `dns-sd` in the Go helper) for `_agentcommander._tcp` on all interfaces. | Host, port, TXT record: `v=1`, `name`, `pin` (SPKI SHA-256), `mode` |
| Directory | `GET https://directory.bytedesk.ai/v1/relays` over system-trusted TLS. | Name, URL, pin, membership mode, issuer, last heartbeat |
| Invites | `agentcommander://join?server=…&pin=…&code=…` (exists). | URL, pin, invite code |

Bonjour reaches the LAN and VPNs that carry multicast, such as ZeroTier. Plain WireGuard and most other layer-3 tunnels do not carry multicast. A relay on such a network is found through the directory, a tailnet or an invite.

One tray verb returns the merged list:

| Verb | Input | Returns |
| --- | --- | --- |
| `relay-discover` | optional `refresh` | One row per relay: name, URL, sources, pin and how it was verified, membership mode, issuer, reachability, whether it is in the server list, and the first incomplete checklist step. |

The agent refreshes every 60 seconds while the app runs, and immediately when the network changes or Bonjour reports a change. It sends `relay-discovered` to the tray for a relay it has not seen before.

## Trust

A relay found on the tailnet:

1. The device dials the relay's tailnet address and reads its certificate.
2. It runs `tailscale whois <address>` and checks that the node is in this tailnet and carries `tag:relay`.
3. WireGuard has already authenticated the node key. If both checks pass, the device pins the SPKI without a prompt and records `verified: tailnet` with the node name.

Everywhere else, the tray shows the fingerprint as today. When a Bonjour TXT record or a directory entry carries a pin, the tray shows whether it matches. A match does not remove the confirmation.

A changed certificate still blocks the connection, whatever the source.

## Sign-in without a file

The relay's Google client is an installed-app client. Google documents that such a secret cannot be kept confidential. PKCE protects the authorization code. The relay can therefore publish it.

- `GET /v1/info` gains `oauth`: `{ "issuer", "clientId", "clientSecret" (installed-app only), "scopes" }`.
- The device uses it when no local file matches the relay's client ID. A local file, if present, still wins, so existing setups keep working.
- `commander-relay host setup` and `deploy` take `--client-secret-file` once on the relay side.

The Google client is still in Testing, so only listed test users can sign in. Publishing it, or moving a relay to another OIDC provider, is an operator task outside this proposal.

## Membership requests

Today a person who is not admitted is refused after sign-in, and `POST /v1/access-requests` covers only grants between friends who are already members.

New:

- After sign-in, a person who is not admitted gets a limited session that can call only `POST /v1/membership-requests` and `GET /v1/membership-requests/mine`.
- The request carries the person's verified email, display name and an optional note.
- Admins see pending requests in the tray's Hosting or Members section and on their activity feed. **Approve** adds the email to the allowlist. **Deny** records the decision.
- The requester's tray shows **Requested** and posts a notification when the request is decided. On approval it signs in again without asking.
- Rate limits: one pending request per person per relay, and a cap on pending requests per relay.

## Public directory

A small Go service at `directory.bytedesk.ai`, built from the `multiplayer` module.

- **Opt in.** The relay admin turns on **List publicly** and sets the public URL. Nothing is listed by default.
- **Register.** The relay signs a registration with its TLS key: name, URL, pin, membership mode, issuer and a timestamp. The directory dials the URL, checks that the certificate matches the pin and that `/v1/info` agrees, and lists the relay.
- **Heartbeat.** The relay re-registers every 5 minutes. An entry without a heartbeat for 15 minutes is hidden and removed after 7 days.
- **Remove.** Turning off **List publicly** sends a signed removal.
- **Read.** `GET /v1/relays` is public and cacheable. It lists only what `/v1/info` already shows publicly.

The directory never sees accounts, members, payloads or device keys.

## Hosting a relay

A host-mode relay on a Mac:

- advertises `_agentcommander._tcp` over Bonjour on the interfaces it binds (tailnet only, LAN or all), with the TXT record above;
- asks the operator to tag its tailnet node `tag:relay` when it is on a tailnet, and reports in **Hosting** when the tag is missing;
- offers **List publicly** (off by default) and **Advertise on this network** (on by default) as toggles in the **Hosting** section.

## The tray

Frontend work under AGENTS.md: Fable with the `frontend-design` skill, [DESIGN.md](../DESIGN.md) components and tokens, and a Codex verification pass on the running app.

- **Relays nearby.** A section at the top of the panel, and in **Add server**, listing discovered relays with their badge and source (Tailnet, Local network, Directory, Invite). Added relays drop out of it.
- **Join checklist.** Selecting a relay shows four steps that complete themselves in order:
  1. **Reachable**: probe `/v1/info`. If it fails because the Mac is not on the tailnet, offer **Join tailnet**.
  2. **Certificate trusted**: pinned automatically for the tailnet, or **Confirm fingerprint**.
  3. **Signed in with \<provider\>**: **Sign in** opens the browser.
  4. **Membership \<mode\>**: done when admitted, or **Request access** / **Enter invite code**.
- **Background.** The tray icon shows a dot when there is a relay the person has not seen. A macOS notification names the relay and its source. Notifications can be turned off in the panel.

## Increments

1. **Find.** `relay-discover` merging the tailnet and Bonjour sources with `/v1/info` badges. Bonjour advertising in host mode. Automatic pinning for verified tailnet relays. Tests with a fake `tailscale` CLI and a local Bonjour service.
2. **Sign in without a file.** `oauth` in `/v1/info`, relay-side `--client-secret-file`, device fallback.
3. **Join.** The Relays nearby section, join checklist, background refresh and notifications (frontend).
4. **Ask to join.** Limited sessions for people not yet admitted, membership requests and the admin approval flow in the tray.
5. **Directory.** The bytedesk.ai directory service, relay registration and heartbeats, **List publicly**, and the directory as a discovery source.

Each increment ends with a working slice verified on this Mac and a second Mac over Headscale.

## Security notes

- `/v1/info` stays public and must not grow member, account or capacity data. Discovery is limited to what it already shows plus the public OAuth client.
- Discovery never trusts a pin on its own outside the tailnet check. A LAN or directory pin is a hint shown next to the fingerprint.
- Bonjour and directory entries are untrusted input: length-limit and sanitize names before showing them.
- Membership requests are rate limited and reveal nothing about who is already a member.
- The production Headscale at `https://adag.bytedesk.ai` is only used, never changed. Tagging nodes and setting ACLs stay with its operator.

## Out of scope

- Port or subnet scanning on any network.
- Automatically joining relays without the person's action.
- Changing the production Headscale, or publishing the Google OAuth client.
- Embedding Tailscale (`tsnet`) in the app or relay.

## Open questions

- Should the directory also list relays that are invite-only, or only open and allowlist relays?
- Who operates `directory.bytedesk.ai`, and which DNS and certificate does it use?
- Should Request access also work for allowlist relays, or only for invite-only relays?

# Increment 2 contract: Social

Scope comes from [the spec](COMMANDER-NETWORK-SERVERS.md), increment 2: per-server profiles, automatic presence, linked contacts, invite links, notifications and the activity feed, and relay admin membership settings. It builds on [increment 1](COMMANDER-NETWORK-INCREMENT-1.md).

## Relay API (Go, `multiplayer/internal/control` and `internal/identity`)

All routes need device authentication unless marked.

### Profile and presence

`PUT /v1/profile` accepts any subset of these fields:

```json
{"handle": "ryan", "displayName": "Ryan", "statusMessage": "Shipping the relay",
 "presence": "online | away | busy | dnd", "avatar": "data:image/png;base64,..."}
```

- `avatar` is a PNG or JPEG data URL of at most 64 KiB. An empty string removes it.
- `GET /v1/profile` and `GET /v1/users/{handle}` return `User` with the new fields.
- `GET /v1/users/{handle}/avatar` returns the image bytes with its content type, or 404.

`User` gains these fields:

| Field | Meaning |
|---|---|
| `displayName`, `statusMessage` | Profile text |
| `presence` | The user's chosen presence while a device lease is live; `offline` otherwise |
| `lastSeen` | When their last lease ended (RFC 3339), for offline users |
| `hasAvatar` | Whether an avatar exists |
| `contactKey` | SHA-256 hex of the lowercased verified email. Returned only for accepted friends and to the user themself. Commander uses it to link the same person across servers. |

### Activity events

`GET /v1/events?after=<seq>&limit=<n>` returns up to `n` (default 50, maximum 200) events for the caller, oldest first:

```json
{"events": [{"seq": 41, "at": "2026-11-26T01:02:03Z", "kind": "friend.request | friend.accepted | friend.removed | grant.received | grant.revoked | member.joined",
             "actor": "sam", "resource": "optional id", "detail": "optional short text"}]}
```

The relay writes events in the same transaction as the change that causes them. It keeps them for 30 days.

### Membership and invites

The relay stores membership settings in PostgreSQL. On first start they are seeded from the edge or host configuration: `allowed_emails` and `admins`, with `mode` set to `allowlist` when the list is non-empty and `open` otherwise.

- `GET /v1/admin/membership` (admins only) returns `{"mode": "open | allowlist | invite", "allowedEmails": [...], "admins": [...], "memberCount": 3}`.
- `PUT /v1/admin/membership` (admins only) replaces `mode`, `allowedEmails` and `admins`. It refuses to remove the last admin.
- `POST /v1/invites` returns `{"code": "...", "expiresAt": "...", "maxUses": 5, "uses": 0}` for input `{"maxUses": 5, "ttlHours": 168}`. Any member can create an invite when the mode is `open`. Only admins can when the mode is `allowlist` or `invite`.
- `GET /v1/me` returns `{"admin": bool, "mode": "..."}` so the tray knows whether to show admin settings.
- **Enrollment:** the device's enrollment challenge request may carry `"invite": "<code>"`. An unused, unexpired code admits a verified email that the mode would otherwise refuse, and adds the email to `allowedEmails`. Each use is counted.
- `GET /v1/info` (anonymous) also returns `"membership": "open | allowlist | invite"`.

An admin is matched by the verified email at sign-in. The identity layer already keeps an email hash per device. Admin checks compare hashes of the lowercased address.

## Device agent (`multiplayer/internal/device`)

New or changed tray verbs, each taking `"server"` unless noted:

| Verb | Input | Output |
|---|---|---|
| `profile` | `{handle?, displayName?, statusMessage?, avatar?}` | `{}` |
| `presence` | `{"presence": "auto | online | away | busy | dnd"}` | `{"presence": "...", "auto": bool}`. `auto` is the default. |
| `contacts` (no server) | `{}` | `{"contacts": [{"contactKey", "displayName", "rows": [{"server", "handle", "presence", "online", "statusMessage", "hasAvatar"}]}]}`. Friends with the same `contactKey` on several servers share one contact. Friends without one stay single. |
| `activity` (no server) | `{"after"?: "cursor"}` | `{"events": [{"server", "seq", "at", "kind", "actor", "resource", "detail"}], "cursor": "...", "unseen": 3}`, newest first across servers |
| `activity-seen` (no server) | `{"cursor": "..."}` | `{}` |
| `avatar` | `{"handle": "sam"}` | `{"contentType", "data": "base64"}` |
| `membership` | `{}` | the relay's membership object, or an error if not an admin |
| `membership-set` | `{"mode", "allowedEmails", "admins"}` | the new membership |
| `invite-create` | `{"maxUses"?, "ttlHours"?}` | `{"link": "agentcommander://join?...", "code", "expiresAt"}` |
| `join` (no server) | `{"link": "agentcommander://join?..."}` | `ServerSummary`. It adds the server with the link's pin, then starts sign-in carrying the invite code. If the link has `from`, it sends that person a friend request after sign-in. |
| `me` | `{}` | `{"admin", "mode"}` |

**Invite link:** `agentcommander://join?server=<url-encoded https origin>&pin=<url-encoded pin or empty>&code=<invite code>&from=<handle>`.

**Automatic presence:** when presence is `auto`, the device agent sets `busy` while any Commander worker is running (from the local Commander service), `away` after 10 minutes of no keyboard or mouse input (`HIDIdleTime` from `ioreg`), and `online` otherwise. It pushes changes to every signed-in server. A manual choice stays until the person picks `auto` again.

**Feed:** the device agent polls `/v1/events` on each online server every 15 seconds, or right after its inbox wakes. It keeps the last 500 events per server in its state folder.

`ServerSummary` gains `presence` and `unseen`.

## Tray (Swift, Fable)

Following the design artifact's increment 2 elements:

- A profile editor per server: display name, handle, status message and avatar.
- A presence picker (auto, online, away, busy, do not disturb) and presence lamps on friends.
- Contacts grouped by server, with linked-contact badges naming the other servers.
- An invite sheet that creates a link and copies it, and a handler for `agentcommander://join` links that opens the add-server flow already filled in.
- macOS notifications for new events, except while presence is `dnd`, plus the activity feed with filters by server and by friend.
- Membership settings for admins: mode, allowed emails, admins and member count.

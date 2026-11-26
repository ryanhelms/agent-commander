# Tray API for Teams requests 1–7

This is the device agent's contract for requests 1–7 in [TRAY-REQUESTS.md](TRAY-REQUESTS.md). The Swift window codes against it.

Every verb is `POST /tray/{verb}` on the device agent with a JSON object body. Add `"server": "<server id>"` to pick a saved relay, as for every other per-server verb. Answers use the usual envelope:

```json
{"ok": true, "data": { }}
{"ok": false, "error": "sentence"}
```

A refusal can carry extra fields beside `error`. Request 7 is the only one that does.

## Summary

| # | Verb | Input | Relay route | Who |
|---|---|---|---|---|
| 1 | `admin-members` | none | `GET /v1/admin/members` | Relay admin only |
| 2 | `workspace-combined` | `workspace` | `GET /v1/workspaces/{id}/combined` | Workspace member |
| 3 | `workspaces`, `knowledge` (existing) | none | `GET /v1/workspaces`, `GET /v1/knowledge` | Member |
| 4 | `status` (existing) | none | `GET /v1/resources` plus local enrollment | Signed-in member |
| 5 | `me` (existing) | none | `GET /v1/me` | Member |
| 6 | `workspace-edit`, `workspace-leave` | `workspace` and fields | `PUT /v1/workspaces/{id}`, `DELETE /v1/workspaces/{id}/membership` | Owner edits, member leaves |
| 7 | `claim` (existing) | unchanged | `POST /v1/workspaces/{id}/claims` | Workspace member |

`admin-members` and `workspace-combined` are read-only verbs. They do not mark a server as used.

## 1. Members and devices of a relay: `admin-members`

Input: `{}` (or `{"server": "…"}`).

```json
{
  "members": [
    {"handle": "alice", "suspended": false, "admin": true},
    {"handle": "bob", "suspended": true, "admin": false}
  ],
  "devices": [
    {"id": "3f2c…", "name": "", "owner": "alice", "online": true, "lastSeen": null},
    {"id": "9a71…", "name": "", "owner": "bob", "online": false, "lastSeen": "2026-11-25T18:04:11Z"}
  ]
}
```

- `members` lists every member of the relay, ordered by handle. A member who has not chosen a handle yet has `"handle": ""`. Moderation needs a handle, so such a row cannot be suspended yet.
- `admin` is true when the member's verified email is on the relay's admin list.
- `devices` lists every enrolled device that is not revoked, ordered by owner then ID. A suspended member's devices stay listed; they cannot sign in until unsuspended.
- `owner` is the owner's handle, or `""` before they choose one.
- `online` is true while the device holds a live session lease.
- `lastSeen` is the end of the device's most recent session, in RFC 3339. It is `null` while the device is online, and `null` for a device that never opened a session.
- **`name` is always `""`.** The relay stores no device name: enrollment sends only keys. The page should show the device ID (or a short form of it) instead.

The row actions use the existing moderation routes through the `relay` verb:

| Action | `relay` input |
|---|---|
| Suspend… | `{"method": "POST", "path": "/v1/admin/members/{handle}/suspend"}` |
| Unsuspend | `{"method": "POST", "path": "/v1/admin/members/{handle}/unsuspend"}` |
| Revoke… | `{"method": "DELETE", "path": "/v1/admin/devices/{id}"}` |

A caller who is not an admin gets:

```json
{"ok": false, "error": "only a relay admin can list members and devices"}
```

## 2. A workspace's combined view: `workspace-combined`

Input: `{"workspace": "<workspace id>"}`. `id` is accepted in place of `workspace`.

```json
{
  "workspace": "7c1e…",
  "members": [
    {
      "handle": "alice",
      "online": true,
      "workers": [
        {
          "id": "build-worker",
          "name": "Build worker",
          "resource": "build-worker",
          "agent": "w-42",
          "harness": "claude",
          "model": "opus",
          "state": "working",
          "branch": "",
          "checks": null,
          "claims": [
            {"id": "c9…", "kind": "paths", "key": "src", "expiresAt": "2026-11-26T06:10:00Z"}
          ]
        }
      ]
    },
    {
      "handle": "bob",
      "online": false,
      "workers": [
        {
          "id": "bob/w-7",
          "name": "w-7",
          "resource": "",
          "agent": "w-7",
          "harness": "",
          "model": "",
          "state": "working",
          "branch": "",
          "checks": null,
          "claims": [{"id": "d2…", "kind": "issue", "key": "12", "expiresAt": "2026-11-26T06:12:00Z"}]
        }
      ]
    }
  ]
}
```

`members` lists every member of the workspace's group who has not left the workspace, ordered by handle. `online` is true while any of the member's devices holds a live lease.

Each member's `workers` come from two real sources:

1. **Published agents.** An `agent` resource the member owns, when the caller may see it: it is the caller's own, it is shared with the workspace's group, or the caller can see it as a friend or grantee. `id` and `resource` are the resource ID, `name` is its published name, and `harness` and `model` come from its published capabilities.
2. **Claim holders.** A live claim in this workspace whose agent does not match a published agent above. `id` is the claim's holder (`handle/agent`), `name` and `agent` are the agent part, `resource` is `""`, and `harness` and `model` are `""`.

The relay cannot link another member's published agent to that member's claims, because it doesn't know which Commander worker a resource runs. The device agent links the caller's own: every own agent row gets `agent`, the Commander worker it is enrolled for, and a claim held under that worker joins the row instead of appearing on its own. Other members' agent rows have `"agent": ""`. For other members, the same worker can therefore appear twice: once as a published agent and once as a claim holder.

`state` is one of:

| Value | Meaning |
|---|---|
| `working` | The worker holds at least one live claim in this workspace. |
| `online` | A published agent whose device holds a live lease. |
| `offline` | A published agent whose device has no live lease. |

Fields that have no data source yet:

- **`branch` is always `""`.** No relay record ties a worker to a branch. Queue entries carry a branch, but only on the Mac that runs the queue, and they name no worker.
- **`checks` is always `null`.** Nothing reports check results for a worker to the relay. When it is non-null it will be `{"passed": 0, "failed": 0, "running": 0}`. Do not show zero counts for `null`.

A caller outside the workspace's group, or one who left it, gets `{"ok": false, "error": "no workspace <id> in your groups"}`.

## 3. Owner handles: `workspaces` and `knowledge`

Workspace rows from `workspaces` and the result of `workspace-create` already carry `ownerHandle` beside `owner`. Knowledge items now do too.

```json
{"workspaces": [{"id": "…", "owner": "<user id>", "ownerHandle": "alice", "group": "…", "name": "…", "goal": "…", "repository": "…", "base": "main", "integration": "queue", "claims": []}]}
```

```json
{"items": [{"id": "…", "owner": "<user id>", "ownerHandle": "alice", "kind": "prompt", "name": "…", "content": "…", "visibility": "server", "version": 2, "createdAt": "…"}]}
```

The same field is on `GET /v1/knowledge/{id}/versions` (through `relay`) and on the result of `knowledge-share`. `ownerHandle` is `""` only for an owner who has no handle.

## 4. Commands on a host you lend: `status`

Each row of `status.resources` with `"kind": "host"` now always carries `capabilities.commands`:

```json
{
  "id": "mac-studio",
  "kind": "host",
  "name": "Mac Studio",
  "actions": ["host.run"],
  "owner": "alice",
  "device": "…",
  "endorsements": [],
  "capabilities": {
    "tools": ["test", "lint"],
    "commands": [
      {"name": "test", "allowArgs": false, "environment": "macos"},
      {"name": "lint", "allowArgs": true}
    ]
  }
}
```

The device agent reads the commands from the host's enrolled command file on this Mac, which is what it runs. It falls back to what the relay last published when the file can't be read. `commands` is `[]` when neither has any. This is the same `{name, allowArgs, environment}` shape as `status.directory` entries for friends' hosts. `environment` is omitted when empty.

## 5. The policy's knowledge limits: `me`

```json
{"admin": false, "mode": "invite", "knowledgeDefault": "private", "knowledgeWidest": "group"}
```

Both are one of `private`, `friend`, `group`, `server`. A share wider than `knowledgeWidest` is refused. A new item without a visibility gets `knowledgeDefault`.

The same values are public in `GET /v1/info` under `policy`. That is useful before sign-in:

```json
{"method": "GET", "path": "/v1/info"}
```

passed to `relay` returns `{"policy": {"knowledgeDefault": "private", "knowledgeWidest": "group", …}, …}`.

## 6. Edit and leave a workspace

### `workspace-edit`

Input: `workspace` (or `id`) and any of `name`, `goal`, `repository`, `base`, `integration`. An omitted or empty field stays as it is. `integration` is `queue` or `pull_request`. The group cannot change.

```json
{"workspace": "7c1e…", "goal": "Ship the relay", "integration": "pull_request"}
```

The answer is the updated workspace row, in the same shape as a `workspaces` row, with its live `claims`.

Refusals:

| Case | `error` |
|---|---|
| Caller is a member but not the owner | `only the owner can edit workspace <id>` |
| Caller is not a member, or left | `no workspace <id> in your groups` |
| Nothing to change | `nothing to change` |
| Invalid integration | `integration must be queue or pull_request` |

### `workspace-leave`

Input: `{"workspace": "7c1e…"}`. The answer is `{}`.

Leaving ends the caller's live claims in that workspace and removes the workspace from their `workspaces`, `workspace-combined` and board reads. The caller stays in the group and keeps its other workspaces. Leaving twice is refused with `no workspace <id> in your groups`.

The owner cannot leave: `the owner cannot leave workspace <id>`.

To come back, the group owner removes the member from the group and adds them again. Removing a member from the group clears their departures.

## 7. The holder in a refused claim: `claim`

When another member's live claim overlaps, `claim` fails with the holder as fields:

```json
{
  "ok": false,
  "error": "relay HTTP 409: overlapping claim held by bob/w-7",
  "holder": "bob",
  "agent": "w-7",
  "claim": "d2…"
}
```

- `holder` is the holder's handle.
- `agent` is the holding agent, the part after `/` in a claim row's `holder`.
- `claim` is the blocking claim's `id`, as listed in that workspace's `claims`. Use it to mark the row.

The same fields appear when the claim is made through `relay` (`POST /v1/workspaces/{id}/claims`), and when a card claim or card edit through `relay` (`PUT /v1/workspaces/{id}/cards/{card}`) is refused because someone else holds the card. Other refusals carry no extra fields.

The relay's own 409 body is `{"error": "…", "holder": "bob/w-7", "holderHandle": "bob", "claim": "d2…"}`. Its `holder` keeps the `handle/agent` form that existing clients read.

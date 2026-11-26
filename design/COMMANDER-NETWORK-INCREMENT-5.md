# Increment 5 contract: Teams

Scope from [the spec](COMMANDER-NETWORK-SERVERS.md), increment 5: groups, shared workspaces with claims and either integration mode, the task board, lending hardware, knowledge sharing, reputation, and the rest of relay administration. Main path first; each section names the smallest working version.

## 1. Groups

- **Relay:** `POST /v1/groups` creates a group with `{"name"}`; the creator is its owner. `GET /v1/groups` lists groups I belong to, with members. `PUT /v1/groups/{id}/members/{handle}` adds a member and `DELETE` removes one. Only the owner can do either, and only friends can be added. `DELETE /v1/groups/{id}` deletes the group. Members get `group.added` and `group.removed` events.
- **Grants to a group:** `PUT /v1/grants/{resource}/group:{id}` grants every current member, and the relay expands it to one grant per member. A member added later receives the group's grants. A member removed loses them. The owner's device mirrors the expanded grants into its local policy when it next reads `/v1/grants`.
- **Tray verbs:** `groups`, `group-create`, `group-add`, `group-remove`, `group-delete`, and `grant` with `"group": "<id>"` in place of `handle`.

## 2. Shared workspaces

A workspace is a goal, a repository, a base branch and a member group, on one server.

- **Relay:** `POST /v1/workspaces` with `{"name", "goal", "repository", "base", "group", "integration": "queue | pull_request"}`. `GET /v1/workspaces` lists those I can see, with claims. The relay stores only metadata. Code never crosses the relay.
- **Claims:** `POST /v1/workspaces/{id}/claims` with `{"kind": "issue | paths | card", "key", "holder": "<handle>/<agent>"}`. An overlapping live claim returns 409 with the holder. `DELETE` releases a claim. A claim expires 10 minutes after its holder's device lease ends.
- **Integration:**
  - *queue:* contributors push branches through the owner's existing `git.push` grant. The owner's device runs a merge queue: tray verb `queue` lists the queue, and `queue-merge` runs the workspace's test command and merges in order.
  - *pull_request:* contributors open pull requests themselves. Commander links them in the workspace view.
- **Tray verbs:** `workspaces`, `workspace-create`, `claim` and `release`.

## 3. Task board

- **Relay:** each workspace has cards: `POST /v1/workspaces/{id}/cards` with `{"title", "body"}`, then `GET` and `PUT` to update `state` (`open | claimed | done`), `assignee` and `result`. Claiming a card is a claim of kind `card`.
- **Agents:** `agentctl mcp` adds `commander_network_board`, which lists cards and claims, completes or comments on them within workspaces the agent's owner belongs to.

## 4. Lend hardware

New action `host.run` on a new resource kind `host`. The owner enrolls one or more named commands, each a fixed argument array with a working directory, for example "run iOS UI tests". The owner can set an environment label such as "ios-simulator".

- The payload is `{"command": "<enrolled name>", "args": [...]}`. Arguments append to the fixed array only when the enrolled command allows extra arguments.
- It returns the exit code and the last 64 KiB of output.
- Each run uses the normal grant and approval rules.
- Nothing runs except enrolled commands.

## 5. Knowledge sharing

- **Relay:** items stored by the relay: `POST /v1/knowledge` with `{"kind": "prompt | skill | instructions | mcp | summary", "name", "content", "visibility": "private | friend:<handle> | group:<id> | server"}`. `GET /v1/knowledge` lists items visible to me. `PUT` creates a new version, and `GET /v1/knowledge/{id}/versions` lists versions. The relay admin's `knowledgeDefault` and `knowledgeWidest` settings limit `visibility`.
- **Secrets never travel:** the device refuses to share `mcp` items whose content contains values that look like secrets (token patterns, `password=` and the like). Placeholders `${NAME}` are filled on install from the recipient's Keychain.
- **Tray verbs:** `knowledge`, `knowledge-share` and `knowledge-install`. Install writes a skill to `~/.claude/skills/<name>/SKILL.md`, an instructions snippet to the clipboard, or an MCP item to a file the person chooses.

## 6. Reputation and directory

- **Relay:** for each request outcome the requester reports, `POST /v1/outcomes` with `{"resource", "request", "accepted": bool}`. `GET /v1/reputation/{resource}` returns completed, accepted and rejected counts and the median time. Visibility follows the admin's `reputationVisibility` setting: `owner | users | friends | server`.
- **Endorsements:** `POST /v1/endorsements` with `{"resource", "skill"}`. Endorsements are listed with the resource.
- **Directory:** `GET /v1/directory?q=` searches handles, and the names and capabilities of resources whose owners opted in with `listed: true`. Nothing is listed by default.

## 7. Relay administration (rest)

`PUT /v1/admin/policy` (admins only) sets `knowledgeDefault`, `knowledgeWidest`, `reputationVisibility`, `directory` (on or off), `maxGrantDays`, `maxBudgetTokens` and `retentionDays`. `POST /v1/admin/members/{handle}/suspend` and `unsuspend`, and `DELETE /v1/admin/devices/{device}`, revoke access. `GET /v1/info` includes the admin contact and the policy summary.

## Ownership

| Part | Owner |
|---|---|
| All relay routes above | Codex |
| Device verbs, `host.run`, the merge queue, knowledge install, the secret check | Claude |
| `commander_network_board` MCP tool | Codex |
| Tray and cockpit: groups, workspaces with the combined view, board, hosts, knowledge library, reputation and directory, admin policy | Fable |

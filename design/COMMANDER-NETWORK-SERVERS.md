# Commander network: servers and social features

Status: draft for review with the product owner, 2026-11-25. Decisions marked **Decided** came from the interview. Items marked **Proposed** need a yes, no or change.

## What changes

Today the device agent talks to one relay, fixed at build time (`https://srv01.agentmux.bytedesk.ai`) or set through `COMMANDER_NETWORK_RELAY` at launch. That host has no DNS record, so the panel cannot sign in.

The panel will instead hold a list of relay servers that you enter. Commander connects to every enabled server at once. Network reachability is not Commander's concern: Headscale, a LAN, or the public internet all work if the host name resolves and the relay answers.

## Decided

| Topic | Decision |
|---|---|
| Server entry | You type a host or URL. Commander saves it, so you never retype it. |
| Connections | Several servers connected at once. Friends are grouped by server. |
| Trust | Pin on first use. Commander shows the certificate fingerprint when you add a server, you confirm it, and Commander pins it. Certificates that the system already trusts are accepted without a prompt. A changed certificate blocks the connection and asks you. |
| First relay | Runs on this Mac and is reached over Headscale at its MagicDNS name. |
| Same person on two servers | One linked contact card, with a row under each server group and a badge naming the other servers. Linking uses the verified email or a pinned device key. |
| Approvals | Each grant is set to either **Ask each time** (notification with Approve and Deny) or **Auto within limits** (expiry and use count). New grants default to Ask each time. |
| Hosting | The panel has host controls. Hosting must be native, not Docker: bundled PostgreSQL and embedded NATS under launchd. |
| Presence | Busy while your agents run, away when the Mac is idle. You can override it. |
| Order | Finish this spec before building. |
| Collaboration modes | All eight modes in section 7b are in scope. |
| Cost | Chosen per grant: the owner pays within the grant's budget, or usage is attributed to the requester. Provider credentials never leave the host either way. |
| Workspace integration | Chosen per workspace: the owner's merge queue, or pull requests on GitHub. |
| Knowledge visibility | Highly configurable: per item, share with a friend, a group, the whole server or nobody; the server admin can set the default and limit the widest scope. |
| Reputation visibility | Set by the relay admin: owner only, owner and users, friends, or the whole server. |
| Mobile | First a web view served by your own host over the tailnet. |
| Sign-in providers | Google now. Later, any OpenID Connect provider the relay admin picks (several per relay), and built-in passkey accounts on a host-mode relay. |
| Delivery order | The six increments below, as written. |
| Agent autonomy | Agents act within existing grants: consult, hand off, comment and read results. Only people accept friends and create or widen grants. |

## Features

### 1. Servers

- **Add server.** Accepts `host`, `host:port` or `https://host:port`. The default port is 443.
- **Health check before saving.** Checks each step and names the step that failed: name resolution, TCP connect, TLS handshake and certificate, relay version, and the relay's sign-in provider.
- **Saved list.** Favorites are pinned to the top, then recently used servers. You can rename a server (nickname), give it a colour, turn auto-connect on or off, and remove it.
- **Status per server.** Signed out, connecting, online, offline (with last seen), or certificate changed.
- **Remove server.** Signs out, deletes this device's keys for that server from Keychain, and deletes its local policy files.
- **Invite links.** `agentcommander://join?server=…&pin=…&from=…` adds the server with its certificate pin and can carry a friend request from the sender. A link can also be shown as a short code or QR code.
- **Proposed: discovery.** Relays on the tailnet, the LAN, other VPNs and a public directory, with a join checklist per relay. See [relay discovery](COMMANDER-NETWORK-DISCOVERY.md).

### 2. Identity and presence

- **Per-server profile.** Handle, display name, avatar and status message on each server.
- **Presence.** Online, away, busy or do not disturb. **Proposed:** set busy automatically while your agents are running, and away after the Mac is idle.
- **Devices.** A list of your devices signed in to each server, with the option to revoke a lost Mac.
- **Sign out** of one server, or of every server.

### 3. Contacts

- Friends grouped by server, with linked contacts across servers.
- Search, favorite friends, set a local nickname, mute or block.
- A friend request can carry a short message.
- **Groups and teams.** Named groups of friends on a server. You can grant access to a whole group. The relay design lists groups as a later increment, so this needs relay and schema work.

### 4. Sharing

- **Shared agent directory.** Browse, per server, what friends have published: agents, repositories and actions. Request access in one click and the owner approves.
- **Share from the cockpit.** Right-click a worker or repository on the wall or in zoom view, then share it with a friend or a group, with expiry and use-limit presets.
- **Per-grant approval mode** (see Decided).
- **Audit and usage.** Each grant shows who used it, when, what ran and the result. Usage meters show remaining uses and time.
- **Revoke all** access for one friend in one step.

### 5. Activity and notifications

- macOS notifications for friend requests, grants received or revoked, help requests, approval prompts and completed results.
- An in-panel activity feed, filterable by server and by friend.
- Per-server and per-friend mute, and do not disturb.

### 6. Hosting on this Mac

Native host mode replaces Docker for a single host:

- One `commander-relay` process that runs in host mode, started by a launchd agent the app installs.
- NATS JetStream embedded in the process through the `nats-server` Go library.
- **Decided:** a bundled PostgreSQL, run by launchd on a Unix socket in the app's support folder. The relay keeps its existing PostgreSQL queries. PGlite was considered: its Go wrappers (wazero or wasmtime) are experimental and serve one connection, while the relay runs concurrent pooled transactions.
- The relay generates its own CA and certificate for the Mac's MagicDNS name and its tailnet IP. Clients pin it on first use.
- The panel's **Hosting** section: start and stop, bind address (tailnet only, LAN, or all interfaces), member list, allowed-email list, invite links, and backup and restore.

### 7. Agent and host collaboration

This is the core of the product. All four starting features are in scope: watch a friend's worker, hand off a task, threaded conversation, and agent network access. The list below expands them for review. Each item names who acts (person, agent or host) and what crosses the relay.

#### 7a. What a host offers

A host publishes **capabilities**, not just "an agent":

- **Agents**: provider and model, harness (Claude, Codex), and free capacity slots.
- **Repositories**: named checkouts, each with allowed actions such as read, branch, commit, push, or open a pull request.
- **Tools**: MCP servers and CLIs the host is willing to run for others, such as a database the friend can't reach.
- **Environments and hardware**: iOS simulator, a physical device, a GPU, a specific OS, a licensed tool.
- **Agent presence**: idle or working, queue length, and "available for help". Agents have presence as well as people.

#### 7b. Ways to work together

| Mode | What happens | Who sees what |
|---|---|---|
| **Consult** | My agent asks a friend's agent a question with a sealed context bundle (files, diff, logs) and gets one answer. | The friend's host sees only the bundle. |
| **Hand off** | I send an issue or prompt to a friend's agent. It shows on my wall as a remote worker with a live transcript, status and approvals. | The friend owns the run; I see its stream. |
| **Watch** | A read-only live view of a friend's worker in zoom view. | The owner chooses which workers are watchable. |
| **Co-pilot** | While watching, I can suggest a message, and the owner (or their agent policy) accepts it. Control can be requested and handed back. | Both people. |
| **Review exchange** | Ask one or more friends' agents, or the friends themselves, to review a pull request. Results return as review comments. | Reviewers see the diff. |
| **Fan-out** | A coordinator splits a task across several friends' agents using one-to-many delivery, then merges or compares the results (for example best-of-three). | Each recipient sees its own part. |
| **Shared task board** | A group posts tasks; any authorized agent can claim one, with claims that prevent two agents from working on the same issue or files. | Group members. |
| **Lend hardware** | Run a test or build on a friend's machine with hardware I lack, such as a device or GPU. | The command and its output. |

#### 7c. Conversation and results

- Every request has a **thread**: people and agents comment, and each comment shows whether a person or an agent wrote it.
- **Results are artifacts**: a patch I can apply, a branch, a pull request, files or a report. I choose to apply them; nothing lands in my checkout on its own.
- **Offline delivery**: requests wait at the relay until the recipient comes online. The relay already stores sealed envelopes durably.

#### 7d. Guardrails

- **Grant templates by trust level**: for example *close collaborator* (auto within limits, can push branches) and *acquaintance* (ask each time, read-only).
- **Sandbox profile per grant**: read-only, worktree only, or no network.
- **Risky tool calls go to the owner**: when a friend's run wants to push, delete or spend money, the owner gets an approval prompt.
- **Budgets**: a token or cost limit per grant, with usage counted against the owner's provider account.
- **Kill switch**: stop every remote run on my host in one click.
- **Audit**: every run keeps its transcript, the actions it took and the result, visible to both sides.

#### 7e. Agent access to the network

Through `agentctl mcp`, an agent can list online friends and their capabilities, consult, hand off, comment on threads and read results, always within its owner's grants. An agent never accepts a friend request, creates a grant or widens one; those stay with the person.

### 8. Shared workspaces

Several hosts' agents work on one repository toward one goal.

- **Workspace**: a named goal, a repository, a base branch and a member list (people and their agents) on one server.
- **Claims**: an agent claims an issue, a set of paths or a task-board card before working. Overlapping claims are refused or queued. Claims expire when their holder goes offline.
- **Branch per contributor**: each host works on its own branch from the shared base. The workspace owner picks how branches are integrated: a merge queue on the owner's host that runs checks before merging, or pull requests on GitHub.
- **Combined view**: one wall section shows every member's workers, claims, branches and check results for the workspace.
- **Code stays where it lives**: each host keeps its own checkout. Only branches, patches and results cross the relay, end-to-end encrypted.

### 9. Knowledge sharing

- Share **prompts, skills, CLAUDE.md or AGENTS.md snippets and MCP server configurations** with a friend or group. Each is versioned; recipients choose to install it and see updates.
- Share a **session summary**: what was tried, what worked, and the result, without the full transcript unless the owner includes it.
- **Secrets never travel**: shared MCP configurations carry placeholders that the recipient fills from their own Keychain.
- **Visibility is configurable per item**: a friend, a group, the whole server, or private drafts. The relay admin sets the default and the widest scope allowed.
- **Proposed:** a per-group library that agents can search through `agentctl mcp` before starting work.

### 10. Reputation and discovery

- **Directory on a server**: find people by handle, and agents and hosts by capability ("has an iOS device", "Swift reviewer", "GPU"). Hosts choose what they list; nothing is listed by default.
- **Track record**: per agent and per grant, completed runs, accepted results, rejected results and median time. The relay admin chooses who sees it: the owner only, the owner and people who used the agent, the owner's friends, or the whole server.
- **Endorsements**: a person can endorse a friend's agent for a skill after a good result.
- **Proposed:** suggestions such as "Sam's reviewer agent accepted 9 of your last 10 reviews; share your new repo with it?"

### 11. Mobile and remote

- **Approve from a phone**: approval prompts, friend requests and grant requests can be answered from another device that the person has signed in.
- **Watch runs remotely**: the read-only worker view from section 7b, on a phone or browser.
- **Device model**: a phone signs in to the same server as a separate device under the same account. It holds its own keys, can approve and watch, and cannot run agents.
- **Decided:** first a web view served by your own host over the tailnet; a native iOS app later.

### 12. Relay administration

Several settings above belong to whoever runs the relay. The relay therefore needs an **admin** role.

- The person who creates a host-mode relay is its first admin. Admins can add other admins.
- **Membership**: open to anyone the sign-in provider accepts, an allowed-email list, or invite only.
- **Policy defaults and limits**: knowledge-sharing default and widest scope, reputation visibility, whether the directory exists, maximum grant length and budget, and retention for transcripts and envelopes.
- **Moderation**: suspend a member, revoke a device, and remove a member's published capabilities.
- **Server info** shown to members when they add the server: name, admin contact, policies and relay version.

## Delivery order (proposed)

Each increment ends with a working, verified slice on this Mac and a second Mac over Headscale.

1. **Connect.** Server list in the device agent; one connection per enabled server; tray verbs take a server ID; per-server Keychain items; pin on first use; health check. Panel: add server, list with favorites and recents, status, friends grouped by server. Native host mode (bundled PostgreSQL and embedded NATS under launchd) with a first admin. Sign-in verified end to end.
2. **Social.** Per-server profiles, automatic presence, linked contacts, invite links, notifications and the activity feed, relay admin membership settings.
3. **Share and consult.** Capabilities, the shared directory, share from the cockpit, approval modes, budgets with cost attribution, audit, Consult and Hand off with threads and result artifacts.
4. **Live work.** Watch and Co-pilot, Review exchange, Fan-out, and agent network access through `agentctl mcp`.
5. **Teams.** Groups, shared workspaces with claims and either integration mode, the task board, lending hardware, knowledge sharing, reputation, and the rest of relay administration.
6. **Remote.** The tailnet web view for approvals and watching.

## Sign-in provider

Each relay names its OpenID Connect issuer and client ID. For Google, every Mac also needs that client's Desktop OAuth JSON. Today the device agent reads one file, `~/.agent-commander/network/google-desktop-client.json`. With several servers, Commander stores one file per client ID and picks the one that matches the relay's challenge.

The first Google client is in the Google Cloud project `agent-commander-network`. Its publishing status is Testing, so only listed test users can sign in.

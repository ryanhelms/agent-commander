# Commander network: goal and progress

## Goal

Agent Commander users can join any relay they can resolve, see their friends grouped by server, and get agents on different Macs to work together safely. This Mac hosts the first relay natively and is reached over Headscale. Work ships in the six increments of the [servers and social spec](COMMANDER-NETWORK-SERVERS.md). Each increment ends with a build you can open and a recorded demo.

## How each increment ends

1. The increment's tests pass and its changes are committed on `claude/commander-network-f774d6`.
2. A build of Agent Commander is made from the worktree (`dist/Agent Commander.app` in the worktree, never the live app in the primary checkout).
3. A demo subagent starts at once. It runs the increment's demo script against that build and a host-mode relay, records the result, and fills the increment's row below. It reports defects and does not fix them.
4. The next increment starts in parallel with the demo. Defects the demo finds go into the running increment's task list.

## Progress

| Increment | Scope | Status | Commit | Build | Demo |
|---|---|---|---|---|---|
| 0. Spec | Spec, rules, Google OAuth client, tray design artifact | Done | 154a1d7 | — | [Tray design artifact](https://claude.ai/artifact/Ws7ZxqfckGrGu7RXuGg5P2) |
| 1. Connect | Server list, several connections, pinning, health check, friends by server, native host mode, sign-in | Done | 2d569d5 | `dist/Agent Commander.app` in the worktree (debug) | [12 of 12 steps passed, 7 defects](demos/increment-1/demo.md) |
| 2. Social | Profiles, presence, linked contacts, invites, notifications, feed, membership | In progress | — | — | — |
| 3. Share and consult | Capabilities, directory, share from cockpit, approvals, budgets, audit, Consult, Hand off | Planned | — | — | — |
| 4. Live work | Watch, Co-pilot, Review exchange, Fan-out, agent network access | Planned | — | — | — |
| 5. Teams | Groups, shared workspaces, task board, lend hardware, knowledge, reputation, admin | Planned | — | — | — |
| 6. Remote | Tailnet web view for approvals and watching | Planned | — | — | — |

## Demo scripts

- **Increment 1.** Start the host-mode relay on this Mac. Add `ryan-mac.tail.internal` in the tray, pass the health check and pin its certificate, sign in with Google, and show the server online. Add a second relay, show both connected, mark one as a favorite, restart the app, and show both reconnect without retyping.
- **Increments 2 to 6.** Each script is written when its increment starts, from the spec's acceptance items.

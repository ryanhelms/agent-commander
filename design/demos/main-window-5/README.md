# Main window increment 5: Teams

Sidebar B's Teams mode now has a full-size page for every place: each workspace, then Groups, Hosts, Knowledge, Directory and Admin. Each page is a clickable design preview with sample data, and each is bound to the network model in the live window. This increment also fixes the defects the running-window check of increment 4 found, and adopts the network model's calls from PRs #13 and #14.

**Not seen in a real window.** Everything here was checked by build, 751 unit tests and headless renders. No window was opened, clicked or driven. The items marked "needs a check in a window" below can only be confirmed there.

## Open a preview

```sh
open "dist/Agent Commander.app" --args --design-preview teams-board
```

| Scenario | Opens sidebar B on |
|---|---|
| `teams-workspace` | Relay launch, on its Combined view |
| `teams-board` | Relay launch, on its Board, with a card you hold open |
| `teams-groups` | Groups, with Relay crew open |
| `teams-hosts` | Hosts, with mira's build-box ready to run |
| `teams-knowledge` | Knowledge, with the relay-triage skill open |
| `teams-directory` | Directory, with a search done and a reputation open |
| `teams-admin` | Admin, on studio's policy |

They are in the preview gallery menu under "Main window redesign". Every place is also a click away inside `shell-b`. Choose the scenario again to reset the sample data.

### What to click

| Page | Try |
|---|---|
| Board | Claim "Add a per-request retry budget": it moves to Claimed in your name. Claim "Fuzz the lease parser": the sample relay answers 409, the card says who holds it and moves to Claimed in their name. Open your card, type a result, Complete. Release… asks first. New card… adds one. |
| Combined view | Open on a row goes to the wall for your worker and to Hand-offs for a friend's. |
| Integration (Relay launch) | Add branch…, then Run merge…: the confirmation lists each branch with its test command, in order. Run merge: one branch merges and one fails with its output. Remove… asks first. |
| Integration (Infra guild) | The open pull requests. A row opens it in the browser. |
| Claims | Claim…, choose Paths, type `Sources/Relay`: refused, the form says who holds the overlap and that claim's row is marked. Release… on your own claim asks first. |
| Groups | New group…, name it, Create group. Add a friend. Remove… and Delete group… each ask first. |
| Hosts | Run on build-box: the exit code and the end of the output come back. Type `--fail` as an extra argument for a failed run. Share… on your own host opens the share sheet on Shared. |
| Knowledge | Install… on a skill: the confirmation names `~/.claude/skills/relay-triage/SKILL.md`. On github-mcp it names the file and the `${GITHUB_TOKEN}` placeholder. Share…: paste something like `token = ghp_…` to see the secret refusal; choose Server to see the policy's limit refused. |
| Directory | Search, choose a result, type a skill, Endorse. |
| Admin | Change a limit, Set policy…: the confirmation lists each change as old → new. Suspend…, Unsuspend and Revoke… each ask first and name who or what. |

## Renders

Whole windows, one pixel per point, console theme unless named. Each state is drawn at 1440 × 900 (`<name>-console.png`) and at 1280 × 800 (`fit-1280-<name>-console.png`).

```sh
TEAMS_RENDER_DIR=design/demos/main-window-5 swift test --filter TeamsRender
```

| Picture | Name |
|---|---|
| Workspace, Combined view | `teams-workspace` |
| Board, with a card open | `teams-board`, and `teams-board-black-glass.png` |
| Merge queue | `teams-integration-queue` |
| Merge confirmation | `teams-integration-merge-confirm` |
| Pull requests | `teams-integration-pull-requests` |
| Claims, with a refused claim | `teams-claims-refused` |
| Groups | `teams-groups` |
| Hosts | `teams-hosts` |
| Knowledge | `teams-knowledge` |
| Install confirmation | `teams-knowledge-install-confirm` |
| Share knowledge | `teams-knowledge-secret-refused` (the form as it opens; the refusal shows once a secret is typed) |
| Directory | `teams-directory` |
| Admin | `teams-admin` |
| Suspend confirmation | `teams-admin-suspend-confirm` |

A test measures every one of these states at both sizes: none asks for more width than the window has.

## Live or demo, per page

The live pages are drawn from the fixture in tests only. The renders above are the previews.

| Page | Live | Demo only |
|---|---|---|
| Workspace header | Goal, repository, base, how it lands, group, telemetry. New workspace… (the network's own form). | Leave and edit: no call exists. |
| Board | The board (the window's own read), New card…, Claim on a card. An open card is the network's card host: claim, complete with a result, release after its confirmation, reopen. | — |
| Combined view | Each member of the workspace's group, and the agents that hold a claim, with what each holds. | Worker state, branch and checks: no read exists. Open goes to the wall or to Hand-offs, not to the worker itself. |
| Integration, queue | The queue on this Mac, Add branch… (the network's host), Run merge after the window's confirmation, Remove… after its confirmation. | — |
| Integration, pull requests | The open pull requests (the window's own read), Repository. | — |
| Claims | Every claim, Claim… (the network's host), Release… after its confirmation. | The mark on the claim that stopped a refused claim: only the window's own form sets it. |
| Groups | The table, a group's members, New group…, add a friend, Remove… and Delete group… after their confirmations. | — |
| Hosts | Your hosts and friends' hosts, Run (the network's host: command, arguments, exit code, output), Share… (the share sheet on Shared), Request (goes to Network, Directory). | Your own hosts' enrolled commands: the relay's resource list doesn't carry them, so the column is empty. |
| Knowledge | The library, an item's content and versions (the window's own read), Share… (the network's host, with its secret refusal), Install… after the window's confirmation naming the destination. | The line saying how widely the server lets knowledge be shared: only an admin can read the policy. |
| Directory | Search (the window's own read), reputation and endorsements, Endorse, Request access (goes to Network, Directory). | Reporting how a request you sent turned out: not offered on this page. |
| Admin | The network's policy host: the policy, Save policy, and suspending a member or revoking a device by handle or ID, each after a second press. | The member and device lists with Suspend… and Revoke… on each row, and the confirmation listing each policy change: no list read exists, so the live page shows the host alone. |

### How the live pages use the network model

- **One file binds them.** `TeamsPagesLive.swift` reads the model into values and sends every action to a call that names its target (`MultiplayerTeamsActions.swift`).
- **One boundary carries the answers.** `TeamsPageActions` is a struct of async closures that return `NetworkActionResult`, the same result the network pages use. The preview supplies the sample's actions through the same boundary, so both share every flow (`TeamsPagesState`).
- **The window owns its reads.** Boards, pull-request lists, version lists and reputations are read per workspace, item or resource and kept by the window. The model's actions don't refresh them, so the window reads again after each action that changes one.
- **The window asks for every second press.** The model's actions ask nothing. Deleting a group, removing a member, releasing a claim, removing a queued branch and running the merge wait for a confirmation in the window that names the target. Releasing a held card, suspending a member and revoking a device are confirmed inside the network's own hosts.
- **Forms are the network's hosts** where one exists: new workspace, claim, card, queue a branch, share knowledge, run on a host, policy. Each is shown with `scrolls: false` because the page scrolls. New card and New group are the window's own forms.
- **No Teams page moves the tray.** A test opens a workspace, reads it, sends a refused claim and builds every host while the tray is on another page; the tray's route and its own board are unchanged.

## Increment 4 defects

The report is in [`../main-window-4/verify/`](../main-window-4/verify/REPORT.md).

| # | Defect | What changed |
|---|---|---|
| 1 | ⌥⌘3 did nothing | **The cause was not found.** The key's path through the code is the same as the other four, and no other binding of the chord exists in the source. The window now also hears the mode keys itself, before it looks for a key equivalent, so a press reaches its mode whatever else wants the chord. A test checks every mode key from every mode. **Needs a check in a window.** |
| 2 | Presence had no accessibility element | The presence control is now AppKit's own pull-down button, with nothing drawn, over the readout. A test finds it in the hosted view: a menu button named "Your presence", value "Auto: Busy", a check beside the choice in force. Whether the toolbar exposes it **needs a check in a window.** |
| 3 | Answered approvals | Rows come from every request the network lists, with the network's word on each, in Approvals and in Needs you. The window filters nothing out and adds no time of its own: its outcome dwell now equals the network's 2 s hold, and Needs you no longer keeps its own copy of an answered approval. An answered row is not counted and its countdown stops. "Waiting on you", "Access requests", the telemetry and the navigation count the same rows. |
| 4 | Thread labels and counts | A row with no comments no longer ends in ", ". The strip's "comments" is the sum the rows show; "in the open thread" is the open thread's own count. |
| 5 | Confirmations below the fold | The Revoke confirmation, the grant sheet and every Teams confirmation scroll into view when they open. **Needs a check in a window.** |

After the hold, a request the relay still lists reads as waiting again, because nothing then says it was answered. If the relay keeps listing a denied approval, its row returns with its verbs and its countdown. That is the network's list, not something the window filters.

## Adopted from PR #14

| Call | Where |
|---|---|
| `model.apply(artifact:of:on:checkout:)` | Hand-offs: each artifact's result is the call's own, and names a saved file's final name. |
| `model.remove(_:)` | Servers: the window asks for the second press and removes by value. The tray stays where it is. |
| `share.resource(forWorker:)` | The wall: a worker has a dock only when the network shares it. |
| `footerTitle:`, `allowsSuggestion:` | The remote zoom: "Open hand-off" is the one way out, and it takes a suggestion where the owner shared Suggest. |
| `RemoteWorkerGroup` | The wall's remote band is the network's own group again; reviews and fan-outs sit under it in their own frame. |
| `multiplayerFixedNow` | The network's countdowns in the window count from the window's fixed time in a render. |
| `theme.space.sectionInset` | People, the identity inspector. |

## Gaps

- **Increment 4's renders in `../main-window-4/` were not redrawn.** The remote band now has two frames when there are both tiles and rows.
- **The Admin page differs between preview and live.** The preview shows the page-scale policy form and member and device lists. The live page shows the network's policy host alone, which moderates by typed handle or device ID.
- **The policy host's Cancel does nothing on the Admin page**, because the page has nothing to close.
- **The live Combined view has no worker state, branch or checks.**
- **A workspace's owner isn't shown.** The relay names the owner by user ID, which the window can't turn into a handle. The merge queue's actions are offered to everyone, as in the tray.
- **Knowledge rows name an owner only when it is a handle the window knows.**
- **Breadcrumbs for a workspace read "Workspaces › Relay launch"**, without "Teams".
- **The wall's controls are still not themed:** the run header, "Group by parent", the presentation menu and the key hints. Carried over again.
- **One test from PR #14 is unsteady in a full run.** `MultiplayerWindowCheckTests.anAnsweredRowIsHeldForTheLiveHoldThroughReadsAndNavigation` failed in two of five full runs here and passes alone. It is the network session's test.

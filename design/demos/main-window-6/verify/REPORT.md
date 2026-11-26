# Increment 6 (PR #25): running-window check

**Result:** all five increment 5 defects that needed a window are fixed: confirmations scroll into view, messages stay on their page, presence shows one chevron, two quick answers both land, and names wrap. The other fixes, Admin moderation, the owner-only actions and fit at both sizes also pass. One new Low defect: **after Set policy, Admin shows no message.** The router has no caller in the running app yet; its unit tests pass.

The check ran on 26 November 2026 against `562f052` (PR #25, merged as `e0c11e4`), using a debug build with the network fixture. Screenshots in this folder are scaled to 1440 px at most.

## Moved pages and whether their tray pages can go

| Window page | Passes | Notes |
|---|---|---|
| `network.directory` | Yes | Fit; endorse on Teams Directory |
| `network.approvals`, with access requests | Yes | Review grant sheet in view; two quick answers both land |
| `network.shared` | Yes | Revoke confirmation in view |
| `network.handoffs`, `network.threads`, `network.audit`, `network.fanout` | Yes | Fit at both sizes. Their actions were checked in [increment 4](../../main-window-4/verify/REPORT.md), not again here. |
| Each workspace: Board, Combined view, Integration, Claims | Yes | Claim and complete, merge confirmation in view, owner-only actions |
| `teams.groups`, `teams.hosts`, `teams.knowledge`, `teams.directory` | Yes | Handles, "you shared" counts, endorse |
| `teams.admin` | **Not yet** | Saves, but shows no message (defect A). The tray keeps Policy and moderation until the fix is checked. |

## Environment

| Item | Value |
|---|---|
| Checkout | `~/.worktrees/agent-commander/issue-21-4f9a12811470` at `562f052` |
| Build and system | `swift build` (debug), macOS 27.0.1 (26A434) |
| Instance | PID 30330, launched with `-AllowOnlyOneInstance NO` |
| Window sizes | 1280 × 800 for checks 1–8 and the first fit pass. 1440 × 900 for the second fit pass. |
| Fixture | Scratch `AGENT_COMMANDER_HOME` and `COMMANDER_NETWORK_FIXTURE_STATE`, plus a temporary `commander-network` link to the fixture. The link was removed afterwards. |
| Local service | None, so the window shows "Service offline" |
| How the window was driven | Accessibility actions on the PID only. No mouse clicks and no keystrokes. Overflow was measured by walking the accessibility tree. |

## Checks

| Check | Result | Screenshot |
|---|---|---|
| Revoke confirmation scrolls into view (Shared, 1280) | Pass. The buttons sit inside the window's bottom edge. Cancelled. | 01, 02 |
| Review grant sheet scrolls into view (Approvals, 1280) | Pass. The sheet's top sits under the page top. It is taller than the page, so the rest scrolls. | 03, 04 |
| Run merge confirmation scrolls into view (Integration, 1280) | Pass. It lists each branch with its test command. Cancelled; nothing merged. | 06, 07 |
| "Queued" stays on Integration | Pass. It isn't on any other Teams, Network, People or Agents page. | 08, 09 |
| "Endorsed" stays on Directory | Pass. It isn't on Admin. | 10, 11 |
| Presence shows one chevron | Pass. It is still the `AXMenuButton` "Your presence", value "Auto: Busy". The menu works, and Auto was restored. | 15–17 |
| Approve and Deny 27 ms apart | Pass. Both land, the count goes from 3 to 1, and the fixture has both. | 18 |
| Knowledge owners show handles | Pass | 19, 20 |
| Sidebar names and the merge-queue intro wrap at 1280 | Pass | 06, 20 |
| Breadcrumbs start with "Teams" or "Agents" | Pass | 05, 20, 27, 45 |
| A Done card has no claim note | Pass | 22, 23 |
| Board count matches its heading | Pass | 05, 23 |
| "You shared" counts your item | Pass. It went from 2 to 3. | 21 |
| Admin moderation lists members and devices | Pass. Five members and six devices. | 11 |
| Suspend asks first | Pass. Kept. | 12 |
| Set policy | **Partial.** The confirmation names the change and the fixture is written, but the page shows no message. Restored. | 13, 14 |
| Owner sees Edit… and the queue actions, not Leave | Pass | 06 |
| A member sees Leave…, not Edit… | Pass | 24 |
| A member doesn't see the queue actions | Pass. The owner was changed in scratch state, then restored. | 26 |
| Edit opens in view, and cancels | Pass | 25 |
| Fit: 22 views at 1280 × 800 and 1440 × 900 | Pass. Nothing passes either edge. | 30–51, 60–81 |
| Router reached from the running app | Not testable in a window. Nothing calls it until the tray row exists. The `agentcommander://` handler serves `join` links only. | — |
| `swift test --filter CommanderWindowRouter` | Pass, 6 of 6 | — |

## Defects

| # | Severity | Defect | Expected |
|---|---|---|---|
| A | Low | After Set policy, Admin shows no message. The live `setPolicy` action returns a result with no message. | One "Policy set on ryan-mac." band, on Admin only |
| B | Low | A knowledge row's second line is cut short at 1280: "Skill, by fixture-sam on…" | The line wraps or fits |
| C | To confirm | On Relay reconnect, the Integration tab counts 2 while the heading says "Merge queue, 4". This may be queued versus all entries. | Confirm the two counts are meant to differ |

## Windows driven

- **PID 30330:** its main window, at 1280 × 800 and then 1440 × 900, and its presence menu, twice. All through accessibility actions.
- **Screen captures:** three region captures of presence, taken after bringing the PID forward and checking that it owned the topmost window. The rest are window captures.
- **Mouse and keyboard:** none.
- **Not touched:** the user's live app. Its helper services were running and were left alone.

## Settings changed and restored

- **Defaults:** the run added the key `NSWindow Frame cockpit` to the `AgentCommander` defaults. It was deleted.
- **Fixture link:** removed, along with the folders created for it.
- **Fixture changes:** in scratch state only. Presence, the policy and the workspace owner were restored.
- **System settings:** none changed.
- **Instance:** quit by PID. No source was edited.

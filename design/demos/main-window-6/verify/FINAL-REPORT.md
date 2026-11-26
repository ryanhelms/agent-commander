# Increment 6, final check at `1da7d0b` (PRs #29 and #30): running-window report

**Result:** every tray link row works. Each one opens its window page, whether the main window is open or closed. The panel closes, and the right place and item are selected. Review, Control and Admin pass, and fit passes on all 22 views at 1280 × 800.

There are two findings:
- **New defect (Medium):** after a link row closes the panel, the first click on the menu bar item does nothing. A second click opens it. This happened on every row press, and also after a real mouse click.
- **Watch's zoom wasn't tested.** The wall draws remote tiles only inside an open run, and the fixture has no local service.

The check ran on 26 November 2026 against `develop` at `1da7d0b`, using a debug build with the network fixture. The screenshots in [`final/`](final/) are scaled to 1100 px at most. Each tray row has two files: `NNa-tray-…` shows the panel before the press, and `NNb-window-…` shows the window after it. An earlier, partial pass at `061509b` is summarised at the end; its screenshots aren't committed.

## Pass list

| Item | Result |
|---|---|
| `teams.admin` | **Pass.** Its tray page can go. |
| Review | **Pass** |
| Control | **Pass.** It opens the plain wall, because it names a local worker. |
| Watch | **Not verified.** The unknown-worker fallback passes. The zoom to a remote tile needs a local run. |
| Every tray link row in the table below | **Pass**, but see defect 1 |

## Environment

| Item | Value |
|---|---|
| Checkout | `~/.worktrees/agent-commander/verify-inc6-develop`, detached at `1da7d0b` |
| Build and system | `swift build` (debug), macOS 27.0.1 (26A434) |
| Instance | PID 36181, launched with `-AllowOnlyOneInstance NO` |
| Window size | 1280 × 800 |
| Fixture | A scratch `AGENT_COMMANDER_HOME` and `COMMANDER_NETWORK_FIXTURE_STATE`, plus a temporary `commander-network` link to the fixture. The link was removed afterwards. |
| Local service | None, so the window shows "Service offline" |
| Live app | Its window was not running. Its helper services were running and were left alone. |

## Tray link rows

"Open" means the main window was open. "Closed" means it was closed before the press. Every press closed the panel, and every press made with the window closed reopened it.

| Tray row | Window page | Panel closed? | Right place? | Right item? | Screenshots |
|---|---|---|---|---|---|
| Server › Open Directory | Network › Directory | Yes | Yes | — | 01, 02 |
| Server › Open Approvals | Network › Approvals | Yes | Yes | — | 03, 04 |
| Server › Open Hand-offs | Network › Hand-offs | Yes | Yes | — | 05, 06 |
| Server › Open Audit | Network › Audit | Yes | Yes | — (all resources) | 07, 08 |
| Server › Open Groups | Teams › Team tools › Groups | Yes | Yes | — | 09, 10 |
| Server › Open Workspaces | Teams › Workspaces › Relay reconnect | Yes | Yes, see note 1 | — | 11, 12 |
| Server › Open Hosts | Teams › Team tools › Hosts | Yes | Yes | — | 13, 14 |
| Server › Open Knowledge | Teams › Team tools › Knowledge | Yes | Yes | — | 15, 16 |
| Server › Open Directory (Teams) | Teams › Team tools › Directory | Yes | Yes | — | 17, 18 |
| Agents › Open Directory | Network › Directory | Yes | Yes | — | 19, 20 |
| Agents › Open Fan-out | Network › Fan-out | Yes | Yes | — | 21, 22 |
| Agents › Open Workspaces | Teams › Workspaces › Relay reconnect | Yes | Yes, see note 1 | — | 23, 24 |
| Agents › Open Hosts | Teams › Team tools › Hosts | Yes | Yes | — | 25, 26 |
| Agents › Open Knowledge | Teams › Team tools › Knowledge | Yes | Yes | — | 27, 28 |
| Agents › Open the audit for relay-worker | Network › Audit | Yes | Yes | Yes, filtered | 29, 30 |
| People › Open Groups | Teams › Team tools › Groups | Yes | Yes | — | 31, 32 |
| Needs you › three approvals, with the window open and closed | Network › Approvals | Yes | Yes | Yes, each approval | 33–35 |
| Live work › two hand-offs, with the window open and closed | Network › Hand-offs | Yes | Yes | Yes, each request | 36, 37 |
| Live work › Fan-out | Network › Fan-out | Yes | Yes | Yes, its comparison | 38, 39 (see note 2) |
| Relay policy › Open in Agent Commander | Teams › Team tools › Admin | Yes | Yes | Yes, ryan-mac's policy | 48, 49 |

1. Workspaces open the first workspace, because the window has no list page for them.
2. With only one fan-out, a press made with the window closed can't prove the item was delivered. The approval and hand-off rows do prove it: each such press selected a different item.

**The window coming forward:** after an accessibility press, Claude stayed frontmost. A real mouse click on a row brought Agent Commander forward with its window on top (screenshot 40). An accessibility press simply doesn't count as user input for activation.

## Watch, Control and Review

| Row | Result | Screenshots |
|---|---|---|
| Watch a worker with a hand-off, with the window open and closed | **Not tested.** The plain wall opened. Remote tiles are drawn only inside an open run. | 41, 42 |
| Watch an unknown worker | Pass. The plain wall opened. | 43 |
| Control a local worker, with the window open and closed | Pass. The plain wall opened, as expected. | 44, 45 |
| Review, with the window open and closed | Pass. Network › Hand-offs opened with the review selected, showing its summary and findings. | 46, 47 |
| An unknown review | Not tested. The fixture can't produce one. | — |

## Admin

| Check | Result | Screenshot |
|---|---|---|
| Moderation lists members and devices | Pass: 5 members and 6 devices | 50 |
| Suspend asks first | Pass. Kept. | 51 |
| Set policy names the change | Pass: "Keep records for: 90 days → 60 days" | 52 |
| Policy saves, with "Policy set on ryan-mac." | **Pass** | 53 |
| The message stays on Admin | Pass | 54 |
| Restore | Done. The fixture matches its earlier copy. | — |

## Quick re-checks

| Check | Result | Screenshot |
|---|---|---|
| Knowledge rows wrap at 1280 | Pass | 79 |
| The merge-queue heading reads "2 queued of 4" | Pass | 71 |
| Fit at 1280 × 800, 22 views | Pass. Nothing passes either edge. | 60–81 |

## Tray pages still shown in full

- **With a link row on top:** Watch, Control, Review and Relay policy.
- **Composers with no link:** Request access, Share, Consult, Hand off, Request review and New workspace.
- Every other moved page is now a link row only.

## Defects

| # | Severity | Defect | Expected |
|---|---|---|---|
| 1 | Medium | After a link row closes the panel, the first click on the menu bar item does nothing. It happened on every opening at both SHAs, and after a real mouse click too. The likely cause is that `MultiplayerPanelWindow.close()` closes the window directly, so `MenuBarExtra` still treats the panel as open. This is the network session's file. | One click reopens the panel |
| 2 | To confirm | The Hand-offs sidebar says "2 sent", while the heading says "Sent by you, 3". The heading seems to count the review. | The counts agree, or the reason they differ is shown |
| 3 | Note | Watch's zoom to a remote tile can't be shown without a local run | Check it with the service running |

## Windows driven

- **PID 36181:** its main window, its tray panel and its status item.
- **Status item:** accessibility actions didn't open it. It was opened by mouse clicks at its centre, (1090, 16). Before each click, the element at that point was checked to be this PID's own status item, with no other app's item overlapping. Each opening took two clicks, because of defect 1.
- **Tray row:** one mouse click on a row, at (1264, 531), after the same check.
- **Everything else:** accessibility actions only, closing the main window included. No keystrokes were sent.
- **Siri orb:** a system window labelled "Siri Waveform Orb" appeared beside a focused comment field on a Thread page. It was not touched.
- **Not touched:** the user's live app.

## Settings changed and restored

- **Defaults:** the run added the key `NSWindow Frame cockpit` to the `AgentCommander` defaults. It was deleted.
- **Fixture link:** removed, along with the folders created for it.
- **Fixture changes:** in scratch state only. The Admin change was restored.
- **System settings:** none changed.
- **Instance:** quit by PID. The checkout is clean, and no source was edited.

## Earlier pass at `061509b`, before PRs #29 and #30

This pass made 37 row presses: Directory, access requests, Approvals, Hand-offs, Threads, Audit, Fan-out, Groups, Workspaces, Claims, cards and Add to queue. Each one opened the right place and item and closed the panel. Defect 1 was already present.

The pass stopped before the remaining rows, the page checks and the fit pass, which the run above covers. It also found that the tray's Fan out composer opens Network › Fan-out, but the window's own New fan-out… composer doesn't open.

# Increment 2: running-window check

**Result:** these all work in a real debug window:
- sidebar B
- the toolbar readouts
- answering items in Needs you
- the placeholder pages
- the theme choice surviving a relaunch

Two shortcuts are wrong (⌥⌘1 and ⌥⌘4), and screen readers can't use the presence readout. There are 11 defects, and none blocks the main path. They are increment 3 work.

The check ran on 26 November 2026 against `198f00b`, whose content equals `develop` at `6da44cb`. A verifier subagent did it through the accessibility API, keystrokes and window captures. Screenshots are in this folder, scaled to at most 1440 px.

## Environment

- **Build:** debug build from `swift build`, on macOS 27.0.1. The window is 1280 × 800 pt.
- **Run 1:** PID 5015, launched with `-AllowOnlyOneInstance NO -appearance.theme console`.
- **Run 2:** PID 12941, launched without the theme argument, to test persistence.
- **Scratch folders:** `AGENT_COMMANDER_HOME`, `COMMANDER_NETWORK_BIN` and `COMMANDER_NETWORK_FIXTURE_STATE` all pointed into scratch folders.
- **No local service.** The window shows "Service offline". With no runs and no local requests, the local-request steps could not run.
- **Fixture link.** `COMMANDER_NETWORK_BIN` only works when `AGENT_COMMANDER_NETWORK_PANEL=1` is set, and that variable replaces the cockpit. So the fixture was linked to `.build/debug/Contents/MacOS/commander-network` for the run, and the link was removed afterwards (defect 11).

## Steps

| Step | Result | Screenshots |
|---|---|---|
| Launch | Pass | 01 |
| Needs you order, counts and readout strip | Pass. Earliest lapse first, then access, then the friend request. | 02 |
| Rail modes | Pass. Network has 8 places with live counts, People shows "3 friends online", Teams has 2 workspaces, and the gear opens Settings. | 03–06 |
| ⌥⌘2, ⌥⌘3, ⌥⌘5 | Pass | — |
| ⌥⌘1, ⌥⌘4 | Fail (defects 1 and 2) | — |
| ⌘N while offline | ⌘N does nothing, but the New run row opens the form (defect 6) | 07a, 07b |
| ⇧⌘A from Settings | Nothing happens (defect 7) | 08 |
| ⌘1, ⌘], ⌘[ | Not tested: they need an open run | — |
| Breadcrumb, service state, `servers` readout | Pass. The readout opens Network → Servers. The breadcrumb is empty on Runs (defect 9). | — |
| Presence menu | Pass. Away was set on the fixture and then Auto restored, both confirmed in the state file. | 09–11 |
| Needs you answers | Pass. Approve, Deny, Review ("In review"; the row stays), Decline and Approve on a suggestion each show their result for about 2.4 s. | 12–17 |
| Friend Accept | Shows "Accepted", then the row returns. The fixture always returns this request, so this is not an app defect. | — |
| Placeholders and "Open network panel" | Pass | 19, 20 |
| Sidebar collapse | Pass | 21 |
| Theme | Pass. The choice persists after a relaunch, and switching to Console takes effect at once. While `-appearance.theme` is set at launch, the choice shows no change (defect 8). | 22–26 |
| Accessibility | Rail cells and rows expose the selected state, a label with the count and the shortcut. Answer buttons are labelled. Presence fails (defect 3). | — |
| Comparison with `live-*.png` and DESIGN.md | These match: hairline grids, mono data, the readout strip and the joined decision cells. The pink lamps are the fixture server's hashed colour, which is correct. | — |

These were not tested:
- **Local Reply:** there were no local requests to answer.
- **Empty state:** the fixture's friend request never leaves the list.
- **Consoles looking the same in both themes:** there were no consoles to compare.

## Defects

| # | Severity | Defect | Expected |
|---|---|---|---|
| 1 | Medium | ⌥⌘1 does nothing (5 tries). It may be shadowed by the hidden ⌘1 "Focus coordinator" button; this is not confirmed. | It selects Agents |
| 2 | Medium | ⌥⌘4 opens Agents → Runs (4 tries). Clicking the Teams cell works. | It selects Teams |
| 3 | Medium | Presence is exposed as `AXUnknown` "Your presence", with no value and no press action. Its help text reads "Servers: 2 of 3 online". | One element with its value, such as "Auto: Busy", that a press can open (DESIGN.md: readouts speak as one element) |
| 4 | Low | The presence menu shows no check beside the current choice | A check beside the current choice |
| 5 | Low–Medium | Toolbar items sit in macOS glass capsules with large corners | Flat, as in the renders. DESIGN.md allows no corner rounder than 2 pt and no glass. |
| 6 | Low | Offline, ⌘N is disabled but the New run row still opens the form | The row is disabled too, or ⌘N works |
| 7 | Low | ⇧⌘A from another page doesn't return to the wall. With no local request this may be intended. | Either fix it or correct the README |
| 8 | Low | The theme choice shows no change while `-appearance.theme` is set at launch (test setups only) | The choice applies, or the page says it is fixed by a launch argument |
| 9 | Low | The breadcrumb is empty on Runs with no run open | It reads "Agents / Runs" |
| 10 | Low | "Open network panel" from Approvals opens the panel's Servers section | It opens approvals |
| 11 | Low (tooling) | The cockpit can't be pointed at the network fixture without the panel variable replacing it | A way to run the cockpit against the fixture |

Minor:
- Teams reads "1 claims". It should read "1 claim".
- The Settings eyebrow is in mixed case. The other pages use upper case.
- Countdowns over an hour read as minutes, for example "1424:25 left".
- Countdowns have no drain line, which DESIGN.md's countdown includes.
- An answered row keeps a hidden "Waiting 21m" text that screen readers still read.

## Windows driven

- **PID 5015:** its main window, its "Commander network" window and its own menu-bar panel.
- **PID 12941:** its main window.
- **Not touched:** the user's live app. Its main app wasn't running; only its `agentctl serve` and `commander-network serve` helpers were.
- **Focus taken from another session:** bringing the debug window to the front took focus from another worktree's instances (PIDs 35391 and 70854). They were not driven.

## Settings changed and restored

- **User defaults domain:** the runs created an `AgentCommander` domain holding the theme and the window frame. It was deleted afterwards.
- **Fixture link and presence:** the fixture link was removed, and fixture presence was set back to Auto.
- **System settings:** none were changed.
- **Debug instances:** both were quit by PID.

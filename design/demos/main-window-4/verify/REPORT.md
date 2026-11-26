# Increment 4 (PR #9): running-window check

**Result:** most of increment 4 works. These pass:
- ⌥⌘1 and ⌥⌘4
- every page fitting at 1280 × 800
- full breadcrumbs
- the Consult composer hosted on the Directory page
- the Revoke and Apply confirmations; Apply wrote nothing
- Threads loading
- all the low-severity fixes

These fail:
- ⌥⌘3 no longer works.
- Presence is still not an accessible element.
- Approving a request doesn't keep its outcome on the row.

All open defects move to increment 5.

The check ran on 26 November 2026 against `bc60387` (PR #9), using a debug build with the network fixture. The screenshots in this folder are scaled to 1440 px at most.

## Environment

| Item | Value |
|---|---|
| Checkout | `~/.worktrees/agent-commander/main-window-4` at `bc60387` |
| Build and system | `swift build` (debug), macOS 27.0.1 |
| Instance | PID 68492, launched with `-AllowOnlyOneInstance NO`, console theme |
| Window | 1280 × 800. Set to 1440 × 900 only for the breadcrumb check. |
| Fixture | A scratch `AGENT_COMMANDER_HOME` and `fixture-state`, plus a temporary `commander-network` link. The link was removed afterwards. |
| Local service | None, so the window shows "Service offline" |
| How the window was driven | Accessibility actions on the PID. Keystrokes only while the PID was frontmost, plus key events posted to it. Mouse clicks only after checking that the PID owned the topmost window. |

## Fixes from increment 3

| Check | Result |
|---|---|
| ⌥⌘1 selects Agents from every mode | Pass |
| ⌥⌘4 selects Teams from every mode | Pass |
| ⌥⌘2, ⌥⌘5 | Pass |
| ⌥⌘3 selects People | **Fail (regression).** Nothing happens from any mode, with keystrokes or with events posted to the PID. Clicking the rail cell works. |
| Presence is its own element | **Fail.** The two toolbar items look separate, but the accessibility tree holds only `servers, 2 of 3 online`. A hit test on presence returns the toolbar. The menu works by mouse and shows a check beside Auto. |
| Full breadcrumbs at 1280 and 1440 pt | Pass |
| Decline confirmation, the alert band staying on its page, "1 friend request", selectable rows, labels that include times | Pass |

## Fit at 1280 × 800

On all nine pages, the rail stays 26 pt from the left edge and nothing runs past the right edge. On Servers, Directory, Approvals and Shared, the inspector sits under the table. On Approvals, the grant sheet's Cancel and Share buttons are reachable by scrolling. Pass.

## New behaviour on the fixture

| Check | Result | Screenshot |
|---|---|---|
| Directory → Consult | Pass. The composer opens on the page, and no panel window opens. | 25 |
| Shared → Revoke → Keep grant | Pass. The grants are unchanged. | 26 |
| Hand-offs → Get result → Apply → choose a checkout → Don't apply | Pass. The confirmation names the patch and the folder, and the folder stays unchanged. | 29 |
| Approvals: an answered row keeps its outcome | **Partial.** A denied row stays with "Denied". An approved row leaves at once. A kept outcome disappears after leaving the page and coming back. | 22 |
| Threads loads | Pass, with 11 requests | 30 |
| Wall control dock | Not tested: it needs a live run | — |

## Defects

| # | Severity | Defect | Expected |
|---|---|---|---|
| 1 | Medium | ⌥⌘3 does nothing, a regression from increment 3 | It selects People |
| 2 | Medium | Presence is not in the accessibility tree; the hit test returns the toolbar | A menu button "Your presence" whose value reads, for example, "Auto: Busy" |
| 3 | Low–Medium | An approved row leaves at once. A denied row stays, but loses its outcome when you leave the page. "Waiting on you 2" counts the denied row while the telemetry says 1. The denied row's countdown keeps running. | Both outcomes stay on their rows. The outcomes survive leaving the page. The counts agree, and countdowns stop once a row is answered. |
| 4 | Low | Thread row labels end in ", ". The telemetry says "comments, 0" while a row says "2 comments". | No trailing separator, and counts that agree |
| 5 | Low | At 1280 pt, the Revoke confirmation and the Review grant sheet open below the fold | The opened confirmation or sheet scrolls into view |
| 6 | Low | The certificate inspector holds an empty text element | Comes from the tray's organism; already noted |

## Windows driven

- **PID 68492:** its main window, resized and then restored, its folder picker (twice) and its presence menu.
- **Possible stray click:** the first click on presence may have landed on a Google Chrome window showing a GitHub 404 page. That was before the topmost-window check was added. Every later click passed the check.
- **Not touched:** the user's live app.

## Settings changed and restored

- **Defaults:** the window-frame key the run added to the `AgentCommander` defaults was deleted.
- **Fixture link:** removed.
- **Scratch checkout:** a scratch git repository was created for Apply. It was left in the scratchpad unchanged.
- **Fixture changes:** scratch state only.
- **System settings:** none changed.
- **Instance:** quit by PID.

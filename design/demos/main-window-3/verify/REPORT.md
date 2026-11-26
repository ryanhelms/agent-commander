# Increment 3: running-window check

**Result:** all nine pages work in a real window, and every main action tried on the fixture worked. Most increment 2 fixes hold, but three things don't:

- ⌥⌘1 and ⌥⌘4 still go to the wrong place.
- Presence still has no accessible element of its own.
- At the default 1280 pt width, five pages are wider than the window. On Approvals, the grant sheet's Cancel and Share buttons are out of reach.

These defects are increment 4 work.

The check ran on 26 November 2026 against `9ec6076` (`claude/main-window-3-network-pages`), using a debug build and the network fixture. The screenshots in this folder are scaled to 1440 px or less.

## Environment

| Item | Value |
|---|---|
| Checkout | `~/.worktrees/agent-commander/main-window-3`, HEAD `9ec6076` |
| Build | `swift build` (debug), macOS 27.0.1, display 1728 × 1117 pt |
| Instances | PID 18011 for the main run. PID 46203 for a short run with `-appearance.theme blackGlass`. |
| Fixture | A scratch `AGENT_COMMANDER_HOME` and `fixture-state`, plus a temporary link from `.build/debug/Contents/MacOS/commander-network` to the fixture. The link was removed afterwards. |
| Local service | None, so the window shows "Service offline" |
| Window | 1280 × 800 at launch. Checked at 1280 × 800 and at 1440 × 900. |
| How the window was driven | Accessibility actions scoped to the PID, keystrokes only while that PID was in front, events posted to the PID, and one mouse click |

## Increment 2 fixes

| Check | Result |
|---|---|
| Defect 1: ⌥⌘1 selects Agents | **Fail.** Nothing happens, whether sent as keystrokes or as events posted to the PID. |
| Defect 2: ⌥⌘4 selects Teams | **Fail.** It opens Agents → Runs (4 of 4 tries). ⌥⌘2, ⌥⌘3 and ⌥⌘5 work. |
| Defect 3: presence is its own element | **Fail.** The `servers` readout button covers both readouts (172 pt), and the presence menu is its child. |
| Defect 4: presence shows a check | Pass |
| Defect 5: flat toolbar | Pass for the shell's own items. The console display menu keeps its capsule, as the README documents. |
| Defects 6, 8 and 9 | Pass |
| Minor issues: h:mm:ss countdowns, drain line, "1 claim", Settings eyebrow, friend Decline with its waiting time | Pass |

## Pages

| Page | Action | Result | Screenshots |
|---|---|---|---|
| Needs you | Row opens its page | Pass. The approval opens Approvals with its inspector. | 06 |
| Approvals | Approve | Pass. The row leaves and the alert band confirms it. The audit log records it. | 07, 08, 26 |
| Approvals | Deny | Pass | 09 |
| Approvals | Review opens the grant sheet; Cancel | Pass, and the tray did not move. At 1280 pt, Cancel and Share are off screen (defect 3). | 10, 11 |
| Servers | Detail, certificate review | Pass | 12, 30 |
| Hand-offs | Open a row | Pass | 24, 37, 39 |
| Threads | Post a comment | Pass. The count goes from 3 to 4. | 31 |
| Fan-out | Choose a winner | Pass | 33, 34 |
| People | Decline a friend request | Pass, but no confirmation appears (defect 8) | 35, 36 |
| Directory, Audit, Shared | Layout | Match the renders | 22, 26, 28 |
| Tray route | Opening a review in Hand-offs switched the panel window from Add server to Review | Confirmed, as documented | 38 |
| Black glass | Tables follow the theme. The inspector keeps the console style, as documented. | Pass | 41 |

At 1440 × 900, all nine pages match the renders.

## Defects

| # | Severity | Defect | Expected |
|---|---|---|---|
| 1 | Medium | ⌥⌘1 still does nothing | It selects Agents |
| 2 | Medium | ⌥⌘4 still opens Agents → Runs | It selects Teams |
| 3 | High | At 1280 pt, Servers, Approvals, Directory, Audit and Shared are wider than the window. The rail shifts off the left edge by 4 to 56 pt. Reconnect, the inspector and the breadcrumb are cut off. The grant sheet's Cancel and Share sit at x = 1597 in a window 1504 wide. | Pages fit the window: the table or inspector narrows, or the window has a larger minimum width |
| 4 | Medium | Presence has no accessible element of its own | A menu button "Your presence" with a value such as "Auto: Busy" |
| 5 | Low | The incoming access request row on Approvals, and the friend request row on People, are static text | Selectable buttons with the selected state |
| 6 | Low | Some labels leave out what the screen shows: waiting and "when" times are missing, the alert band reads as one button, "Certificate changed" is said twice, and the certificate inspector has an empty text element | Labels match the screen |
| 7 | Low | The breadcrumb cuts off short names even with room to spare ("Hand-o…", "Approv…") | Full names |
| 8 | Low | Decline on People shows no confirmation | An alert band, as Approve and Deny show |
| 9 | Low | The alert band follows you to other pages | It stays on its page, or clears |
| 10 | Low | The ryan-mac row label says "1 friend requests" | "1 friend request" |
| 11 | Low | Choosing a row discards a form open in the panel, because the pages share the tray's route | Typed input survives, or the shared route goes away (tray request 1) |

These weren't tested:

- **Local Reply:** there was no service running.
- **Apply:** held back by design.
- **Consoles in both themes:** there were no consoles without the service.

## Windows driven

- **PID 18011:** its "Agent Commander" window (resized to 1280 × 800, then 1440 × 900), its "Commander network" window (opened, then closed), and its status item (pressed twice; it didn't open).
- **PID 46203:** "Agent Commander", Settings and Approvals.
- **Not touched:** the user's live app.

## Settings changed and restored

- **`AgentCommander` defaults:** the window-frame key the run added was deleted, so the domain is `{}` again.
- **Fixture link:** removed.
- **Fixture presence:** left at `auto`.
- **System settings:** none changed.
- **Instances:** both were quit by PID.

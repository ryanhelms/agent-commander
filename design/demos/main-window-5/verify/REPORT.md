# Increment 5 (PR #17): running-window check

**Result:** three of the four open increment 4 defects are fixed. Every Teams page opens and fits, and every main action works on the fixture. One increment 4 defect is still open, and the check found new ones.

These pass:
- ⌥⌘1 to ⌥⌘5 from every mode, at 1280 and at 1440. **⌥⌘3 selects People again.**
- Presence is its own element: a menu button "Your presence", value "Auto: Busy". Its menu works.
- Approvals: approved and denied rows both keep their outcome, also after leaving and coming back within the 2 s hold. The counts agree and the countdowns stop.
- Every Teams place opens a real page. Nothing passes the right edge at 1280 or at 1440.
- Every main action works on the fixture: Board, Claims, Integration, Groups, Hosts, Knowledge, Directory and Admin.

These fail:
- **Confirmations below the fold still don't scroll into view at 1280.** This affects the Revoke confirmation, the Review grant sheet and the new Run merge confirmation. It is increment 4 defect 5, so PR #17's claim that it is fixed does not hold.
- **A page's success message follows you to other pages.** It shows on Teams pages and carries across them.
- Teams breadcrumbs leave out "Teams".

The check ran on 26 November 2026 against `f7f80b7` (PR #17, merged as `91df5dc`), using a debug build with the network fixture. The screenshots in this folder are scaled to 1440 px at most.

## Environment

| Item | Value |
|---|---|
| Checkout | `~/.worktrees/agent-commander/issue-10-51f03c875513` at `f7f80b7` |
| Build and system | `swift build` (debug), macOS 27.0.1 (26A434) |
| Instance | PID 17355, launched with `-AllowOnlyOneInstance NO`, console theme |
| Window sizes | 1280 × 800 for most checks. 1440 × 900 for the second fit pass and the mode keys. |
| Fixture | A scratch `AGENT_COMMANDER_HOME` and `COMMANDER_NETWORK_FIXTURE_STATE`, plus a temporary `commander-network` link to the fixture. The link was removed afterwards. |
| Local service | None, so the window shows "Service offline" |
| How the window was driven | Accessibility actions on the PID. Keystrokes only after checking that the PID was frontmost. One mouse click, sent after checking that the PID owned the topmost window at that point. Overflow was measured by walking the accessibility tree for frames past the window's edges. |

## Fixes from increment 4

| Check | Result | Screenshot |
|---|---|---|
| ⌥⌘1–⌥⌘5 from every mode at 1280 | Pass. All 20 changes of mode work. | 01 |
| ⌥⌘3 selects People | **Pass.** It works from all four other modes. | 73 |
| Mode keys at 1440 | Pass, 20 of 20 | 73 |
| ⌘1, ⌘], ⌘[ | Pass. With no run they change nothing, which matches the code: each needs a run, a coordinator or a zoomed worker. Zoom itself needs a live run and wasn't tested. | — |
| Presence is its own element | **Pass.** It is an `AXMenuButton` named "Your presence" with value "Auto: Busy" and id `shell-presence`. A hit test returns it. | 02 |
| Presence menu works | Pass. Choosing Away sets the value to "Away" and writes `presence: away` to the fixture. Auto was restored. The first AXPress didn't open the menu, but a second one did. | 03, 04 |
| Presence has one chevron | **Fail (new).** The pull-down draws a second chevron at the right edge of the readout. | 04 |
| Revoke confirmation scrolls into view (Shared, 1280) | **Fail.** The page stays at the top. The buttons sit at y 1047, below the window's bottom edge at 977. | 07, 08 |
| Review grant sheet scrolls into view (Approvals, 1280) | **Fail.** The scroll position stays at 0. Only the sheet's header shows. | 10 |

## Approvals

| Check | Result | Screenshot |
|---|---|---|
| Approve a row: outcome stays | Pass. The row reads "Approved" and its countdown stops. | 11, 17 |
| Approved row survives leaving and returning within the hold | Pass at 0.7 s. It is gone after the hold. | 18 |
| Deny a row: outcome stays | Pass. The row reads "Denied. fixture-sam is told." with no countdown. | 14 |
| Denied row survives leaving and returning within the hold | Pass at 1.2 s. It is gone after the hold. | 15, 16 |
| Counts agree | Pass. The page figure, the navigation counts and "first lapses in" all leave out answered rows. | 14, 15 |
| Answer two rows quickly | **Fail (new).** A Deny pressed while an Approve was still in flight was dropped without a message. | 11 |

## Teams pages: fit and breadcrumbs

All 13 views have nothing past the left or right edge, at both sizes. Admin is shown, because ryan-mac is an admin server.

| View | 1280 | 1440 | Breadcrumb |
|---|---|---|---|
| Relay reconnect: Board, Combined view, Integration, Claims | Pass (20–23) | Pass (60–63) | "Workspaces › Relay reconnect" |
| iOS onboarding: Board, Combined view, Integration (pull requests), Claims | Pass (24–27) | Pass (64–67) | "Workspaces › iOS onboarding" |
| Groups | Pass (28) | Pass (68) | "Team tools › Groups" |
| Hosts | Pass (29) | Pass (69) | "Team tools › Hosts" |
| Knowledge | Pass (30) | Pass (70) | "Team tools › Knowledge" |
| Directory | Pass (31) | Pass (71) | "Team tools › Directory" |
| Admin | Pass (32) | Pass (72) | "Team tools › Admin" |

- **Breadcrumbs:** "Teams" is missing on every Teams page, Team tools pages included.
- **Truncated text:** the sidebar shows "Relay reconne…", and at 1280 the merge queue's intro ends "merges t…". Host tags and knowledge owners are also cut short.

## Teams actions on the fixture

| Check | Result | Screenshot |
|---|---|---|
| Board: claim a card | Pass. The card moves to Claimed, held by you. | 40 |
| Board: complete with a result | Pass. **Defect:** the Done card still says "Claimed … Nobody else can take it while you hold it." | 41, 42 |
| Refused claim shows the holder | Pass: "Overlapping claim held by fixture-sam/sam-agent." | 43 |
| Release asks first | Pass. Kept. | 44 |
| Queue a branch | Pass. `collab/verify-inc5` is queued as number 5. | 45 |
| Run merge confirmation, then cancel | Pass. It lists each branch with its test command, in order. Don't run merged nothing. **Fail:** it opens below the fold at 1280. | 46 |
| Create a group | Pass. Delete group… asks first. Kept. | 48, 49 |
| Host command | Pass. `run-ios-ui-tests` gave exit 0 with output. With the argument `fail` it gave exit 1. | 50, 51 |
| Share knowledge: secret check | Pass. A token is caught before sending, and Share is disabled. **Defect:** the refusal's text element is empty to accessibility. | 52 |
| Share knowledge at Server scope | Pass. **Defect:** "you shared" stays 0. | 53 |
| Share knowledge: policy limit | Pass, but the message reads only "Couldn't share policy-probe. Forbidden." | 58 |
| Install confirmation, then cancel | Pass. It names `~/.claude/skills/relay-triage/SKILL.md` and is in view. Nothing was written. | 54 |
| Directory: search and endorse | Pass | 55 |
| Admin: set policy | Pass. The fixture was updated, then restored. | 56, 57 |
| Admin: suspend asks first | Pass. Kept. | 59 |
| The tray's Teams page doesn't move | **Not observed.** The tray's status item ignored AXPress, so it wasn't opened. A unit test covers it. | — |

## Defects

| # | Severity | Defect | Expected |
|---|---|---|---|
| 1 | Medium | At 1280 the Revoke confirmation, the Review grant sheet and the Run merge confirmation open below the fold (increment 4 #5, still open) | The opened confirmation or sheet scrolls into view |
| 2 | Medium | A success message follows you to other pages, such as "Queued collab/verify-inc5" on Groups. On Admin it sits above the host's own "Saved" message. | A message stays on the page that raised it |
| 3 | Low–Medium | Presence draws two chevrons | One chevron |
| 4 | Low | Teams breadcrumbs leave out "Teams" | "Teams › Workspaces › Relay reconnect", "Teams › Team tools › Hosts" |
| 5 | Low | A Done card keeps its claim note, on screen and in its accessibility label | The note clears when the card is done |
| 6 | Low | A second answer sent while the first is in flight is dropped without a message | Queue it, or say why it wasn't sent |
| 7 | Low | The secret refusal's text element is empty to accessibility | The refusal text is exposed |
| 8 | Low | Knowledge "you shared" stays 0 after you share | It counts your item |
| 9 | Low | The policy refusal reads only "Forbidden." | It names the widest scope allowed |
| 10 | Low | The Board tab shows 4 or 3 while the heading says "Board, 6". "Its 1 member lose" should read "loses". | Counts that agree, and correct grammar |
| 11 | Low | Knowledge owners show as user IDs ("by u-sam"). The sidebar and the merge-queue intro are cut short at 1280. | Handles where known, and no cut-off sentences |

## Windows driven

- **PID 17355:** its main window, set to 1280 × 800 and then 1440 × 900; its presence menu, three times; its status item, with AXPress only.
- **Unexplained resize:** once, the window went to 1728 × 1083 with no input from the check. It was set back before the next capture.
- **Mouse:** one click on Revoke, after checking that the PID owned the topmost window there.
- **Not touched:** the user's live app, which was not running.

## Settings changed and restored

- **Defaults:** the run added the key `NSWindow Frame cockpit` to the `AgentCommander` defaults. It was deleted.
- **Fixture link:** removed, along with the folders created for it.
- **Fixture changes:** in scratch state only. Presence and the Admin policy were restored.
- **`~/.claude/skills/relay-triage`:** not created.
- **System settings:** none changed.
- **Instance:** quit by PID. No source was edited.

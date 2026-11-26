# Main window increment 6: the router, and the increment 5 defects

This increment adds the open-in-window router the triage tray will call, fixes the 11 defects the [running-window check of increment 5](../main-window-5/verify/REPORT.md) found, and adopts the Teams reads and calls from PRs #22 and #24.

**Not seen in a real window.** Everything here was checked by build, unit tests and headless renders. `PageRevealTests` hosts three pages in a window that is never shown and reads the page's scroll offset, with the bands' sideways scroll on as it is live. Nothing else was driven. The tray's "Open in Agent Commander" row is the network session's and isn't built yet, so the router has no caller.

## Draw the pictures again

```sh
MAIN_WINDOW_6_RENDER_DIR=design/demos/main-window-6 swift test --filter MainWindow6Render
```

Each state is drawn at 1440 × 900 (`<name>-console.png`) and at 1280 × 800 (`fit-1280-<name>-console.png`).

| File | Shows |
|---|---|
| `teams-integration-merge-confirm` | A long queue. The Run merge confirmation was under the fold and is scrolled into view. |
| `network-approvals-grant` | The Review grant sheet, scrolled to its top edge. |
| `network-shared-revoke-confirm` | The Revoke confirmation, scrolled into view. |
| `teams-workspace`, `teams-hosts` | Breadcrumbs that lead with Teams. The workspace's owner as a fact, and Edit… for the owner. |
| `teams-board` | The Board tab's figure matches the heading. A Done card has no claim note. |
| `teams-workspace-edit-confirm` | The owner's edit, and the confirmation that names each change. |
| `teams-workspace-leave-confirm` | A member's Leave…, and its confirmation. |
| `teams-claims-refused` | A refusal that names the holder, the agent and the claim, with the claim's row marked. |
| `teams-knowledge`, `teams-knowledge-share` | Owners by handle, "you shared" counted, and the server's widest scope in the share form. |
| `teams-groups-delete-confirm` | "Its 1 member loses every grant made to the group." |
| `teams-admin`, `teams-admin-suspend-confirm` | Members and devices as the relay lists them: a member with no handle, devices by ID, online or last seen. |

## Needs a check in a window

- The three confirmations scroll into view at 1280 × 800 against the fixture.
- Presence shows one chevron. The pull-down's own arrow is turned off; the picture can't show a toolbar.
- A second answer pressed while the first is in flight goes through after it.
- A page's message is gone on the next page, and Admin shows one "Policy set" band.
- The sidebar wraps "Relay reconnect" to two lines.
- `CommanderWindowRouter.open` from the tray, with the window open and with it closed.

Requests to the network session are in [TRAY-REQUESTS.md](TRAY-REQUESTS.md).

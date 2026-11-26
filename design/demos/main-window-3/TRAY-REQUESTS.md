# Requests to the tray session from main window increment 3

The earlier four requests are met on `develop` at `f0ce59d` and are in use: per-request results, decline a friend request, a hostable grant sheet, and arrival times on friend requests. These are what the network pages asked for after that.

**Status at `86fc56f`:** 1, 2, 3, 4, 5, 6, 7 and 9 are done on `develop` (PRs #6 and #8) and in use by the main window since increment 4. 8 and 10 are open. What increment 4 still asks for is in [`../main-window-4/TRAY-REQUESTS.md`](../main-window-4/TRAY-REQUESTS.md).

| # | Request | Why | Status |
|---|---|---|---|
| 1 | Reads that don't move the tray: a thread, the audit log, a server's certificate check and rename, a hand-off's detail, a fan-out. For example `share.loadThread(_:on:) -> MultiplayerLoad`, or a second route owned by the caller. | Today each is tied to `route`, so the window and the tray share one route. Choosing a hand-off in the window moves an open tray, and the tray changes the window's inspector. `postComment`, `sendAccessRequest`, `sendFanout`, `confirmPost`, `rename` and `saveProfile` all refuse unless the tray's route is theirs. | Done in PR #6. The window owns its route and reads (`loadThread`, `loadAudit`, `checkCertificate(of:)`, `rename(_:to:)`). Removing a server still moves the tray. |
| 2 | Hosts like `MultiplayerGrantHost` for the other composers: Consult, Hand off, Request review, Watch, Add friend, Invite, Membership and Add server. | The window opens the network panel for these. | Done in PR #6. All eight are hosted on the page. |
| 3 | A grant host without its own scroll view, or one that reports its height. | The window gives it a fixed 560 pt inside an inspector that already scrolls with the page. | Done in PR #6 (`scrolls: false`). The fixed 560 pt is gone. |
| 4 | Keep an answered approval or access request in the model's lists for a moment, or say in the result that the caller may show it. | The model removes it on success, so a live row leaves before it can show "Done". | Done in PR #8 (`answer(for:on:)`). An answered row shows its outcome. |
| 5 | Revoke a grant by value: `revoke(_ grant:on:) async -> MultiplayerActionResult`. | Revoke lives on the session's own page and its confirm step. Shared can't offer it. | Done in PR #6. Shared offers Revoke. |
| 6 | Say whether D1 and D7 are fixed on `develop`. | The redesign plan holds Apply, and names approvals, until they are. Apply is not wired in the window. | Done: both are fixed on `develop`. Apply is wired. |
| 7 | A list of threads you take part in, including consults. | Threads shows only hand-offs, reviews and fan-out answers the model already holds. | Done in PR #8 (`loadThreads(on:)`). Threads lists sent and received, consults included. |
| 8 | Let the tray's atoms read `@Environment(\.theme)` instead of `MultiplayerTheme`. | In black glass the inspectors' contents stay console-styled. `DESIGN.md` section 6 already lists this. | Open. |
| 9 | Change the activity sentence "Approve or deny it in the tray". | The feed now also shows in the main window, where the answer is in Approvals. | Done in PR #8. |
| 10 | Let the cockpit run against the network fixture: honour `COMMANDER_NETWORK_BIN` and `COMMANDER_NETWORK_FIXTURE_STATE` when `AGENT_COMMANDER_HOME` is set, without `AGENT_COMMANDER_NETWORK_PANEL`. | Defect 11 of the increment 2 check. The verifier had to link the fixture into the build folder. | Open. |

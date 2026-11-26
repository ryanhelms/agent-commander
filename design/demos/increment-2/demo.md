# Increment 2 demo: Social

Run on 25 November 2026 against the worktree build (`claude/commander-network-f774d6`, binaries built 19:38 from `f4e832c`), the host-mode relay at `https://ryan-mac.tail.internal:8443` and the test device agent (state in the session scratchpad, socket `/tmp/acn/net.sock`). The live Agent Commander and its daemon were not used. Only one user exists on the relay, so friends, linked contacts and feed events were shown with the tray fixture (`Tests/Fixtures/commander-network-fixture.py`).

## Results

| # | Step | Result | Evidence |
|---|---|---|---|
| 1 | `me`: admin true, mode open | Pass | `01-me.json` |
| 2 | `profile` sets displayName and statusMessage; `status` shows them | **Fail** (D1) | `02-profile-set.json`, `03-status-after-profile.json` |
| 3 | `presence busy`; `servers` shows `presence: busy` | Pass | `04-presence-busy.json`, `05-servers-presence-busy.json` |
| 4 | `presence auto`; presence returns to the automatic value | Pass, with D3 | `06-presence-auto.json`, `07-servers-presence-auto.json` (still busy right after), `07b-servers-presence-auto-later.json` (online) |
| 5 | `invite-create` returns an `agentcommander://join` link with server, pin, code and `from` | Pass | `08-invite-create.json` |
| 6 | `membership` returns mode, allowed emails, admins, member count | Pass | `09-membership.json` (admin email redacted) |
| 7 | `contacts`, `activity`, `activity-seen` with the cursor | Pass (empty: no second user, no events) | `10-contacts.json`, `11-activity.json`, `12-activity-seen.json`, `13-activity-after-seen.json` |
| 8 | Extras: `avatar` with none set returns 404 error; `/v1/info` carries `membership: open` | Pass | `14-avatar-none.json`, `15-relay-info.json` |
| 9 | UI (live daemon): home with presence picker (Auto, Online, Away, Busy, Do not disturb) | Pass, with D4 | `20-ui-home.png`, `21-ui-presence-picker.png` |
| 10 | UI: choose Busy in the picker, header and daemon follow; choose Auto again | Pass | `29-ui-home-presence-busy.png`, `30-ui-presence-picker-while-busy.png` |
| 11 | UI: profile editor shows the saved name and status | **Fail** (D1, D2) | `23-ui-profile-editor-after-cli-save.png` (empty fields), `24-…filled.png`, `25-ui-after-profile-save.png` ("Profile saved."), `26-ui-profile-editor-reopened.png` (empty again) |
| 12 | UI: invite sheet creates a link | Pass | `27-ui-invite-link.png` |
| 13 | UI: membership settings for an admin (mode, allowed emails, admins, member count) | Pass | `22-ui-server-detail.png`, `28-ui-membership.png` |
| 14 | UI (live daemon): activity feed | Pass (empty state only) | `20-ui-home.png` |
| 15 | UI (fixture): linked contacts across two servers | Pass, with D5 | `40-fixture-home.png`, `41-fixture-linked-contacts.png` |
| 16 | UI (fixture): unseen badge ("3 new"), feed, Mark as seen clears it | Pass, with D6 | `42-fixture-activity-unseen.png`, `47-fixture-activity-after-mark-seen.png` |
| 17 | UI (fixture): feed filters by server and by friend | Pass | `43-…server-menu.png`, `44-…filter-server.png`, `45-…friend-menu.png`, `46-…server-and-friend.png` |
| 18 | UI (fixture): profile editor loads saved values; allowlist membership | Pass (fixture only) | `48-fixture-profile-editor.png`, `49-fixture-membership-allowlist.png` |
| — | macOS notifications for new events, and none under DND | Not run | The fixture's events are static and only events arriving after the first load are notified; no second user to create live events. Code path read in `MultiplayerSocialModel.applyActivity`. |
| — | `agentcommander://join` handler, friend request from `from` | Not run | Opening the URL would route through Launch Services to the live app. |
| — | Avatar upload | Not run | Picture chooser not exercised. |

## Defects

- **D1. The device agent's `status` verb omits the user's own `displayName`, `statusMessage` and `hasAvatar`.** It fetches `GET /v1/profile` but returns only `handle` (`multiplayer/internal/device/tray.go`, `status`). The fixture's `status` does return them, so the profile editor works on the fixture and opens empty on a real relay (`23-…png`, `26-…png`). Saving from an empty editor works, but a person cannot see what they saved.
- **D2. "Profile saved." banner stays on the next screens.** After saving, it shows on the server page, the reopened profile editor and the invite sheet until dismissed.
- **D3. `presence auto` does not push the automatic value at once.** It returns `{"presence":"auto","auto":true}` (not the effective presence) and the relay keeps the old manual value until the 30-second presence loop runs (`07-…json` still busy, `07b-…json` online).
- **D4. The presence picker marks no current choice, and the header hides whether Auto is on.** Visually the button shows only the effective presence ("Online" or "Busy"); the menu has no check mark. Only the accessibility label adds ", auto".
- **D5. "Friends 6 online" counts a linked contact once per server and counts Away as online.** Sam Rivera appears on two servers and is counted twice; fixture-mei (Away) is counted.
- **D6. Server rows show no per-server unseen count**, although `ServerSummary.unseen` is in the contract and the fixture returns it. The only badge is "3 new" on the Activity heading.
- **D7 (minor).** Each activity filter is exposed twice in the accessibility tree (two "Filter by server" and two "Filter by friend" menu buttons).

## Visible differences from the mockup (`design/mockups/commander-network-tray.html`)

- Header (c): presence badge reads "Busy" without the mockup's "3 agents running" count.
- Tally: three cells; "remote runs" is increment 3 (expected).
- Friends: linked badge reads "also on studio-relay" with a link icon, as in the mockup's "⛓ also on team-relay". Rows add an avatar tile and show the handle under the display name. Share is disabled on studio-relay with the hint "Add a resource on this server first".
- Activity: filter menus and time column match. Each row adds a server swatch. The mockup shows no "N new" count or Mark as seen button.
- Hosting (e): the mockup puts allowed emails and the invite link in the Hosting sheet with Copy link, Show code and Show QR. The build has a separate Membership page (mode segments, allowed emails and admins text areas) and an Invite page (uses stepper, expiry segments, Copy link). No Show code or Show QR.
- Live server name stays the full host name `ryan-mac.tail.internal` (increment 1 D4) and has no "Hosted here" badge; the fixture's server has it.

## State left behind

- Presence mode restored to `auto` (pushed `online`). Membership mode unchanged (`open`).
- The relay profile for `ryan` now has displayName "Ryan Helms" and statusMessage "Demoing increment 2 (UI)". The previous values could not be read (D1), so they were not restored.
- Two invite codes exist on the relay (5 uses, expire 2 December). Neither was copied or used.
- Both demo app processes were quit. The clipboard was not touched (Copy link not pressed).

## Run notes

- Both launches ran the worktree binary directly with `-AllowOnlyOneInstance '<false/>'`, a fresh `AGENT_COMMANDER_HOME` in the scratchpad and `AGENT_COMMANDER_NETWORK_PANEL=1`. The fixture launch used `COMMANDER_NETWORK_BIN` and a scratch `COMMANDER_NETWORK_FIXTURE_STATE`.
- The UI was driven through the accessibility API scoped to the demo process. Menus were operated with arrow keys only after checking that the demo process was frontmost.

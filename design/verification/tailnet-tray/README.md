# Tailnet band in Add server: captures

Issue #48. Spec: [Device side: the tray UI](../../COMMANDER-NETWORK-TAILNET.md). Design: [DESIGN.md](../../../DESIGN.md), "Tailnet band" and the Relay row and Secret field molecules.

Every capture is the worktree's debug app in panel mode on the fixture. No `tailscale` CLI ran and nothing reached a network. All names are made up (`fixture-lab`, `tail.example`).

## How they were made

```sh
swift build
AGENT_COMMANDER_HOME=<scratch folder> AGENT_COMMANDER_NETWORK_PANEL=1 \
COMMANDER_NETWORK_BIN="$PWD/Tests/Fixtures/commander-network-fixture.py" \
COMMANDER_NETWORK_FIXTURE_STATE=<scratch file> \
COMMANDER_NETWORK_FIXTURE_TAILNET=<running|empty|missing|off|pending|error> \
.build/debug/AgentCommander -AllowOnlyOneInstance '<false/>'
```

Each window was driven through accessibility presses (Network tab, Add server, then the control named below) and captured with `screencapture -l <window id>`, cropped to the panel. The user's live Agent Commander was not touched. The debug processes were stopped afterwards.

## Captures

| File | Fixture start | State | What it shows |
| --- | --- | --- | --- |
| `01-running.png` | `running` | Running | Tailnet name as an `on` state label, three relay rows (online, offline, added), the hint line. |
| `02-running-relay-chosen.png` | `running` | Running, after pressing the build-relay row | The row is filled `selection` with the `focus` marker, the address field holds `https://build-relay.tail.example`, and the health check ran: "All 5 steps passed". |
| `03-cli-missing.png` | `missing` | CLI missing | "Not installed", the sentence, Get Tailscale and Check again. |
| `04-no-relays.png` | `empty` | Running, no tagged relay | Count 0 and the `tag:relay` sentence. |
| `05-read-failed.png` | `error` | Verb error | "Not checked", the reason in `failure`, Try again. The address field stays usable. |
| `06-join-browser.png` | `off` | Join form, browser | Login server field, segments, Join tailnet (off until a login server is typed). |
| `07-join-auth-key.png` | `off` | Join form, auth key | The secure Auth key field appears only under this choice. |
| `08-login-pending.png` | `pending` | Login pending | `waiting` lamp, the login URL as a copy chip, Open login page. |
| `09-joined-after-poll.png` | `pending`, 7 s later | Running | The same window after the 2 s poll saw the login finish: the relays are listed with no action from the person. |

## Compared with DESIGN.md

No difference that matters was found in these captures. Checked on each: band padding and hairline, `heading` type for "Tailnet" with the count in full ink, state labels in `state` type with the right lamp and tone, `sub` prose in secondary ink, field boxes at 30 pt, standard buttons at 24 pt, and one filled primary action on the page (Save server).

Small things to know:

- **The selected relay row is wider than the band's text.** Its `selection` fill runs 8 pt past the band's inset on both sides, so the row's text keeps the band's alignment. The hairlines between rows stay on the inset.
- **Join tailnet is a standard button, not primary.** DESIGN.md allows one primary action per region; the page's primary stays Save server.
- **The waiting lamp is `focus` blue beside `attention` words.** That is the lamp atom's own drawing, the same as elsewhere in the tray.
- **The captures show the review stage's caption** under the panel ("The menu bar network panel, shown in this window…"). It is not part of the tray.

## Not captured from the running window

- **Typing a login server and pressing Join.** An accessibility "set value" fills the field's text but does not reach SwiftUI's binding, and real key presses would have needed the debug window in front of the user's work. The join paths are covered by `MultiplayerTailnetTests` instead: the browser join (`off` → pending → poll → running) and the key join (a refused key, then a good one), both against the fixture.
- **The hosted Add server form** in the main window (`MultiplayerAddServerHost`). It draws the same band from the same model; it was not opened in a running window.
- **Black glass theme.** The menu bar tray is fixed to the console theme, so only console was captured.

`MULTIPLAYER_RENDER_DIR=<folder> swift test --filter MultiplayerTailnetTests` (with the flags `make test-native` uses) draws the six states headless, at full height, as `tailnet-<state>.png`.

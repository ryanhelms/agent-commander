# Main window increment 4: live work on the wall

## Where the wall stood at `5680b11`, before this increment

Written before any code changed.

### Already there (from the network session, in `MultiplayerWall.swift`)

- **Remote workers band.** Hand-offs you sent show under the local workers as up to three remote worker tiles. The band draws nothing until there is a hand-off.
- **Remote worker tile.** The console title bar and harness surface of a local tile, with task, from, via and sent as mono lines.
- **Remote zoom.** Choosing a tile zooms it: the hand-off's task and state, then the tray's watch view, read-only. It reads while it is on screen.
- **Network pages.** Hand-offs, Fan-out, Approvals and Shared are full pages bound to the network model (increment 3). Shared shows who holds control and offers Take back.

### Gaps

| # | Gap | Fix in this increment |
|---|---|---|
| 1 | The wall's own frame ignores the theme. In the console theme the pane headings, the worker groups (15 pt corners, glass fill) and the count badge are still black glass. | Wall tokens in both themes; the headings, groups and band read them. |
| 2 | The Remote workers band is console-styled in both themes, so in black glass it has 2 pt corners beside 15 pt groups. | A band composed outside `MultiplayerWall.swift` from the same tile, in the wall's frame. |
| 3 | The wall says nothing when a friend holds one of your workers. Control shows only in the tray and on Shared. | A dock under the held worker's tile: holder badge, countdown, Take back. |
| 4 | A waiting Co-pilot suggestion shows in Needs you and Approvals, not at the worker it is for. | The same dock names who suggests what and opens its review. |
| 5 | The wall reads `MultiplayerModel.shared` inside the cockpit page, so it can't be drawn from values or rendered headless with remote work. | The cockpit takes the wall's live work as a value and sends actions out. |
| 6 | The band and the zoom lead only to the tray ("Open in tray", "n more…"). Reviews and fan-outs you sent don't show on the wall. | Links go to Hand-offs and Fan-out; reviews and fan-outs that still need you are rows in the band. |
| 7 | Apply and Save on a hand-off's artifact open the network panel. | Apply in the Hand-offs inspector, with a confirmation naming the checkout and a result per artifact. |
| 8 | The console tiles' shells and controls must not change. | Untouched. Everything above sits around the tile. |

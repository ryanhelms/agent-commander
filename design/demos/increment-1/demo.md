# Increment 1 demo: Connect

Run on 25 November 2026 against the worktree build (`claude/commander-network-f774d6`), the host-mode relay at `https://ryan-mac.tail.internal:8443` and a test device agent (state in the session scratchpad, socket `/tmp/acn/net.sock`). The live Agent Commander and its daemon were not used.

## Results

| # | Step | Result | Evidence |
|---|---|---|---|
| 1 | `servers` lists ryan-mac online and signed in | Pass, with defect D1 | `01-servers.json` |
| 2 | `server-probe ryan-mac.tail.internal:8443`: 5 steps pass, pin offered | Pass | `02-probe-ryan-mac.json` |
| 3 | `server-probe team-relay.invalid`: stops at DNS with a clear reason | Pass | `03-probe-invalid.json` |
| 4 | Probe and add a second entry by IP `100.64.0.1:8443` with the probe's pin | Pass | `04-probe-ip.json`, `06-server-add-ip.json` |
| 5 | `server-update` favorite, then `servers` lists favorites first | Pass | `07-server-update-favorite.json`, `08-servers-favorites-first.json` |
| 6 | `servers.json` on disk lists both servers (mode 0600, `servers/<id>/` 0700) | Pass | `09-servers.json-on-disk.json` |
| 7 | `server-remove` the second entry; entry and its `servers/<id>/` folder are gone | Pass | `15-server-remove.json`, `16-servers-after-remove.json`, `17-servers.json-after-remove.json` |
| 8 | UI home: ryan-mac online, favorites first, per-server state | Pass, with D1 and D4 | `10-panel-home.png` |
| 9 | UI Add server: failed DNS step | Pass | `11-add-server-dns-fail.png` |
| 10 | UI Add server: 5 steps pass, fingerprint shown, pin confirmed, Save enabled | Pass, with D2 and D3 | `12-add-server-probe-pass.png`, `13-add-server-pin-confirmed.png` |
| 11 | UI server detail shows "Signed in as ryan" | Pass | `14-server-detail-ryan-mac.png` |
| 12 | UI after removal, then after quitting and relaunching the app: server reloads without retyping | Pass | `18-panel-home-after-remove.png`, `19-panel-home-after-app-restart.png` |
| — | Daemon restart persistence | Not run | The test daemon was not to be restarted. Only on-disk `servers.json` and an app relaunch were checked. |
| — | Google sign-in on the second server | Not run | Out of scope (no sign-in allowed). The second server stayed `signedOut`. |

## Defects

- **D1. `servers` returns an empty `handle` for a signed-in server until `status` has been called for it.** First `servers` call: `signedIn: true, handle: ""` (`01-servers.json`); after `tray status`, `handle: "ryan"` (`08-…json`). The home panel never shows the handle.
- **D2. Add server accepts a URL that is already in the list.** Probing `ryan-mac.tail.internal:8443` (already saved) ends with "Ready to save." and an enabled Save button; no duplicate warning (`13-…png`).
- **D3. Switches look the same on and off.** "Connect automatically" (on by default) and the pin switch use a grey track with no on-state tint (`11-…png`, `13-…png`). The mockup's `.tog` uses the working green. The pin switch's accessibility label is empty (the label text sits beside it as a separate static text).
- **D4. Default name is the full host name.** Adding by host gives `name: "ryan-mac.tail.internal"`; the contract example and mockup use the short `ryan-mac`.
- **D5. Probe `tls` step omits `systemTrusted`** listed in the contract's `Probe` shape (`02-…json`).
- **D6. `server-add` changes another server's `lastUsedAt`.** Adding `s-908ddfff` moved `s-f01fcff5`'s `lastUsedAt` to the same instant, which affects recents ordering.
- **D7 (minor).** Accessibility value of the tally reads "1 of 1 servers online" (plural); relay step detail reads "commander-relay host 1" without the "compatible" wording in the mockup.

## Visible differences from the mockup (`design/mockups/commander-network-tray.html`)

- Home (c): tally has 3 cells, not 4 ("remote runs" is increment 3 — expected). No "Hosted here" badge on ryan-mac. No "Online" header presence line (increment 2 — expected). Server swatch colour sits beside the name rather than as a separate column; matches intent.
- Home (c): a signed-out server shows a "Sign in" button in place of a status word; the friends section lists it as "signed out". Mockup has no signed-out row to compare.
- Add server (b): no "Colour" swatch picker; no "Choose client file…" path was exercised (client was configured). Step layout, numbered pending steps, failed-step styling and footer text ("Fix step 1 to finish.") match.
- Server detail: shows Address, Nickname, Connect automatically, Favorite, Remove server…, friends and sharing sections. It does not show the pinned fingerprint or "Pinned on" date that state (d) relies on.
- Certificate-changed (d) and Hosting (e) states were not exercised.

## Run notes

- Launching the bundle binary directly while the live app runs hands the launch to the live cockpit (single-instance admission) and exits. This happened three times before the workaround and brought the live cockpit window forward; no other state changed. The working launch adds `-AllowOnlyOneInstance '<false/>'` (argument domain only; the string `NO` is not read as a Bool). The UI was driven through the accessibility API scoped to the demo process's PID.

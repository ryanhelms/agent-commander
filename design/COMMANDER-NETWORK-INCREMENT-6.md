# Increment 6 contract: Remote

Scope from [the spec](COMMANDER-NETWORK-SERVERS.md), increment 6: a web view served by your own Mac over the tailnet, for approvals and watching from a phone.

## Where it runs

The device agent (`commander-network serve`) serves the web view when the person turns it on in the tray.

- It listens on HTTP at the Mac's tailnet address only, port 8780 by default, for example `http://ryan-mac.tail.internal:8780`.
- It never listens on a LAN or public interface.
- Tailnet traffic is already encrypted between devices (WireGuard). The web view adds pairing and sessions on top.

## Pairing

1. The tray verb `remote-enable` with `{"listen"?}` starts the server and returns `{"url", "code", "expiresAt", "pairURL"}`. The code is 8 characters and lasts 10 minutes. The tray shows it with a QR code of `<url>/pair?code=<code>`.
2. The phone opens the link. The server checks the code, then sets an HttpOnly, SameSite=Strict session cookie that lasts 30 days. Each paired device is listed with the name the person gives it.
3. `remote-devices` returns `{"devices", "url", "running"}` and, while an unused code is on offer, `"pairing": {"code", "expiresAt", "pairURL"}`; a code that has been used disappears from it. `remote-revoke` with `{"device"}` removes one. `remote-disable` stops the server and keeps the pairings.

## API (cookie session required)

| Route | Returns or does |
|---|---|
| `GET /api/overview` | Server summaries, unseen activity, pending approvals across servers, and active hand-offs |
| `GET /api/approvals` | Pending approvals with their server |
| `POST /api/approvals/{server}/{id}/approve` and `/deny` | Same as the tray verbs |
| `GET /api/activity` | The merged activity feed |
| `GET /api/handoffs` | Hand-offs per server |
| `GET /api/watch/{server}/{resource}?after=` | One watch page: `{status, events, cursor, state}` (increment 4 `agent.watch`) |
| `GET /api/watchable` | Friends' resources that grant me `agent.watch`, with their server |
| `POST /api/activity/seen` with `{"cursor"}` | Marks activity as seen, as the tray verb does |

Every POST needs the header `X-Commander-Remote: 1` as a cross-site request guard.

## Web page

`GET /` serves one self-contained page, without a session; API calls without a session answer 401 and the page shows how to pair. The page has no external assets. It shows approvals with Approve and Deny, the activity feed, hand-offs, and a read-only watch view. It follows the tray's tokens: dark by default, with the light theme from `prefers-color-scheme`. Fable owns its design.

## Ownership

| Part | Owner |
|---|---|
| Server, pairing, sessions, API | Claude |
| The page (`internal/device/remote/index.html`, embedded) and the tray's Remote section with the QR code | Fable |

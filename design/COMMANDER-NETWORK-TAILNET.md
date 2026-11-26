# Commander network: relays over a tailnet

Status: proposal, 2026-11-26. Builds on remote relay deployment ([PR #45](https://github.com/ryanhelms/agent-commander/pull/45)). Tracked in the GitHub issue linked from the PR that adds this file.

## Goal

Let a relay and the devices that use it meet on a Headscale or Tailscale network (a tailnet) instead of a public port. A relay joins the tailnet as its own node. A Mac running Agent Commander checks that it is on the tailnet, offers to join one when it is not, and lists the relays it can see, so you add one without typing a URL.

[Servers](COMMANDER-NETWORK-SERVERS.md) said reachability is not Commander's concern. That stays true for the connection itself: the device agent still dials a URL, pins the certificate and signs in exactly as before. This proposal adds only the two steps around it: putting the relay on the tailnet, and finding it from the tray.

## What does not change

- The relay still terminates TLS itself, with device client certificates. Clients still pin its SPKI. The tailnet is an extra layer, not a replacement for the relay's own authentication.
- Sign-in still goes through the relay's OIDC issuer.
- The production Headscale (`https://adag.bytedesk.ai`, MagicDNS suffix `tail.internal`) is only ever used, never changed, by Commander. Keys, users, tags and policy there are the operator's to manage.

## Relay side: a Tailscale sidecar in Docker mode

`remote.py deploy docker` takes a tailnet option:

```sh
python3 -B multiplayer/deploy/remote/remote.py deploy docker ops@server \
  --tailnet-login-server https://adag.bytedesk.ai \
  --tailnet-auth-key-file ~/relay.key \
  --tailnet-hostname agent-relay \
  --issuer https://accounts.google.com --client-id "$CLIENT_ID" --admin you@example.org
```

| Piece | What the deploy runs |
| --- | --- |
| Sidecar | `agent-commander-relay-tailnet`, from `tailscale/tailscale`, on the host network in userspace mode (`--tun=userspace-networking`). It creates no TUN device, route or firewall rule on the server and needs no capabilities. It logs in to `--tailnet-login-server` with the pre-auth key, as `--tailnet-hostname`, with `--accept-dns=false`. Its state, socket and serve configuration live in the `agent-commander-relay-tailnet` volume, so the node keeps its name and 100.x address across redeploys. |
| Relay | The same `agent-commander-relay` container, on the host network with no published port. It listens on `127.0.0.1:18443` (`--tailnet-local-port`), so nothing outside the server reaches it directly, and it does not collide with a proxy on `*:443`. |
| Forwarding | `tailscale serve --bg --tcp 443 tcp://127.0.0.1:18443` in the sidecar. It forwards raw TCP, so the relay's TLS and device client certificates pass through untouched. |
| Certificate names | After the sidecar is up, the deploy reads its MagicDNS name and tailnet addresses (`tailscale status --json`) and adds them to the relay's hostnames with `commander-relay host configure`. The relay reissues its leaf certificate with the same key, so the pin does not change. |
| URL | `https://agent-relay.tail.internal`. `--hostname` becomes optional: the tailnet names are enough. |

**Why not a shared network namespace.** A first design ran the sidecar on the Docker bridge with a kernel TUN device and started the relay with `--network container:<sidecar>`. It works where the bridge has egress, but it failed on the production router: that Docker bridge has no outbound internet, so the node got neither DERP nor STUN, and a container cannot hairpin to the router's public address. Userspace mode on the host network uses the host's own egress and leaves the host's networking alone. The relay deployed by hand next to the production Headscale uses this layout.

The pre-auth key:

- is read from a file or the `TS_AUTHKEY` environment variable on the deploying Mac, never from the command line;
- reaches the server on SSH standard input, sits in a 0600 temporary file only while the sidecar starts, and is used once (`TS_AUTH_ONCE`);
- is needed only for the first deploy. A redeploy reuses the logged-in node state.

**Tag the relay node `tag:relay`.** Create the pre-auth key with that tag (Headscale: `headscale preauthkeys create --user USER --tags tag:relay`), or pass `--tailnet-tag tag:relay` to advertise it when the tailnet policy lets the key's user own the tag. Devices find relays by this tag.

`status` reports the sidecar's tailnet state next to the relay's. `remove` stops both containers and keeps both volumes. Systemd mode is out of scope for this increment: a host with Tailscale already installed can use the existing systemd mode with `--hostname <name>.tail.internal --hostname 100.x.y.z --bind 100.x.y.z`.

## Device side: tray verbs

The device agent owns the tailnet adapter. It runs the local `tailscale` CLI (found on `PATH`, in Homebrew, or inside `Tailscale.app`). It never talks to the control server directly. Three verbs join the tray API, next to the `server-*` verbs:

| Verb | Input | Returns |
| --- | --- | --- |
| `tailnet-status` | none | Whether the CLI exists; the backend state (`Running`, `NeedsLogin`, `Stopped`, …); the tailnet name and MagicDNS suffix; this node's name and addresses; a pending browser login URL. |
| `tailnet-join` | `loginServer` (HTTPS URL), and optionally `authKey` and `hostname` | Starts `tailscale login --login-server …`. With an auth key the CLI reads it from a 0600 file that is removed afterwards. Without one, the verb waits for the login URL, opens it in the system browser and returns it. It refuses when this Mac is already running on a tailnet, so it never switches the user's network by surprise. |
| `tailnet-relays` | optionally `tag` (default `tag:relay`) | Peers that carry the tag, with their MagicDNS name, addresses, online state, the relay URL `https://<name>` and whether that URL is already in the server list. |

Adding a listed relay is the existing flow: the tray calls `server-probe` with the listed URL, shows the TLS fingerprint and calls `server-add` with the confirmed pin. Discovery never trusts a pin on its own.

## Device side: the tray UI (frontend task)

In the network tray's **Add server** sheet, built from the components in `Sources/AgentCommander/MultiplayerServers.swift` and [DESIGN.md](../DESIGN.md):

1. A **Tailnet** section above the URL field. When `tailnet-status` reports `Running`, it shows the tailnet name and the relays from `tailnet-relays` as rows. Choosing a row fills the URL and runs the existing probe.
2. When the CLI is missing, the section says so and links to Tailscale's download page.
3. When the Mac is not on a tailnet, the section offers **Join a tailnet**: a login server field, a choice between **Sign in with browser** and **Use an auth key**, and a Join button. While the login is pending the section shows the login URL and polls `tailnet-status`.
4. Relays already in the list show as added and are not selectable.

This is frontend work under AGENTS.md: Fable with the `frontend-design` skill, DESIGN.md components and tokens, and a Codex verification pass on the running app.

## Verification

`multiplayer/deploy/remote/testhosts/rehearse.py --mode tailnet` starts a disposable Headscale container on a private Docker network and never touches the production server. It:

1. creates a Headscale user and two tagged pre-auth keys;
2. deploys the relay to the Docker test host with the userspace sidecar and no published port;
3. checks that neither 443 nor the loopback port answers on the test host's own address;
4. starts a client node on the same Headscale, runs `remote.py connect` against `https://agent-relay.tail.internal`, and runs the Linux device agent there: `tailnet-status`, `tailnet-relays` and `server-probe` on the listed URL, with the pin matching the deploy;
5. redeploys without an auth key and confirms the node name, address and pin are unchanged.

The tray verbs have unit tests against a fake `tailscale` CLI.

## Out of scope

- Changing the production Headscale: creating keys, users, tags or ACLs. The operator does this.
- Tailscale Serve HTTPS, Funnel or Tailscale-issued certificates. Serve forwards raw TCP only; the relay keeps its own CA and pin.
- Embedding Tailscale (`tsnet`) in the relay or the app.
- Systemd-mode sidecars.

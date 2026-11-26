# Deploy a relay to a remote Linux host

`commander-relay deploy` installs `commander-relay host` on a Linux server over SSH, then connects to it as Agent Commander would. Host mode is one process with an embedded JetStream broker and a private PostgreSQL child, so the server needs no separate database or broker. Choose one of two forms:

| Mode | What runs on the server | The server needs |
| --- | --- | --- |
| `docker` | One container from the host image, with its state in the `agent-commander-relay` volume | Docker Engine |
| `systemd` | `agent-commander-relay.service`, a sandboxed system service with its state in `/var/lib/agent-commander/relay` | systemd, and apt or dnf to install PostgreSQL when it is missing |

For a multi-edge deployment with replicated brokers, use the [Compose pilot](../README.md) instead.

## Before you deploy

On the Mac that runs the deploy:

- SSH access to the server with a key. The SSH user is root, or has passwordless `sudo`. In Docker mode, membership of the `docker` group is enough.
- `commander-relay` for this Mac: `make relay` writes `dist/commander-relay`, and the app bundle carries one in `Contents/MacOS`.
- Docker Desktop with Buildx for Docker mode. For systemd mode, Go, or a prebuilt Linux relay passed with `--binary`.
- Run the deploy from the repository, which holds the image recipe and relay source, or pass `--module` with the `multiplayer` directory.

On the server:

- x86-64 or arm64 Linux.
- Inbound TCP on the relay port, 443 by default. Clients make direct TLS connections, so any load balancer must pass TLS through.
- Outbound HTTPS to the OIDC issuer. The relay reads the issuer's discovery document when it starts.
- A DNS name for the server, or clients that connect by IP address.

You also need an OIDC client for the Agent Commander desktop app and at least one administrator email. See [the pilot guide](../README.md#prepare-the-host) for the Google Desktop client setup.

## Deploy

Run the deploy from the repository root. Each `--hostname` goes into the relay's certificate. The first one forms the URL that clients use.

```sh
dist/commander-relay deploy systemd ops@relay.example.org \
  --hostname relay.example.org \
  --issuer https://accounts.google.com \
  --client-id "$COMMANDER_GOOGLE_DESKTOP_CLIENT_ID" \
  --admin you@example.org
```

For a container, replace `systemd` with `docker`. Other options:

- `--allow-email` adds a member. Repeat it for each person. Without it, any account of the OIDC client may join.
- `--port` sets the public port. `--bind` limits the listener to one address.
- `--ssh-port`, `-i KEY` and `-o OPTION` pass through to `ssh`.
- `--binary` deploys a prebuilt Linux `commander-relay` in systemd mode instead of building one.
- `--public-url` names the URL clients use when a proxy or port mapping changes it.

The deploy prints the relay URL and its server pin, then runs the connection check:

```json
{"mode": "systemd", "url": "https://relay.example.org", "pin": "sha256/…"}
```

Deploying again upgrades the relay in place. It keeps the configuration, database and TLS identity, so the pin stays the same and clients reconnect without trusting it again. The configuration options apply only to the first deploy. To change them later, edit `host.json` on the server and restart the relay.

## Deploy on a tailnet

In Docker mode the relay can join a Headscale or Tailscale network (a tailnet) instead of opening a public port. The deploy runs a `tailscale/tailscale` sidecar, `agent-commander-relay-tailnet`, in userspace mode on the host network. The relay listens on `127.0.0.1:18443` only, and `tailscale serve --tcp 443` forwards tailnet connections to it as raw TCP, so TLS and device certificates pass through untouched. Neither container publishes a port or changes the server's routes, firewall or TUN devices, and neither needs the Docker bridge to have outbound access.

Before the first deploy, create a pre-auth key for the relay node and tag it `tag:relay`, so devices can find it. On Headscale:

```sh
headscale preauthkeys create --user USER_ID --tags tag:relay --expiration 1h
```

Save the key in a file, then deploy:

```sh
dist/commander-relay deploy docker ops@server.example.org \
  --tailnet-login-server https://headscale.example.org \
  --tailnet-auth-key-file ~/relay.authkey \
  --issuer https://accounts.google.com \
  --client-id "$COMMANDER_GOOGLE_DESKTOP_CLIENT_ID" \
  --admin you@example.org
```

- The node name is `agent-relay` unless you pass `--tailnet-hostname`. The relay URL is `https://<node>.<MagicDNS suffix>`, such as `https://agent-relay.tail.internal`.
- The deploy adds the node's MagicDNS name and tailnet addresses to the relay certificate. `--hostname` is optional and adds more names.
- The key is read from the file, or from `TS_AUTHKEY`. It reaches the sidecar on SSH standard input, never on a command line or in the container's configuration. Only the first deploy needs it: the `agent-commander-relay-tailnet` volume keeps the node's login, name and address.
- `--tailnet-tag tag:relay` advertises the tag instead, when the tailnet policy lets the key's user own it.
- The server needs outbound access to the login server and to DERP, or direct UDP to its peers. `--tailnet-local-port` changes the loopback port when 18443 is taken.
- The connection check runs from the Mac that deploys, so that Mac must be on the same tailnet. Otherwise pass `--no-connect` and check from a tailnet node.

`status` adds the sidecar's tailnet state. `remove` removes both containers and keeps both volumes. To free the node name, run `docker exec agent-commander-relay-tailnet tailscale logout` on the server before `remove`.

## Connect from Agent Commander

1. Open the network tray and choose **Add server**.
2. Enter the relay URL.
3. The check shows the steps DNS, TCP, TLS, relay and sign-in. Compare the TLS fingerprint pin with the `pin` from the deploy, then confirm it.
4. Sign in with an administrator or member account.

To check a relay from a terminal, run `deploy connect`. It checks the pin, reads `/v1/info`, and confirms that `/ready` answers a device certificate with HTTP 204 and refuses a client without one.

```sh
dist/commander-relay deploy connect https://relay.example.org --pin 'sha256/…'
```

## Operate

```sh
dist/commander-relay deploy status systemd ops@relay.example.org
dist/commander-relay deploy remove systemd ops@relay.example.org
```

`status` prints the state, server pin and CA pin. `remove` stops the relay and removes the container or unit. It keeps the data volume or `/var/lib/agent-commander/relay`, so a later deploy resumes with the same identity. Back up that volume or directory. It holds the database and TLS keys.

Read the logs on the server:

```sh
journalctl -u agent-commander-relay
```

```sh
docker logs agent-commander-relay
```

## What each mode installs

**systemd.** The deploy cross-compiles `commander-relay` for the server's architecture and copies it to the server. Then it runs `commander-relay host provision` there as root. Provision installs the distribution's PostgreSQL server when none is present, without creating its default cluster. It creates the `agent-commander` system account and the 0700 host directory, moves the binary to `/usr/local/bin`, writes the configuration on the first deploy only, then runs `commander-relay host install`. The unit runs as `agent-commander` with `NoNewPrivileges`, `ProtectSystem=strict` and write access only to the host directory. Its one capability is `CAP_NET_BIND_SERVICE`, for port 443. To install by hand on a server with the binary in place, run the same two commands:

```sh
sudo -u agent-commander commander-relay host --dir /var/lib/agent-commander/relay init \
  --name relay --hostname relay.example.org --issuer https://accounts.google.com \
  --client-id "$CLIENT_ID" --admin you@example.org
sudo commander-relay host --dir /var/lib/agent-commander/relay install
```

**docker.** The deploy builds [`host.Dockerfile`](host.Dockerfile) for the server's architecture and streams the image over SSH. The image adds `commander-relay` to `postgres:17-alpine` and runs as the `postgres` account. The container has a read-only root filesystem, no capabilities and `no-new-privileges`. It listens on 8443, published on the public port. To run the image yourself:

```sh
docker volume create agent-commander-relay
docker run --rm -v agent-commander-relay:/data agent-commander-relay:current init \
  --name relay --listen :8443 --hostname relay.example.org \
  --issuer https://accounts.google.com --client-id "$CLIENT_ID" --admin you@example.org
docker run -d --name agent-commander-relay --restart unless-stopped -p 443:8443 \
  -v agent-commander-relay:/data --read-only --tmpfs /tmp --cap-drop ALL \
  --security-opt no-new-privileges agent-commander-relay:current
```

## Rehearse both modes locally

The rehearsal starts two disposable Linux containers that stand in for remote servers. One runs systemd and the other runs Docker Engine. It reaches each one only through SSH with a generated key.

```sh
cd multiplayer && go run ./deploy/remote/testhosts
```

For each mode it deploys, runs the connection check, and adds the relay to a real `commander-network` device agent with isolated state. The device agent's probe must pass and its pin must match. The rehearsal then restarts the relay and reconnects with the same pin, redeploys and confirms the pin is unchanged, and removes the relay. It deletes the test containers afterwards. Add `--keep` to leave them running, or `--mode docker` to run one mode.

`--mode tailnet` rehearses the tailnet deploy. It starts a disposable Headscale on a private Docker network, never a real control server, and issues two pre-auth keys. It deploys the relay with the sidecar, confirms that the relay publishes no port and does not answer on the host's own address, and checks it from a second tailnet node: the connection check by MagicDNS name, then the Linux device agent's `tailnet-status`, `tailnet-relays` and `server-probe`. It redeploys without a key and confirms the node address and pin are unchanged. The test hosts need outbound access to Docker Hub and Tailscale's DERP servers. The test hosts need outbound HTTPS to `accounts.google.com`. The device agent stops before sign-in, because that needs a person at a browser.

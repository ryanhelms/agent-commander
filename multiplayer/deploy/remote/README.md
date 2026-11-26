# Deploy a relay to a remote Linux host

`remote.py` installs `commander-relay host` on a Linux server over SSH, then connects to it as Agent Commander would. Host mode is one process with an embedded JetStream broker and a private PostgreSQL child, so the server needs no separate database or broker. Choose one of two forms:

| Mode | What runs on the server | The server needs |
| --- | --- | --- |
| `docker` | One container from the host image, with its state in the `agent-commander-relay` volume | Docker Engine |
| `systemd` | `agent-commander-relay.service`, a sandboxed system service with its state in `/var/lib/agent-commander/relay` | systemd, and apt or dnf to install PostgreSQL when it is missing |

For a multi-edge deployment with replicated brokers, use the [Compose pilot](../README.md) instead.

## Before you deploy

On the Mac that runs the deploy:

- SSH access to the server with a key. The SSH user is root, or has passwordless `sudo`. In Docker mode, membership of the `docker` group is enough.
- Docker Desktop with Buildx for Docker mode, or Go for systemd mode.
- Python 3.10 or newer and OpenSSL.

On the server:

- x86-64 or arm64 Linux.
- Inbound TCP on the relay port, 443 by default. Clients make direct TLS connections, so any load balancer must pass TLS through.
- Outbound HTTPS to the OIDC issuer. The relay reads the issuer's discovery document when it starts.
- A DNS name for the server, or clients that connect by IP address.

You also need an OIDC client for the Agent Commander desktop app and at least one administrator email. See [the pilot guide](../README.md#prepare-the-host) for the Google Desktop client setup.

## Deploy

Run the deploy from the repository root. Each `--hostname` goes into the relay's certificate. The first one forms the URL that clients use.

```sh
python3 -B multiplayer/deploy/remote/remote.py deploy systemd ops@relay.example.org \
  --hostname relay.example.org \
  --issuer https://accounts.google.com \
  --client-id "$COMMANDER_GOOGLE_DESKTOP_CLIENT_ID" \
  --admin you@example.org
```

For a container, replace `systemd` with `docker`. Other options:

- `--allow-email` adds a member. Repeat it for each person. Without it, any account of the OIDC client may join.
- `--port` sets the public port. `--bind` limits the listener to one address.
- `--ssh-port`, `-i KEY` and `-o OPTION` pass through to `ssh`.
- `--public-url` names the URL clients use when a proxy or port mapping changes it.

The deploy prints the relay URL and its server pin, then runs the connection check:

```json
{"mode": "systemd", "url": "https://relay.example.org", "pin": "sha256/…"}
```

Deploying again upgrades the relay in place. It keeps the configuration, database and TLS identity, so the pin stays the same and clients reconnect without trusting it again. The configuration options apply only to the first deploy. To change them later, edit `host.json` on the server and restart the relay.

## Connect from Agent Commander

1. Open the network tray and choose **Add server**.
2. Enter the relay URL.
3. The check shows the steps DNS, TCP, TLS, relay and sign-in. Compare the TLS fingerprint pin with the `pin` from the deploy, then confirm it.
4. Sign in with an administrator or member account.

To check a relay from a terminal, run `connect`. It checks the pin, reads `/v1/info`, and confirms that `/ready` answers a device certificate with HTTP 204 and refuses a client without one.

```sh
python3 -B multiplayer/deploy/remote/remote.py connect https://relay.example.org --pin 'sha256/…'
```

## Operate

```sh
python3 -B multiplayer/deploy/remote/remote.py status systemd ops@relay.example.org
python3 -B multiplayer/deploy/remote/remote.py remove systemd ops@relay.example.org
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

**systemd.** The deploy cross-compiles `commander-relay` for the server's architecture and copies it to `/usr/local/bin`. [`systemd-install.sh`](systemd-install.sh) installs the distribution's PostgreSQL server when none is present, without creating its default cluster. It creates the `agent-commander` system account and the 0700 host directory, then runs `commander-relay host install`. The unit runs as `agent-commander` with `NoNewPrivileges`, `ProtectSystem=strict` and write access only to the host directory. Its one capability is `CAP_NET_BIND_SERVICE`, for port 443. To install by hand on a server with the binary in place, run the same two commands:

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
python3 -B multiplayer/deploy/remote/testhosts/rehearse.py
```

For each mode it deploys, runs the connection check, and adds the relay to a real `commander-network` device agent with isolated state. The device agent's probe must pass and its pin must match. The rehearsal then restarts the relay and reconnects with the same pin, redeploys and confirms the pin is unchanged, and removes the relay. It deletes the test containers afterwards. Add `--keep` to leave them running, or `--mode docker` to run one mode. The test hosts need outbound HTTPS to `accounts.google.com`. The device agent stops before sign-in, because that needs a person at a browser.

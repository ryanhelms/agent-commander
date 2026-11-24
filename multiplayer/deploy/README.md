# Multiplayer relay pilot

One Docker Compose host runs two Go relay processes, PostgreSQL, three private NATS servers running JetStream and a TCP ingress. Each device makes outbound HTTPS connections to one hostname. The edge checks its device certificate even during enrollment. Any edge can renew the same session, deliver work or accept a receipt.

## Prepare the host

Use Docker Engine with Compose v2, Python 3.10 or newer with TLS 1.3 support, OpenSSL with P-256 support and a directory on persistent disk for service keys. Run the setup as a regular service operator with access to Docker. The host needs outbound access to the OIDC provider and the image and Go module registries during setup. Give both Macs network access to the relay hostname and OIDC provider.

Register a native public OIDC client with Authorization Code, PKCE S256, the `openid` scope, and the loopback redirect `http://127.0.0.1:<ephemeral-port>` with path `/`. Allow the two pilot accounts to use this registration. Edges and devices must agree on the issuer URL and trust its certificate. The tray handles the browser callback, binds the identity to a device key and rotates relay credentials.

With an email allowlist, the tray also requests the OIDC email scope. The edge checks the signed verified-email claim during enrollment and applies the list to access and refresh tokens. Omitting the list allows users of the configured OIDC audience to enroll.

Generate the runtime files once for a new deployment. Supply the relay hostname as it appears in the TLS certificate. The certificate file includes its intermediate chain. For a private trial, omitting the certificate and key creates a relay certificate using the generated pilot CA. Give the two devices only the public `ca.pem` trust anchor for that setup.

For the internet pilot, add `--public` and pass the exact verified email of each participant with repeated `--allow-email` flags. Generate that configuration on the relay host so Python verifies the supplied certificate chain against the host's trust store. Before generating any credentials, the tool checks the hostname, certificate chain and key with a local TLS 1.3 handshake.

```sh
cfg="$HOME/commander-pilot-config"
python3 multiplayer/deploy/prepare.py "$cfg" \
  --public \
  --hostname srv01.agentmux.bytedesk.ai \
  --issuer https://accounts.google.com \
  --client-id "$COMMANDER_GOOGLE_DESKTOP_CLIENT_ID" \
  --allow-email first@example.org --allow-email second@example.org \
  --certificate /path/to/relay-fullchain.pem \
  --private-key /path/to/relay-key.pem
```

For a private OIDC issuer, add `--issuer-ca /path/to/issuer-ca.pem` for the edge and set `COMMANDER_NETWORK_OIDC_CA` to the issuer's public CA file in the app's launch environment. Use `COMMANDER_NETWORK_CA` for a private relay's public CA. The system browser also needs to trust the OIDC issuer. Public providers such as Google use system trust by default.

Protect the generated directory and its backups. It contains workload credentials, TLS keys and the database bootstrap passwords. Each NATS server has its own data directory and identity. A separate route CA authenticates the private broker mesh. Each edge has all three client seed addresses. The generated internal leaf certificates last 90 days. For a continuing deployment, provision replacement workload and server certificates and distribute updated trust before expiry. The one-time generated CA signing keys are discarded after provisioning.

Run `python3 -B multiplayer/deploy/prepare_test.py` from the repository root to verify certificate and bind settings with disposable certificates.

## Start the relay

```sh
docker compose --env-file "$cfg/pilot.env" -f multiplayer/deploy/compose.yaml up --build -d
docker compose --env-file "$cfg/pilot.env" -f multiplayer/deploy/compose.yaml ps
```

To use the prebuilt Linux x86-64 pilot image, copy the relay archive to the VM and load it into Docker. Generate the VM's private configuration separately with `prepare.py`. Start both edges from the loaded image with no build step. The other services still use their Compose images.

```sh
docker image load -i commander-relay-pilot-linux-amd64.tar.gz
PILOT_RELAY_IMAGE=commander-relay:pilot-linux-amd64 \
  docker compose --env-file "$cfg/pilot.env" -f multiplayer/deploy/compose.yaml up --no-build -d
```

The default ingress is `127.0.0.1:9443`. The public configuration uses `0.0.0.0:443`, which matches the packaged tray's default relay URL. Compose can override both values through `PILOT_BIND` and `PILOT_PORT`. Point the Cloudflare **DNS only** record at the VM's reserved IPv4 address and allow inbound TCP 443 for the relay. The Go edges perform mutual TLS directly. Any load balancer in front of them must pass TLS through. [Cloudflare proxy settings](https://developers.cloudflare.com/dns/proxy-status/)

On the private Compose network, the ingress gives each upstream TCP connection one second and can try another edge within a two-second window. The client reconnects if an already established TLS connection closes during failover. [NGINX stream proxy settings](https://nginx.org/en/docs/stream/ngx_stream_proxy_module.html#proxy_next_upstream_timeout)

Configure Agent Commander on both Macs with the same relay origin, e.g. `https://relay.example.org:9443`. Use separate OIDC users and open the tray on each Mac. Add each other by handle, accept the request, publish a local resource, select allowed actions, set an expiry and use limit, and grant the other handle access. Presence requires an active device lease. The recipient explicitly enables execution on its device.

The private backbone uses PostgreSQL over verified TLS and SCRAM, and NATS over mutual TLS with per-edge credentials and subject permissions. PostgreSQL holds relationships, grants, encrypted request/result envelopes, the outbox, claims and receipts. JetStream carries child IDs. Addressed wakeups contain a device ID. Both client endpoints keep their private signing and decryption keys.

## Check and operate

Each edge exposes `GET /ready` through device-authenticated TLS. A ready edge returns HTTP 204 after the dispatcher is subscribed and both data services are reachable. A plain browser or unauthenticated curl cannot complete the handshake. Use Compose service logs and the tray's device status to check a running pilot.

```sh
docker compose --env-file "$cfg/pilot.env" -f multiplayer/deploy/compose.yaml logs --tail=30 edge-a edge-b
docker compose --env-file "$cfg/pilot.env" -f multiplayer/deploy/compose.yaml down
```

A normal stop preserves the PostgreSQL named volume and the three JetStream data directories in `$cfg/data-nats-*`. Keep the same generated credentials across restarts. Back up PostgreSQL and protect the configuration directory. The two edges demonstrate independent dispatch and reconnect behavior. The delivery stream and its durable consumer use three replicas. The cluster can elect another leader and continue acknowledged writes after a single broker stops. The three processes share a physical host in this Compose deployment. To survive loss of a host, distribute brokers across failure domains, use a replicated PostgreSQL service, and run redundant ingress. Each broker has a 1 GB file-store limit. Monitor disk usage and PostgreSQL growth over the pilot. PostgreSQL keeps receipt and idempotency records for the life of the pilot. [NATS cluster formation](https://docs.nats.io/learn/clustering/forming-a-cluster)

In the November 23, 2026 single-host failover rehearsal, `nats-b` led the three-replica delivery stream and acknowledged sequence 1. After stopping that container, `nats-c` was elected and acknowledged sequence 2. A device certificate still received HTTP 204 from the TLS passthrough ingress with the original leader offline.

## Repeat the two-edge network test

From `multiplayer/`, point the test at a disposable PostgreSQL database for which the test user can create schemas. With Docker available, the fixture creates a separate authenticated loopback-only JetStream container and two distinct relay executables. Each test allocates its own schema and removes it on completion.

```sh
PILOT_TEST_DATABASE_URL='postgres://pilot:password@127.0.0.1:5432/pilot' \
PILOT_TEST_DOCKER=1 go test -race -count=1 -v ./cmd/commander-relay
```

In place of Docker, supply `PILOT_TEST_NATS_URL` for a dedicated, authenticated loopback JetStream broker. Each independently running test requires its own broker or account. The network fixture simulates browser account selection at a local OIDC issuer and uses real authorization-code exchange, certificate-bound sessions, encryption, PostgreSQL and JetStream.

On macOS, use the same disposable database and broker to exercise a sign-in followed by a process restart. The test checks recovery and rotation of the Keychain-backed session, friendship and resource grant.

```sh
PILOT_TEST_DATABASE_URL='postgres://pilot:password@127.0.0.1:5432/pilot' \
PILOT_TEST_MACOS_KEYCHAIN=1 PILOT_TEST_DOCKER=1 \
  go test -race -count=1 -v ./internal/device -run '^TestMacOSKeychainSessionRestart$'
```

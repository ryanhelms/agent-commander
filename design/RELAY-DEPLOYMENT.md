# Commander relay deployment

Commander opens an outbound TLS connection to the relay. The relay multiplexes ordinary HTTP/2 requests inside this connection. Both relay and direct HTTPS traffic enter Commander's hosted OAuth gateway, sharing worker scopes, input ownership and operation receipts. The relay can process payloads in memory. It has no delivery queue.

## Deploy a self-hosted relay

Build the Linux release from the repository root. Place the Agent ACP SDK and transport releases required by `go.mod` next to each other under `dist/sdk/`. The current SDK is 0.1.14 and the transport is 0.1.0. An optional SDK directory argument and the `AGENT_ACP_TRANSPORT_RELEASE` environment variable select alternate copies of those pinned releases.

```sh
python3 packaging/relay-release.py
python3 packaging/relay-release.py --verify
```

The build stages both relay archives in `dist/relay/` and matching standalone executables in `dist/agentctl-linux-amd64` and `dist/agentctl-linux-arm64`. Verification checks the SHA-256 manifest, executable mode and archive members, Linux architecture, and the exact SDK and transport versions and checksums recorded by Go. For a second independent build, pass `--output` with an empty directory and compare its `SHA256SUMS` to the first build.

Copy the archive for the server's architecture and the release's trusted checksum manifest to the Linux server. When checking only one archive, select its entry from the two-architecture manifest.

```sh
archive=agent-commander-relay-linux-amd64.tar.gz
awk -v file="$archive" '$2 == file' SHA256SUMS | sha256sum -c - && tar -xzf "$archive"
```

The archive includes the executable, deployment instructions, Prometheus alert rules and rule tests.

Run `agentctl relay /etc/agent-commander/relay.json` under a dedicated, unprivileged service account. Map each public instance name to the app listener with DNS and a trusted TLS certificate for that name. Use a DNS name and trusted certificate for the tunnel listener. Keep the three listeners distinct. The example uses TCP port 443 for the app listener, TCP port 8443 for host connectors, and a loopback metrics endpoint. To run without binding a privileged port, route TCP 443 to an unprivileged app listener port with the original TLS connection intact.

```json
{
  "listen": ":443",
  "certificate": "/etc/agent-commander/public.pem",
  "private_key": "/etc/agent-commander/public-key.pem",
  "tunnel_listen": ":8443",
  "tunnel_certificate": "/etc/agent-commander/tunnel.pem",
  "tunnel_private_key": "/etc/agent-commander/tunnel-key.pem",
  "metrics_listen": "127.0.0.1:9109",
  "instances": [
    {
      "host": "alice.relay.example.net",
      "certificate_sha256": "REPLACE_WITH_64_HEX_DIGITS"
    }
  ]
}
```

For each instance, the developer creates a separate connector key and certificate. The operator receives the certificate fingerprint over the enrollment channel. Keep the private key on the Commander host. The relay authenticates proof of possession and checks the certificate validity dates and the SHA-256 fingerprint of the DER leaf certificate. A pin belongs to exactly one DNS name. App requests must use that instance's name in TLS and HTTP.

```sh
umask 077
openssl req -x509 -newkey rsa:2048 -nodes -days 90 \
  -subj '/CN=alice.relay.example.net' -keyout connector-key.pem -out connector.pem
openssl x509 -in connector.pem -outform DER | shasum -a 256
```

Add the connector to the developer's `AGENT_COMMANDER_HOSTED_CONFIG` JSON. Retain the OAuth introspection and grant configuration. An optional connector `ca` path sets the trust roots for its tunnel server. The direct HTTPS listener settings may be omitted for a relay-only host. Restart Commander after changing listener or certificate settings.

```json
{
  "relay": {
    "address": "connect.relay.example.net:8443",
    "certificate": "/absolute/path/to/connector.pem",
    "private_key": "/absolute/path/to/connector-key.pem"
  }
}
```

In the hosted CopilotKit backend, set the connector's `baseURL` to the instance origin, such as `https://alice.relay.example.net`. Supply the same audience-bound OAuth token as for direct HTTPS. The relay preserves the bearer for Commander's introspection and grant checks. Take the selected worker's input lease in Commander before submitting the first prompt. [OAuth and hosted grant configuration](../README.md#direct-https-for-hosted-apps)

### Connecting a Keycloak realm

Register a confidential client for the Commander API and a separate confidential client for each embedding backend. Configure the backend's authorization code flow, S256 PKCE and callback URL. Give its access tokens the Commander API audience and the worker scopes its user can request. Keycloak's Subject and Audience mappers must include their claims in the introspection response. Give the Commander service its own introspection client ID and secret. Use the realm's discovery document for `issuer` and `introspection_endpoint`, and use the Commander API audience for `audience`. [Keycloak endpoints](https://www.keycloak.org/securing-apps/oidc-layers) · [Keycloak protocol mappers](https://www.keycloak.org/admin-api/protocol-mappers)

In `hosted-grants.json`, use the developer's returned `sub`, the embedding backend's `client_id`, and the approved workers and scopes. Commander form-encodes its OAuth client ID and secret before applying HTTP Basic authentication to the introspection request. Configure the original credential strings from the issuer. [OAuth client password authentication](https://www.rfc-editor.org/rfc/rfc6749.html#section-2.3.1)

### Checking a hosted backend

The release archive includes a Node client for a disposable two-worker run. On the backend, install the matching `@agent-commander/copilotkit` package in the directory containing the client or an ancestor. Start one Claude worker and one Codex worker under a coordinator that keeps the run open. Once the workers are ready, take their input leases and grant both test apps `commander:observe`, `commander:prompt`, `commander:reply` and `commander:history` on each worker. Provide their access tokens in a private JSON file under the keys `direct` and `relay`. Supply the direct and relay origins followed by the worker IDs.

```sh
COMMANDER_APP_TOKENS=/run/secrets/commander-test-apps.json \
  node design/verification/copilotkit-live/hosted-client.mjs \
  "$DIRECT_ORIGIN" "$RELAY_ORIGIN" "$CLAUDE_WORKER" "$CODEX_WORKER"
```

## Recover from a disconnect

- HTTP 503 means the relay had no connected instance and skipped forwarding the request. Retry after Commander reconnects. HTTP 429 means the instance's forwarding slots were all in use.
- HTTP 502 or an interrupted stream can mean Commander accepted the operation. Use `GET /v1/ag-ui/workers/WORKER_ID/operations?runId=RUN_ID` to recover the operation ID. Reopen the stream by operation ID and run ID. If the receipt is absent, retry the original run with the same run ID, input generation and prompt. Reusing the command identity keeps a late acceptance and a retry from enqueuing two prompts.
- Reply retries use the same request ID and answer. The worker's recorded answer wins if a competing reply already resolved the request.
- Connector reconnect attempts back off with jitter. The relay uses HTTP/2 heartbeat timeouts to detect connections that stop responding. Restarting the relay interrupts existing streams. Commander keeps accepted receipts.

## Operate the managed edition

Before restarting or replacing the enrollment file, run the candidate binary as the relay user against the candidate configuration.

```sh
agentctl relay --check /etc/agent-commander/relay.next.json
```

A zero exit status confirms that the listener addresses resolve, the metrics address is loopback, both TLS key pairs load, the enrollment table is valid and HTTP/2 debug logging is disabled. The command opens no listeners. Verify socket binding, public certificate trust and hostname routing with the staging smoke test. Enrollment reload separately checks that the live listener and TLS settings match.

Keep the invite-only instance list in the operator-managed relay configuration. Verify the developer's identity and connector certificate fingerprint during enrollment. To enroll, revoke, or rotate a connector, atomically replace the configuration file, then send SIGHUP to the relay process. The relay validates the full list before applying it and logs the number of enrolled instances. An invalid update leaves the live inventory in effect. Use an explicit empty `instances` array to revoke every connector. [Go signal handling](https://pkg.go.dev/os/signal#Notify)

Unchanged host and pin pairs retain their connections and in-flight streams during reload. Removing an instance closes its tunnel and makes its hostname unavailable for routing. Rotating a pin closes the former tunnel. App requests receive HTTP 503 while the newly pinned connector is offline. Recover interrupted operations using their original IDs. Listener and server TLS changes require a restart. Revoke an application's access separately in Commander's grant file or authorization server.

Scrape `GET /metrics` on the loopback listener. It exposes aggregate connected hosts, forwarded requests, unavailable requests, saturated requests, interrupted forwarding and response bytes. The binary allows up to 128 invited instances, 32 simultaneous connector handshakes, 16 requests per connected instance, and 1 MiB per request upload. Stream forwarding uses HTTP/2 flow control and a bounded copy buffer. An app write or flush that hits its eight-second deadline ends that stream and releases its slot. A quiet upstream can send its next frame when ready. Treat these as implementation bounds and validate actual throughput on the deployment hardware before admitting the cohort.

For Prometheus on the relay host, add the scrape job and load the supplied rules. Set the absolute rule path to the extracted archive location. The rules alert on a failed scrape, repeated attempts to reach an offline host, repeated saturation, and interrupted forwarding. Validate the sample thresholds against the invite cohort's traffic and route alerts to the assigned incident receiver. [Prometheus alerting rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)

```yaml
rule_files:
  - /opt/agent-commander/packaging/relay/alerts.yml
scrape_configs:
  - job_name: commander-relay
    static_configs:
      - targets: ["127.0.0.1:9109"]
```

Run `promtool test rules packaging/relay/alerts.test.yml` from the extracted archive directory. The fixture checks firing, recovery, and isolation from other scrape jobs. [Prometheus rule unit tests](https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/)

Configure the service supervisor, proxies, traces and error reporters to exclude payloads, bearer headers and request URLs from persistent logs. Record aggregate operational metrics and deployment events. Check synthetic prompt, reply, tool-result and attachment markers against every logging destination before opening access.

Start Commander and the relay with Go HTTP/2 debug logging disabled. Hosted startup rejects `GODEBUG=http2debug=1` and `GODEBUG=http2debug=2` because they can expose traffic through Go's global logger. After correcting the service environment, restart the process. [Go HTTP/2 diagnostics](https://pkg.go.dev/net/http#hdr-HTTP_2)

Use the same tested build for both editions. Save the previous binary and configuration for rollback, validate the candidate in staging, then restart and verify connector authentication, worker routes, receipt recovery and metrics. Rolling back a pin configuration can restore access for a revoked connector. Preserve revocations during rollback.

Assign the operator and incident contact before opening enrollment. Exercise alert delivery, capacity limits, cross-instance isolation, and hostname or certificate failures in staging. The managed launch requires a deployed service, published support contact and a verified invite workflow.

### Google Cloud production target

A read-only lookup of the previously discussed `fabric-prod` project was denied. The current rollout keeps Commander local. This section preserves the infrastructure design for a future managed service.

The relay's host connection table lives in its process. App HTTPS and the authenticated outbound connector therefore need to reach the same active relay instance for an enrolled host. For the initial cohort, use one active backend for the two listener endpoints, or assign each cohort to a distinct relay origin backed by one active instance. A Google Cloud regional external passthrough Network Load Balancer can preserve the ports and TLS connections for the relay process to terminate. Multiple active replicas behind an undifferentiated forwarding rule would need shared connection routing before they could serve the same cohort. [Google Cloud passthrough load balancing](https://docs.cloud.google.com/load-balancing/docs/network/networklb-backend-service)

## Local verification

`go test -race ./internal/service -run TestHostedWorkerAccess` runs the direct HTTPS and relay workflows against the same Commander service and a simulated OAuth issuer. The relay case drops the tunnel before response headers and during streaming, recovers the original receipt, checks instance isolation and verifies the scoped tool result survives the stream. It exercises the per-instance concurrency limit and checks aggregate telemetry for synthetic payload markers and operation identities.

The privacy fixture sent distinct prompt, approval reply, tool result, and attachment markers. It also sent distinct markers through malformed, saturated, and disconnected requests. The race-tested fixture's captured process output and the relay's metrics contained none of the markers or the encoded attachment record. A separate CLI smoke test verified that both built commands reject HTTP/2 frame logging at startup. With frame logging disabled, the CLI verified the outbound tunnel, OAuth rejection, authenticated dispatch, and disconnect. Logging destinations configured by a managed operator still require staging verification. [Hosted privacy fixture](../internal/service/hosted_test.go) · [Startup regression](../cmd/agentctl/integration_test.go)

A local CLI smoke run started both `agentctl relay` and a relay-only `agentctl serve` with disposable loopback endpoints. It verified the initial unavailable response, Unix socket health, outbound connection, OAuth rejection and authorized dispatch, and the host count returning to zero after Commander exited. The Linux amd64 executable was cross-built from the SDK release archive and inspected as a static ELF. Its Go build metadata confirmed the `v0.1.4` SDK pin. Managed staging and production operation remain release gates.

The Linux arm64 build ran under UID 65532 in a read-only Docker Desktop container with a separate pinned connector certificate and loopback-only app and tunnel ports. An independently installed CopilotKit connector exercised real Claude and Codex over the direct listener and the Linux relay. After a container restart, Commander reconnected and the relay authenticated and forwarded a worker request again. The service logs and relay logs contained neither synthetic payload markers nor fixture OAuth bearer tokens. This test used a disposable OAuth introspection service and the local VM. [Hosted test evidence](verification/copilotkit-live/README.md#direct-https-and-outbound-relay)

A separate Linux backend running Node 24.22.2 and the installed 0.1.2 connector exercised both routes with Keycloak 26.6.4. Two confidential apps completed authorization code exchange with S256 PKCE for one test developer. Commander introspected their tokens over HTTPS. Each app sent a prompt to real Claude and Codex workers, answered the worker through the other route, and recovered the original receipt, final answer, tool result and turn-scoped source. All four final answers spanned multiple ACP text chunks. After the developer removed one app's worker grants, that app received HTTP 403 for both the worker summary and live history on both transports. The second app continued to receive HTTP 200 for the same workers. The packaged relay reconnected after a restart. Captured Commander and relay logs contained no test payload markers or bearer tokens. This deployment used one machine and disposable realm settings. [Portable backend proof](verification/copilotkit-live/hosted-client.mjs)

Both local release archives passed SHA-256 verification. The unpacked amd64 and arm64 binaries at SDK 0.1.13 were static ELF executables with the independently verified SDK and transport checksums in their build metadata. Both printed the relay command under non-root users in network-disabled Linux containers. Two builds in separate output directories returned the same archive hashes.

Prometheus 3.3.0 passed the bundled rule fixtures. In a network-disabled Linux arm64 container, Prometheus also scraped the real relay while a synthetic HTTPS client received 68 host-unavailable responses. It posted the warning to a loopback receiver implementing the Alertmanager v2 API. The notification omitted the fixture bearer and worker identifier. Managed incident routing remains a staging gate.

The packaged Linux arm64 relay ran under an unprivileged user in a network-disabled container. It applied connector enrollment, rotation, and revocation through SIGHUP while an unchanged tenant's original stream completed. It rejected a duplicate pin and a listener edit, rejected reconnects with the retired certificate, and dropped the connected-host count to zero after the last revocation. A binary rollback rehearsal upgraded the previous relay, rotated a tenant's certificate, revoked the tenant, then restarted the previous executable with the latest enrollment file. The file retained its SHA-256 digest. The restored executable rejected both of the tenant's certificates and returned HTTP 421 for its hostname. Two enrolled hosts reconnected, served HTTP 200 responses, and appeared in the connected-host count. The Go regression also checks that a readiness probe started before a change cannot register a displaced tunnel afterward. [Enrollment regression](../internal/relay/relay_test.go)

A loopback HTTP/2 test stopped reading an app response. The relay closed the blocked stream, freed its slot and counted one interruption. The same host's quiet stream resumed after more than eight seconds, and a second host continued to serve requests. The stalled fixture bounded how much response data could travel through the two TLS legs before flow control took effect. [Stream regression](../internal/relay/relay_test.go)

### Local capacity measurement

```sh
python3 packaging/go-with-sdk.py test \
  -run '^$' -bench '^BenchmarkRelayCapacity$' -benchtime=3x -count=1 ./internal/relay
```

The benchmark holds every transfer at its upstream handler before releasing the wave. It uses distinct pinned certificates, sends a 1 KiB request, reads a 64 KiB reply, checks the issuing host, and exercises HTTP/2 over both TLS legs. The preflight rejects a seventeenth request to one host with HTTP 429 while the existing transfers complete. Cases with 1, 16, and 128 hosts passed under Go's race detector.

At 128 hosts, each wave carried 2,048 responses. Five waves on the Apple M5 averaged about 9,158 responses per second and 600 MB/s. Five waves in a local Linux arm64 VM container with two CPUs and a 768 MiB limit averaged about 9,204 responses per second and 603 MB/s. Peak RSS was about 432 MiB on macOS and 403 MiB in the container, including the relay, connectors, and clients running in the same process. These loopback measurements used synthetic payloads. Staging still needs measurements with its DNS, OAuth gateway, and deployed hardware. [Benchmark](../internal/relay/capacity_test.go)

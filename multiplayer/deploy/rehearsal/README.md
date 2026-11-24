# Local Docker remote-user rehearsal

Alice, Bob and Carol run as three unprivileged Linux containers. Each has its own internal Docker network, device keys, coordinator socket, Git checkout and OIDC identity. All three resolve `srv01.agentmux.bytedesk.ai` to their own interface on the same TCP ingress. The two Go relays, PostgreSQL and three JetStream brokers use the production Compose definition. Docker publishes zero ports on the host.

## Run the test

Use the local Docker Engine Unix socket, Docker Compose v2.24.4 or newer, Python 3.9+, OpenSSL and the Go version declared in the modules. The root Agent Commander module's local SDK replacements must resolve, exactly as for a normal `agentctl` build. The launcher compiles Linux executables from the checkout and reuses content-addressed Docker images. Initial setup pulls any missing base images and Go dependencies.

From the repository root, run the self-contained acceptance suite. It creates a fresh private run directory, verifies the network and broker failover, exercises the collaboration workflow, then removes the project's containers, networks, persistent volumes and private material. Image and Go build caches survive for subsequent runs.

```sh
python3 -B multiplayer/deploy/rehearsal/acceptance.py
```

For interactive inspection, choose a fresh path outside the checkout. Each live project has independent credentials and volumes.

```sh
run="$(mktemp -d)/run"
lab=multiplayer/deploy/rehearsal/lab.py
python3 -B "$lab" up "$run"
python3 -B "$lab" verify "$run"
python3 -B multiplayer/deploy/rehearsal/acceptance.py "$run"
python3 -B "$lab" compose "$run" exec -T peer-b pilot-peer facts
python3 -B "$lab" down "$run"
```

The workflow assertions expect a fresh project. `lab.py topology` can run at any time when all participants are online. It checks Docker's published ports and network attachments, then makes real connections from each participant’s network namespace. Its listeners verify isolation between live peer endpoints. It checks address resolution, rejection of an unauthenticated TLS client and a successful TLS 1.3 request made with a test device key. `lab.py quorum` stops the current stream leader, confirms that a surviving replica acknowledges a later sequence and checks that all three replicas catch up after restart. `lab.py edge` stops one Go relay, exercises all three network paths through the surviving relay, and verifies the returning relay directly over mTLS. `lab.py verify` runs all three checks.

## What crosses the network

The OIDC fixture validates authorization codes, PKCE, nonces and loopback redirects. Each simulated browser presents a different secret. The issuer signs the ID token for that account, and the real relay enforces its verified-email allowlist.

Inside these networks, `github.com` and `api.github.com` resolve to the local fixture. A private CA, trusted only by these test clients, secures both HTTPS connections. The owner’s device uses its production issue and Git adapters. Issue state is emulated. Git pushes use the actual Git smart-HTTP backend in a separate container, which checks the owner credential before updating the bare repository. Multiple recipients can work on one owner's repository through separate relay grants. The owner alone mounts its working checkout and uses its fixture Git credential.

The participants use the actual device daemon, its coordinator API and the `agentctl mcp` executable. A deterministic Commander Unix-socket fixture supplies the local coordinator run and agent response. This rehearsal exercises Linux networking and authorization. macOS tray rendering, a real browser UI, hosted identity-provider settings and live provider credentials have separate acceptance checks.

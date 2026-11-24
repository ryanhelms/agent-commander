# Agent ACP SDK release candidate 0.1.14

The Go, TypeScript and Python packages share the `agentacp.v1` Protobuf contract. The Go package includes the shared adapter conformance runner, opt-in ACP source capture and inactive-session replay, and a typed preview for MCP results carried in an ACP tool's raw output. The SDK carries ordered text, image and audio prompt parts with ACP capability checks. The native history readers preserve original Claude messages and Codex items. The SDK preserves session-scoped permission requests, prompt outcomes and complete parameters for enriched session updates. Version 0.1.14 checks advertised resume through a fresh runtime. Passive Codex history includes a final session-scoped thread record, including for an empty thread. Its transport diagnostics emit the diagnostic category. A malformed pre-handshake frame stays out of worker output. The candidate is staged locally. Its publishing namespace and destination remain open.

| Package | Candidate | Supported integration |
| --- | --- | --- |
| Go | `agent-acp.local/sdks/go@v0.1.14` in a Go module proxy directory | The generated session client, live ACP runtime and passive history hooks. |
| TypeScript | `agent-acp-0.1.14.tgz` | The generated session client and runtime interface with Protobuf model types. |
| Python | `agent_acp-0.1.14-py3-none-any.whl` | The generated asyncio session client and runtime protocol with Protobuf model types and type declarations. |

The SDK build uses Go 1.23+ for its module, Node.js 22+ for the workspace, and Python 3.10+ for the Python package. Commander continues to require Go 1.25+ and its existing macOS prerequisites. The packaged contract was verified with Go 1.27.4, Node 26.13.1 and Python 3.14. The TypeScript and Python tests inject a runtime through the public interface.

## Independent Go transport

The Go SDK requires `agent-acp.local/transport@v0.1.0`. Another Go application can install that module on its own. Its Apache-2.0 distribution includes its upstream provenance, public API and regression suite. The module was installed from the local proxy and passed tests with Go 1.21.13. The Go SDK, TypeScript client and Python client expose the selected frame as `Observation.wireProvenance`. The wire ID is an optional JSON token stored as text, so a numeric ID above JavaScript’s safe integer range, a string ID and an absent ID stay distinct. Unknown peer error properties stay in the original error payload. [Transport manifest](../../../dist/sdk/agent-acp-transport-0.1.0/manifest.json) · [Shared SDK contract](../../../dist/sdk/agent-acp-0.1.14/conformance/session.json)

Commander verifies the hashes of both the SDK and the transport against `go.sum`. Place their release directories next to each other, or set `AGENT_ACP_TRANSPORT_RELEASE` to the transport release directory. Consumers of the standalone module can point `GOPROXY` at its `go/` directory and pin it independently.

## Build and verify

### Portable local bundle

The local consumer archive contains both versioned release directories and the independent verifier with its shared contract tests. Its SHA-256 is `903858d11690e6c3e1ede0cbc7be3e5950797308ea3bbdbd8bbabed34f018009`. An independent rebuild reproduced the archive byte for byte. The extracted bundle passed the Go contract, embedded and executable adapter checks, TypeScript type check and Node contract, and Python contract with network resolution disabled and public dependencies supplied from caches. [Consumer archive](../../../dist/releases/agent-acp-0.1.14-consumer.tar.gz)

```sh
python3 -B design/verification/sdk-release/bundle.py \
  dist/sdk/agent-acp-0.1.14 dist/releases/agent-acp-0.1.14-consumer.tar.gz
```

After verifying the archive digest and extracting it into a clean directory, run `python3 -B verification/verify.py --consumer-only agent-acp-0.1.14` from that directory. The bundled README lists the offline dependency inputs. Packaging rejects an altered release artifact and keeps an existing archive if its contents differ.

To verify an existing local release as an independent consumer, copy `verify.py` and its sibling `consumer/` directory together. Place the immutable SDK and transport releases next to each other. Run the verifier from any directory with Go, Node.js, npm and Python installed.

```sh
python3 /path/to/verify.py --consumer-only /path/to/releases/agent-acp-0.1.14
```

This check creates a fresh Go module cache, npm project and Python virtual environment. It installs the private Go modules from their individual release proxies, runs the compiled Go and executable ACP adapter scenarios, builds the adapter checker, type-checks the installed TypeScript declarations, and exercises the JavaScript and Python clients against the shipped session fixture. Obtain both manifests from a trusted local distribution. The verifier checks the release files against those manifests and uses the SDK archive's `go.sum` to verify its dependencies.

Offline hosts also need local copies of public dependencies. Configure a populated Go download cache, writable npm cache (including TypeScript 5.9.3), and a Python wheelhouse appropriate to the host. Turn off network resolution with `GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local npm_config_offline=true PIP_NO_INDEX=1 PIP_FIND_LINKS=/path/to/wheels`.

An offline macOS consumer independently verified SDKs 0.1.13 and 0.1.14 with transport 0.1.0 from a disposable directory containing the verifier, release artifacts and cached public dependencies. It passed the installed Go contract, compiled-in and executable adapter scenarios, checker build, TypeScript type check, two Node tests and two Python tests. With SDK 0.1.13, a separately altered transport with a matching altered manifest failed against the SDK archive's original Go checksum. [Binding tests and typed consumer](consumer/)

To install the verified packages into a project with a Go module, set `releases` to the absolute release directory and `public_proxy` to a local Go proxy containing the public dependencies. These commands add the SDK to `go.mod`, put the checker in the project's `bin/`, install the TypeScript binding in `node_modules/`, and install the Python binding in a virtual environment. Use the offline npm cache and wheelhouse settings above on an offline host.

```sh
releases=/absolute/path/to/releases
public_proxy=file:///absolute/path/to/go-cache/cache/download
sdk="$releases/agent-acp-0.1.14"
transport="$releases/agent-acp-transport-0.1.0"
(
  export GOWORK=off GONOPROXY=none GOSUMDB=off GOTOOLCHAIN=local
  export GOPROXY="file://$sdk/go,file://$transport/go,$public_proxy,off"
  go get agent-acp.local/sdks/go@v0.1.14
  GOBIN="$PWD/bin" go install agent-acp.local/sdks/go/cmd/adapter-conformance@v0.1.14
)
npm install --ignore-scripts "$sdk/npm/agent-acp-0.1.14.tgz"
python3 -m venv .venv
.venv/bin/python -m pip install "$sdk/python/agent_acp-0.1.14-py3-none-any.whl"
```

To **build a new SDK release**, set `SDK_CHECKOUT` to the publisher's release checkout. The builder reads tracked SDK sources, generates a module proxy, tarball and wheel, and writes the shared fixture and SHA-256 manifest.

```sh
python3 -m venv /tmp/agent-acp-release-tools
/tmp/agent-acp-release-tools/bin/python -m pip install setuptools==80.9.0 wheel==0.45.1
/tmp/agent-acp-release-tools/bin/python "$SDK_CHECKOUT/tools/release.py" 0.1.14 dist/sdk/agent-acp-0.1.14
python3 design/verification/sdk-release/verify.py dist/sdk/agent-acp-0.1.14
```

Running the verifier from Commander without `--consumer-only` also checks both Go modules against Commander’s independent `go.sum` pins and proves that the build rejects altered archives. The binding tests ship with this verifier. Developers can pass `--sdk-checkout` to exercise a different checkout's binding test sources explicitly. The manifest's source snapshot hash distinguishes working copies at the same Git revision.

The 0.1.14 SDK release worktree was built on the locally verified 0.1.13 sources. Its release manifest records the new source hash and the digests of all three packages. [Local manifest](../../../dist/sdk/agent-acp-0.1.14/manifest.json)

## Adapter conformance

An embedded Go adapter calls `conformance.Check` with its runtime, disposable workspace and deterministic scenario. If the adapter advertises resume, call `conformance.CheckWithRestart` and supply a callback that closes the original runtime and opens a fresh one against the same durable provider state. The suite resumes the selected session and checks a new turn through the fresh runtime. An external ACP executable uses the same checker through `adapter-conformance`. The release ships the [scenario instructions](../../../dist/sdk/agent-acp-0.1.14/conformance/README.md) with its shared language fixture.

```sh
python3 packaging/go-with-sdk.py dist/sdk/agent-acp-0.1.14 build \
  -o /tmp/adapter-conformance agent-acp.local/sdks/go/cmd/adapter-conformance
/tmp/adapter-conformance -cwd /absolute/path/to/fixture -fixture /absolute/path/to/scenario.json \
  -- /absolute/path/to/adapter
```

The checker opens two sessions, preserves their literal prompts, validates command receipts, reconnects each observer by cursor, rejects a crossed permission reply, and confirms the accepted reply and tool result. It rejects a stale interrupt and requires the active turn to report cancellation. It checks advertised passive history and unavailable history against the fixture's declared capability. For advertised session listing, the checker retrieves one session per page and requires both fixture identities. For each advertised image or audio capability, it sends a PNG or WAV and checks the digest returned by the fixture backend against the original bytes. It verifies rejection for unavailable capabilities. The Go fixture exercises a paged retained source. The ACP subprocess fixture carries a missing-resource extension and exercises unavailable history.

## Build Commander against the pin

```sh
make CONFIG=release cli
make CONFIG=release app
CONFIG=release sh poc/agui-console/build.sh
go version -m dist/agentctl
go version -m dist/agentctl
```

The release build reads Commander’s module requirements and downloads both private archives into a fresh module cache. Go checks each module ZIP and go.mod against the recorded checksums. The temporary module file drops both development replacements. With `CONFIG=release`, the CLI, app and reference console find the pinned SDK under `dist/sdk` automatically. Debug builds use the sibling checkouts unless `SDK_RELEASE` names an override. The runtime still requires the selected ACP adapter to be installed.

To run the release build's service tests with local sockets and tmux enabled:

```sh
AGENT_COMMANDER_TEST_INTEGRATION=1 AGENT_COMMANDER_TEST_TMUX=1 \
  python3 packaging/go-with-sdk.py dist/sdk/agent-acp-0.1.14 test -race -p 1 -count=1 ./...
```

## Installed harness compatibility

Build the probe from the Commander checkout. Set `PI_TRANSLATOR` to the built independent Pi translator checkout used in the Pi verification. The Claude and Codex adapter executables default to the sibling SDK checkout’s `harnesses/local/node_modules/.bin`. Pass `--harnesses` to select another installation. The stock Antigravity CLI must be on `PATH`. [Pi setup](../pi-translation.md)

```sh
sdk_version=$(go list -m -f '{{.Version}}' agent-acp.local/sdks/go)
python3 packaging/go-with-sdk.py "dist/sdk/agent-acp-${sdk_version#v}" build -trimpath \
  -o /tmp/commander-check-list ./design/verification/sdk-release/listcheck
python3 packaging/go-with-sdk.py "dist/sdk/agent-acp-${sdk_version#v}" build -trimpath -buildvcs=false \
  -o /tmp/commander-release-cli ./cmd/agentctl
node design/verification/sdk-release/compatibility.mjs \
  --pi-translator "$PI_TRANSLATOR" --list-probe /tmp/commander-check-list \
  --commander-cli /tmp/commander-release-cli
```

The stock ACP client records each real peer’s negotiated protocol version and advertised capabilities. For every peer advertising listing, a separate process uses Commander's pinned SDK and exhausts the listing for a new empty working directory. The probe verifies the executable’s embedded SDK version and module checksum against `go.mod` and `go.sum`. For SDK releases that use the independent transport, the matrix records and verifies its embedded version and checksum as well. When supplied a release `agentctl`, the matrix verifies its embedded SDK and transport checksums against the list probe and records the executable's SHA-256. Its JSON contains versions, capability flags, test outcomes and links to separate workflow evidence. Session identities, titles, paths and content stay private. [Recorded compatibility matrix](compatibility.json)

## Candidate evidence

### SDK 0.1.14 consumer and installed harnesses

The source-free consumer installed SDK 0.1.14 with transport 0.1.0 and passed the shared Go, Node and Python session fixture, the TypeScript compile check, and both Go adapter scenarios. The release checker exercises a new turn on the resumed binding after closing the original runtime. [SDK manifest](../../../dist/sdk/agent-acp-0.1.14/manifest.json) · [Adapter scenarios](../../../dist/sdk/agent-acp-0.1.14/conformance/README.md)

The four installed harnesses completed ACP v1 initialization and returned an empty session list for a fresh working directory. The CLIs were Claude 2.1.331, Codex 0.171.0, Antigravity 1.5.13 and Pi 1.1.0. The matrix verified SDK and transport checksums in both the list probe and the release `agentctl` and recorded its binary digest. This run sent zero prompts. [Recorded capabilities and executable identity](compatibility.json)

### Linux self-hosted releases with SDK 0.1.14

The revised Commander backend retains an on-demand source reference for Pi media rows. Two independent builds with separate Go build caches reproduced both relay archives byte for byte. Their executable members matched the static Linux binaries installed at the time. All 13 embedded Go module checksums matched Commander's `go.sum`, including SDK 0.1.14 and transport 0.1.0. The release verifier also rejected the prior SDK 0.1.13 archives against the current pin. [Archived checksums](../../../dist/releases/relay-sdk-0.1.14-a968ae56/relay/SHA256SUMS) · [Build and verify the release](../../RELAY-DEPLOYMENT.md#deploy-a-self-hosted-relay)

| Linux architecture | Relay archive SHA-256 | Standalone agentctl SHA-256 |
| --- | --- | --- |
| amd64 | `a968ae56a493156ed95c559173173142c30fd3e91ad4f3ee98fc8950836400ea` | `4110efdf68b5a230685aa72e6e2ec74bb802b526dac3b9d7756db7e66c235510` |
| arm64 | `6262eac30520c082c7f8587c446c9961fd049fee87aac6389e22c01feda1df2d` | `951d64f823442a2baea0c333b10b3df9f9a4327aaa27e78cb9990e1744cb3c74` |

On each architecture, a network-isolated Linux container upgraded the sealed 0.1.13 executable directly to this revised 0.1.14 build. The candidate applied enrollment, certificate rotation and revocation through SIGHUP while another tenant's active stream finished. After rolling back the executable with the latest enrollment file intact, both revoked certificates failed to connect, the revoked host returned HTTP 421, and both retained hosts returned HTTP 200. The prior release remains available for comparison. [amd64 rehearsal](../../../dist/releases/relay-sdk-0.1.14-a968ae56/verification/rollback-amd64.log) · [arm64 rehearsal](../../../dist/releases/relay-sdk-0.1.14-a968ae56/verification/rollback-arm64.log) · [Preserved rollback archives](../../../dist/releases/relay-sdk-0.1.13-7d965c96/relay/SHA256SUMS)

The earlier Commander build on the same SDK pin has its own immutable archive and independent rehearsal results. [Intermediate release checksums](../../../dist/releases/relay-sdk-0.1.14-a7a46903/relay/SHA256SUMS) · [Intermediate release verification](../../../dist/releases/relay-sdk-0.1.14-a7a46903/verification/installed.log)

The preflight candidate uses the same SDK and transport pins. Both archives passed the release verifier and all 13 embedded Go module checksums matched `go.sum`. The extracted executables ran as UID 65532 in read-only Linux containers with networking disabled. Each accepted a valid configuration and rejected a malformed certificate pin, invalid TLS key pair, duplicate listener address, non-loopback metrics listener and enabled HTTP/2 debug logging. The CLI regression also confirmed that preflight succeeds while the configured port is occupied. [Preflight checksums](../../../dist/releases/relay-sdk-0.1.14-preflight/SHA256SUMS) · [Linux preflight results](../../../dist/releases/relay-sdk-0.1.14-preflight/preflight-linux.log)

Both architectures then upgraded from the preceding 0.1.14 executable to the preflight build. The candidate applied enrollment changes while a retained tenant's stream finished. Rolling back the executable preserved the latest enrollment file byte for byte. Both revoked certificate pins stayed rejected, the revoked hostname returned HTTP 421, and the two retained connectors returned HTTP 200. The amd64 child ran under Docker Desktop's Linux translation. [amd64 rollback](../../../dist/releases/relay-sdk-0.1.14-preflight/rollback-amd64.log) · [arm64 rollback](../../../dist/releases/relay-sdk-0.1.14-preflight/rollback-arm64.log)

An isolated rebuild of the preflight source snapshot reproduced both tested archives and their checksum manifest byte for byte. The working checkout had received separate terminal-viewer changes by the time of the rebuild. The release verifier checked the local channel after the preflight archives were promoted. [Preflight release checksums](../../../dist/releases/relay-sdk-0.1.14-preflight/SHA256SUMS)

The release verifier checks every embedded dependency checksum against `go.sum` and rejects module replacements. The promoted amd64 and arm64 packages passed. A disposable arm64 archive with an altered `github.com/segmentio/encoding` build-metadata checksum was rejected even after its outer archive manifest was recomputed. [Release verifier](../../../packaging/relay-release.py)

Run the checkout's upgrade and rollback verifier with any two trusted relay release directories. It verifies each archive against its SHA-256 manifest and runs the extracted executables in unprivileged, network-disabled Linux containers. The retired pins must produce a remote TLS rejection. The fixture also checks the unrelated tenant's in-flight stream, the latest enrollment file's digest after rollback and aggregate metrics.

```sh
python3 design/verification/relay-release/verify.py \
  dist/releases/relay-sdk-0.1.14-a968ae56/relay dist/relay
```

The verifier requires Go, Python 3.11 or later, and Docker. Use `--arch` to select the executable's architecture if your Linux host lacks emulation for the other one. This command passed on both architectures for the preceding and promoted archives. Separate negative checks rejected a mismatched checksum and a duplicate manifest entry before extracting an executable. [Verifier](../relay-release/verify.py) · [Loopback fixture](../relay-release/main.go)

### Linux release with frontend tool argument fidelity

The current local Linux release adds exact 64-bit decimal argument handling to the preceding preflight build. It was built from the verified preflight source snapshot plus the frontend-tool changes. A second Go build cache reproduced both archives and their manifest byte for byte. The service, CLI and MCP bridge passed their pinned race suites on that snapshot. Both extracted Linux binaries passed the relay upgrade and rollback rehearsal against the preflight release. Revoked pins stayed revoked and an unaffected stream completed during enrollment reload. The current local archives and standalone executables passed verification after promotion. [Current checksums](../../../dist/relay/SHA256SUMS) · [Linux rehearsal](../../../dist/releases/relay-sdk-0.1.14-frontend/rollback-linux.log) · [Frontend tool tests](../frontend-tools.md)

Prometheus 3.3.0 validated the bundled alert rules and scraped each exact promoted relay binary inside an unprivileged, network-disabled Linux container. The synthetic receiver accepted the host-unavailable alert after 68 HTTP 503 responses on amd64 and 69 on arm64. The notification and daemon logs omitted the fixture bearer and worker identifier. The amd64 relay ran under Docker Desktop's Linux translation. The managed alert receiver and operator acknowledgement remain staging gates. [amd64 alert log](../../../dist/releases/relay-sdk-0.1.14-frontend/alerts-amd64.log) · [arm64 alert log](../../../dist/releases/relay-sdk-0.1.14-frontend/alerts-arm64.log)

### Commander Linux builds with managed Claude model selection

Two independent builds produced identical relay archives with SDK 0.1.13 and transport 0.1.0. The installed standalone executables matched the archive members. All 13 embedded Go module checksums matched Commander's `go.sum`. [Model selection verification](../sdk-runtime.md#managed-claude-model-selection)

| Linux architecture | Relay archive SHA-256 | Standalone agentctl SHA-256 |
| --- | --- | --- |
| amd64 | `7d965c966e1b9f1cd468f92875ef671fa119bc7c103dc12d398dbdd6bc8c310f` | `d1d8047f5ec8e3aec0accc433530472287ca354454e3459e515d9c6f5177c0d1` |
| arm64 | `514d123e67fdee8887b0009078079e0f019d916a1f32f03c06de164d48f71b7e` | `d9244fccfcd3123ced375eeaac2c4f32d7abdae2248e05e23ea54915eb9e61c0` |

Each architecture ran the previous and candidate executables in an unprivileged Linux container with external networking disabled. SIGHUP applied enrollment, rotation and revocation while an unaffected tenant's active stream finished. After rolling back the executable and retaining the latest enrollment, the relay rejected both revoked certificate pins, returned HTTP 421 for the revoked host, and returned HTTP 200 for both retained hosts. The rehearsal copied the executables to the VM's temporary filesystem before startup. [Relay deployment and rollback](../../RELAY-DEPLOYMENT.md)

### Prior candidate checks

Two independent builds of SDK 0.1.13 produced the same eight artifact digests. Standalone transport 0.1.0 also reproduced byte-for-byte. A separate Go consumer installed the transport from its local archive and passed five race-test runs covering scoped selection, a matched error followed by EOF or cancellation, an incomplete write, and overlapping permission requests answered in reverse order. [SDK manifest](../../../dist/sdk/agent-acp-0.1.13/manifest.json) · [Transport manifest](../../../dist/sdk/agent-acp-transport-0.1.0/manifest.json)


Two independent 0.1.12 releases produced the same source snapshot and eight artifact digests. The primary SDK checkout matched all 59 release inputs and all 30 packaged Go files. A separate consumer installed and tested the Go, TypeScript and Python packages. An altered Go archive was rejected against the pinned checksum. The new contract fixture carries a selected-session update with a nullable field and the integer `9007199254740993`. In a real stdio regression, malformed frames at startup and after binding retained their diagnostic categories. Genuine child stderr and valid selected-session records remained available. [0.1.12 manifest](../../../dist/sdk/agent-acp-0.1.12/manifest.json) · [Cross-language fixture](../../../dist/sdk/agent-acp-0.1.12/conformance/session.json)


The installed 0.1.10 Go, TypeScript and Python packages passed their contracts and Commander rejected an altered archive at this pin. Two independent builds produced identical manifests and all eight artifact digests. The Go race suite exercised peers that return mixed directories across native and portable pages, including missing and relative paths, aliases, additional roots and unscoped listings. The directory tests ran on macOS and Linux arm64. The Windows test binary cross-compiled. Scoped operation tests also covered permission options, unknown fields, provider errors, transport disconnects and oversized records. [Local manifest](../../../dist/sdk/agent-acp-0.1.10/manifest.json)


The installed 0.1.9 Go, TypeScript and Python packages passed their contracts, and Commander rejected an altered Go archive at that pin. Two independent builds reproduced the same manifest and eight artifact digests. The embedded and ACP subprocess fixtures passed the same one-session-per-page listing and image/audio checks. Separate negative fixtures advertised a listing which omitted a session or returned replies computed from corrupted media. The driver rejected each. The separately installed Pi translator passed its advertised listing and image checks and rejected audio. [Pi verification](../pi-translation.md) · [Shipped fixture protocol](../../../dist/sdk/agent-acp-0.1.9/conformance/README.md)

The installed 0.1.8 Go, TypeScript and Python bindings passed their shared contract with the new `sourceCursor` and `sourceRecord` fields. The installed Go tests also verified the runtime, passive native readers and compiled-in/executable adapter conformance. Commander rejected an altered archive at the new pin.

An independent comparison read the two completed Color Studio workers from the Claude Agent SDK and Codex App Server, then read the same sessions through the installed Go archive. It paged two observations at a time, resolved each source cursor within that session and compared each decoded JSON original to its provider record. For Codex, the comparison treated a turn’s metadata and each ordered item as separate records. All fields and both supplied PNGs matched.

| Provider | SDK pages | Observations | Distinct originals | Scalar field values | Original PNG |
| --- | ---: | ---: | ---: | ---: | ---: |
| Claude Code | 4 | 7 | 6 | 152 | 110 bytes |
| Codex CLI | 6 | 11 | 10 | 121 | 108 bytes |

Claude’s originals included the message UUID, timestamp and origin. Codex’s included structured tool arguments and results, duration, error fields and turn timestamps. Synthetic reader tests also retained an unfamiliar field on a recognized tool, linked multiple blocks across page boundaries and returned an individually large original intact in its own page. The source remains addressable through the worker’s history permission. [Native conversation evidence](../incremental-native/README.md)


The installed 0.1.7 Go, TypeScript and Python packages passed conformance. The Go runtime tests compared the live and replayed result for direct MCP errors, wrapped tool errors, JSON-RPC errors with ACP partial output, explicit cancellation, and successful results. Commander rejected a modified 0.1.7 archive. [Transcript verification](../transcript-coverage/README.md#live-acp-source)

The installed 0.1.6 Go, TypeScript and Python packages passed the shared contract. Commander rejected a modified Go archive advertised at the same version. The 0.1.6 media fixture sent text, image, text, audio and text through an independently launched ACP executable. The executable checked every block and its exact bytes. Commander refused unavailable capabilities before queuing a request, kept the media bytes outside shared events, and retained them in the worker's scoped Live source. The fixture used deterministic media bytes and a synthetic ACP peer. [Reference console integration](../../../poc/agui-console/README.md#send-an-image-or-audio-prompt)

The full Commander Go race suite passed against 0.1.6 with local socket and tmux integration enabled. The CopilotKit connector suite passed eight tests. Both local Linux relay archives were rebuilt against this pin and passed SHA-256 verification.

The earlier 0.1.1 build reproduced identical manifests and byte hashes in two independent output directories. The installed 0.1.5 Go, TypeScript and Python packages passed the shared contract. The Go runtime verified the live source session, turn and cursor association and preserved MCP text and media descriptors without including inline bytes in the preview. The pinned build rejected a modified Go archive advertised under the same version. SDK replay tests cover a completed tool returned as a single update, scoped pagination, changed history, and cancellation of historical permission requests. [Stock ACP replay in Commander](../stock-acp.md)

A standalone Commander source copy built from the 0.1.1 release archive in a fresh Go module cache. That binary completed the Pi translator workflow, including the one-time permission and passive history recovery after restarting Commander. The full Commander Go race suite passed against the archive with tmux and local socket integration enabled. [Pi verification](../pi-translation.md)

## GitHub distribution

GitHub can host all three deliverables through different services. The npm registry supports the TypeScript SDK and the Commander connector as scoped packages. Use the confirmed GitHub owner's scope, link each package to its source repository, and publish from GitHub Actions with that repository's package permissions. [GitHub npm registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-npm-registry)

Serve the Go module from the tagged SDK repository. Once the repository is confirmed, move the local module identity from `agent-acp.local/sdks/go` to `github.com/OWNER/REPOSITORY/sdks/go`, update the generated imports and Commander pin, and tag the submodule with `sdks/go/vVERSION`. Use `GOPRIVATE` for a private repository and verify installation from outside both checkouts. [Go module subdirectories](https://go.dev/ref/mod#module-directories)

Attach the Python wheel and release checksums to the matching GitHub Release. An authorized consumer downloads the wheel and installs the verified local file. GitHub Packages lists neither Go nor a PyPI-compatible registry. [GitHub package formats](https://docs.github.com/en/packages/learn-github-packages/introduction-to-github-packages#supported-clients-and-formats) · [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)

The current Commander rollout uses local release archives. Its checkout and the SDK checkout have no GitHub remotes. A future independent SDK publication would need a repository owner and permanent package identities.

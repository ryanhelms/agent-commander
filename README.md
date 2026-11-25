# Agent Commander

Agent Commander is a native macOS cockpit for supervising coordinators and agents. Follow a worker's live terminal or switch to a formatted conversation with tool results and attachments. Answer worker questions, send follow-ups, and manage local or SSH-backed sessions from the cockpit or `agentctl`.

The multiplayer pilot adds a menu bar panel for sign-in, friend requests, and sharing workers or GitHub operations through a configurable relay. Grants apply to a specific friend and action, and the owner can revoke them. [Multiplayer architecture](design/MULTIPLAYER-RELAY.md) · [Two-Mac pilot](design/MULTIPLAYER-PILOT.md)

## Download the pilot

Open [GitHub Releases](https://github.com/nscaledev/agent-commander/releases) with your Nscale GitHub account. Choose an Agent Commander pilot release and download the universal macOS ZIP and `SHA256SUMS`. Compare the ZIP's hash with its entry in the manifest before extracting it.

```sh
shasum -a 256 Agent-Commander-Multiplayer-Pilot-macOS-universal.zip
```

The universal app requires macOS 26 or later and supports Intel and Apple silicon. GitHub Actions produces an ad hoc pilot build. The [release guide](RELEASING.md) covers notarized distribution and the Linux relay downloads.

## Build and open from source

Use macOS 26 or later with Xcode's macOS 26 SDK and Swift 6.2 or later, Go 1.26 or later, Git, and Make. For local agent runs, install tmux and the harness you want to use. For source development, place the `agent-acp` and `agent-acp-transport` checkouts beside `agent-commander`. The Go module resolves them at `../agent-acp/sdks/go` and `../agent-acp-transport`.

```sh
make run
```

`make run` opens `dist/Agent Commander.app` through Launch Services. It builds the app on first launch and reopens that bundle on subsequent launches. Closing the window preserves running assignments. The app name is **Agent Commander** and its bundle identifier is `local.agentcommander.cockpit`.

**Agent Commander → Settings… → Allow only one instance** is on by default for each macOS user. Launching another copy brings the existing cockpit forward. To open a separate copy deliberately, turn the setting off and use `open -n "dist/Agent Commander.app"`. macOS remembers the preference between launches.

To install source changes, quit Agent Commander, run `make app`, then run `make run`. Builds use an ad hoc signature by default. To give macOS a consistent signing identity across rebuilds, supply the same existing Apple signing identity on each build, for example `make app CODE_SIGN_IDENTITY="Developer ID Application: Example Company (TEAMID)"`. An ad hoc signature identifies one build, so changing its code can prompt macOS to request permission again. [Apple code signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

With `gh` authenticated to the private repository, fetch the exact Go modules required by `go.mod` and build a release configuration without sibling checkouts.

```sh
python3 packaging/sdk-inputs.py fetch nscaledev/agent-commander
make app CONFIG=release
make run
```

The release tooling verifies both module archives against `go.sum`. Use `make CONFIG=release cli` for the CLI alone or `CONFIG=release sh poc/agui-console/build.sh` for the reference console. To use another copy of the pinned archives, set `SDK_RELEASE` to the SDK directory and, if needed, `AGENT_ACP_TRANSPORT_RELEASE` to the transport directory. [SDK release verification](design/verification/sdk-release/README.md)

To review the 28 native screens and states with sample data, quit the running app, then open the canonical bundle with the gallery argument. Launch arguments and environment variables take effect when a new process starts.

```sh
open "dist/Agent Commander.app" --args --design-preview gallery
```

Use the title bar’s preview menu or press ⌥⌘← and ⌥⌘→ to browse. The menu can pause sample activity or reset the current view. You can also open a specific view by its name in the concept gallery, such as `attention-pip` or `integration-blocked`. Preview replies, filters, and other controls use in-memory data. A normal launch opens the live local cockpit. [Original concepts](design/concepts/index.html) · [Native verification](design/verification/README.md)

## Run new local sessions over ACP

Commander selects the `opus` model alias for new managed Claude coordinators and workers. Commander asks the local or SSH-launched Claude ACP adapter to select Opus and waits for its acknowledgement before the first prompt. The legacy Claude CLI receives `--model opus`. Independently registered profiles use their own launch settings.

New Claude coordinators and workers use the independent Go session SDK when Commander can find the installed ACP adapter. The worker’s tmux pane, the cockpit, MCP and the CLI address the same assignment and native session. On reconnect, Commander reads native history into the console. For installations with only the Claude CLI, Commander can still start a legacy session.

With Node 22 or newer, you can point the same app at a disposable development service. Quit the app before opening it with the development environment.

```sh
export AGENT_ACP_HARNESS_DIR="$(cd ../agent-acp/harnesses/local && pwd)"
npm ci --prefix "$AGENT_ACP_HARNESS_DIR"
export AGENT_COMMANDER_HOME="$(mktemp -d /private/tmp/commander-sdk.XXXXXX)"
./dist/agentctl start
open --env "AGENT_COMMANDER_HOME=$AGENT_COMMANDER_HOME" \
  --env "AGENT_ACP_HARNESS_DIR=$AGENT_ACP_HARNESS_DIR" "dist/Agent Commander.app"
```

A service reads these settings at startup. Keep the same `AGENT_COMMANDER_HOME` to revisit it. Set `AGENT_COMMANDER_RUNTIME=acp` to require ACP, or `legacy` to roll back new built-in Claude sessions. Existing assignments retain their recorded runner. An absolute `AGENT_COMMANDER_CLAUDE_ACP` or `AGENT_COMMANDER_CODEX_ACP` overrides the SDK harness directory and executable search. [Native verification](design/verification/sdk-runtime.md)

### Opt in to managed Codex

Use the pinned `codex-acp` from the same installation and the Codex CLI. Create a private, separate native Codex profile, then sign it in through Codex itself.

```sh
export AGENT_COMMANDER_CODEX_PROFILE="$HOME/.agent-commander-codex"
mkdir -m 700 "$AGENT_COMMANDER_CODEX_PROFILE"
CODEX_HOME="$AGENT_COMMANDER_CODEX_PROFILE" codex login
export AGENT_COMMANDER_CODEX_ACP="$AGENT_ACP_HARNESS_DIR/node_modules/.bin/codex-acp"
```

Set the profile before starting the Commander service. Ask a Claude coordinator to delegate a worker with `client: "codex"`. The bridge uses a read-only planning profile and accepts the Commander MCP tools allowed for that worker. The dedicated Codex profile keeps the native transcript. [Real mixed cockpit verification](design/verification/incremental-native/README.md)

## Run a worker over SSH

Configure one OpenSSH host alias and matching checkout on each machine. The SSH login needs a working Claude account, the Claude ACP adapter and a copy of `agentctl` built for the host. The host's noninteractive PATH must resolve Node. For passive history, make `claude-agent-acp` discoverable beside the configured adapter path or set `AGENT_ACP_HARNESS_DIR` in the remote helper's environment. Confirm the host key through your normal SSH setup and enable Unix socket forwarding on that host.

Start a fresh Commander service with these variables. The optional `AGENT_COMMANDER_SSH_CONFIG` selects an absolute OpenSSH config path.

```sh
export AGENT_COMMANDER_SSH_HOST=dev-linux
export AGENT_COMMANDER_SSH_LOCAL_CHECKOUT=/absolute/local/project
export AGENT_COMMANDER_SSH_CHECKOUT=/absolute/remote/project
export AGENT_COMMANDER_SSH_ADAPTER=/absolute/remote/bin/claude-agent-acp
export AGENT_COMMANDER_SSH_AGENTCTL=/absolute/remote/bin/agentctl
```

Start a run in the configured local checkout and ask the coordinator to delegate one worker locally and one to `dev-linux`. The optional `host` field is available on `commander_delegate` and the worker creation API. The wall shows the SSH alias and remote checkout for the remote worker. Its conversation runs on the SSH host while its controlling tmux pane runs on this Mac. A disconnected SSH-only runtime may require a new assignment. [SSH verification](design/verification/ssh-worker.md)

## Try a planning run

Choose **New run**, select a project directory and enter a planning task. For a quick first run, enter the following task in a small project.

> Plan an onboarding note for this project. Delegate a reader-profile worker and a structure-review worker. Have the first worker ask me which audience I’m writing for and wait for my answer. Have the second suggest three headings while I decide. Bring their findings back together.

The coordinator launches its workers through Commander’s MCP tools. Select a worker to inspect its output. A pending question identifies its originating worker and run. Type the answer into that card and select **Send reply**. The worker receives it through its original request. Prompts and answers travel as data, including whitespace, quotes and dollar signs. Each managed console prints its own tmux attach command. **Stop run** closes delegation for that run and requests cancellation of its managed sessions.

On a managed local Claude worker, open its action menu and choose **Send follow-up…**. Commander takes control, opens the focused console, and sends the message to the same Claude conversation when the current turn ends. Use **Option–Return** to add a line. While you hold control, the coordinator yields replies and control commands for this worker. **Hand back control** returns control and cancels any follow-up that has yet to start. **Interrupt turn** cancels an active turn and keeps its conversation available. **Stop worker…** closes just that worker’s tmux session.

**Needs Attention** uses the right sidebar by default. Choose **Picture-in-picture** from the worker area's attention menu to use a floating, draggable panel that remembers its location. A waiting console adds an amber line inside its harness border. **View request** opens its reply on demand.

Use the display icon in a console’s title bar to choose **Console** or **Pretty** for that worker. Pretty formats conversation text as chat, with Markdown and expandable tool results. The worker keeps its choice on the wall, in zoom and in picture-in-picture. The window toolbar’s **Display** menu applies either mode to every console across runs, including new workers. Each app launch starts in Console mode.

The console header and border identify its harness. Claude Code starts orange, Codex blue, and generic MCP violet. Named custom harnesses receive distinct accents. Open the console’s display menu and choose **Accent for** the harness to pick a color. The choice applies to every console using that harness and is saved on this Mac. Choose **Default** in the same menu to restore its original color.

## Open Devflow from a coordinator

Ask **“Open the Devflow provider editor for this repo”** or **“Open the task management provider in Devflow.”** An interactive coordinator connects to Devflow’s UI-only MCP companion at startup and asks it to open or reuse the console for its checkout. Your request takes you to the specified screen. The coordinator opens the console with its own Commander identity. Choose **Check activity** on Overview to see worker requests available to that identity for the checkout. You review and apply configuration changes in the browser. Planning workers keep their existing tool access.

Commander checks for the UI launcher when a coordinator starts. It looks for Devflow in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, and `/usr/bin`. Set `AGENT_COMMANDER_DEVFLOW` to an absolute executable path in the service environment for another installation. Start a new run after upgrading Devflow. Planning still works when the companion is unavailable.

## Read Linear issues from a coordinator

Grant `linear.issue.read` to a specific checkout in the service's `tool-grants.json`. Use the checkout path you pass to Commander and the UUID of each Linear team that project may read.

```json
{
  "projects": [
    {
      "path": "/absolute/path/to/checkout",
      "tools": {
        "linear.issue.read": {
          "version": 1,
          "settings": {
            "credential": "engineering",
            "team_ids": ["7f6d8dee-b367-4a1f-8cbe-b0d0d6d8f250"]
          }
        }
      }
    }
  ]
}
```

Create a Linear personal API key with **Read** permission and restrict it to the configured teams. In the Commander state directory, save the key as plain text in `linear-credentials/engineering.key`. Set the directory to mode `0700` and both the key and grant file to mode `0600`. Commander reads the key in the service on each call. Grant changes take effect at service restart. [Linear API key permissions](https://linear.app/docs/api-and-webhooks#api-keys)

Ask a coordinator in that checkout to read an issue such as `ENG-123`. It can discover the tool through `commander_list_tools` and call it with ID `linear.issue.read`, version `1`, and arguments `{"issue_id":"ENG-123"}`. The response contains the issue's identifier, title, description, state, and URL. Commander checks the returned team UUID before releasing the result, and flags descriptions it truncates.

## Use the CLI

```sh
./dist/agentctl start
./dist/agentctl run "$PWD" "Plan the documentation for this project."
./dist/agentctl list
./dist/agentctl show RUN_ID
./dist/agentctl reply REQUEST_ID 'Use the SDK developer audience.'
./dist/agentctl take WORKER_ID CURRENT_GENERATION
./dist/agentctl follow-up WORKER_ID HELD_GENERATION 'Check the retry budget too.'
./dist/agentctl hand-back WORKER_ID HELD_GENERATION
./dist/agentctl interrupt WORKER_ID
./dist/agentctl stop-worker WORKER_ID
./dist/agentctl stop RUN_ID
```

### Link a Go session adapter

A Go package compiled into Commander can supply the portable SDK runtime directly. Register a `harness.Adapter` from the package's `init`, and import that package in the `agentctl` build so both the service and its worker process register the same constructor. The ID and version identify the implementation. `Open` receives the working directory, the worker-scoped MCP configuration and the optional ACP source callback. Each call returns a fresh SDK runtime with a `Close` method.

Select it with `agentctl run --client builtin:ID DIRECTORY TASK` or use the same client name when the local owner delegates a worker. For passive history, supply `ReadHistory` and return observations addressed to the requested session. Commander checks that binding again on each page. An old worker whose exact adapter version is unavailable reports that condition when its history is opened.

Run the SDK's `conformance.Check` on the registered constructor using the same scenario used by executable adapters. The compiled file-reader fixture shows the registration, a real worker launch, a second turn and a history read after service restart. [Adapter interface](harness/registry.go) · [Fixture implementation](internal/provider/builtin_fixture_test.go) · [Worker integration test](internal/provider/builtin_integration_test.go)

### Register an installed ACP executable

Place an `acp-profiles.json` file in the Commander data directory and restart the service to load it. Supply a profile ID, an absolute executable path and a literal argument array. That executable can be an ACP CLI or a separately shipped translator.

```json
{
  "gemini": {
    "command": "/absolute/path/to/gemini",
    "args": ["--acp"]
  }
}
```

Select it with `agentctl run --client gemini DIRECTORY TASK`. The owner can also select a registered profile when delegating a worker through the run API. Registered executables run with the local developer's privileges and use their own tool policy. Commander requires an explicit owner selection and supplies the existing scoped MCP connection. The console can show the live ACP stream and resolve permissions supported by the executable. The provider owns retained history.

Use `"omit_commander_mcp": true` for an adapter that rejects client-supplied MCP servers. The adapter can still stream ACP tools and request ACP permissions. [Pi translator setup and verification](design/verification/pi-translation.md)

Pi profiles can opt into passive history with `"history": {"format": "pi-jsonl-v3", "directory": "/absolute/path/to/pi/agent/sessions"}`. Use the directory where the selected Pi installation stores its session journals. The profile binds the history source when creating a worker and reads only the matching session and project. [Pi history and restart proof](design/verification/pi-translation.md)

For a stock adapter verified to support ACP session loading, add `"history": {"format": "acp-v1-replay"}` to its profile before launching the worker. After stopping that worker, open its Provider source to page the retained session. Commander loads the original session and worktree in a disposable adapter process with an empty MCP server list. It restores the stopped worker's console after a service restart and keeps existing live console details while the service still retains them. [Antigravity replay](design/verification/stock-acp.md)

Use `agentctl catalog list` to read the official ACP registry, or pass one or more third-party HTTPS catalog URLs after `list`. Each snapshot includes its source, document digest, host platform and the published binary, npm and Python distributions. Publisher names are discovery claims and appear as unverified until an installation verifies them independently. [ACP registry format](https://github.com/agentclientprotocol/registry/blob/main/FORMAT.md)

To verify and stage a binary archive, run `agentctl catalog stage-binary URL ID VERSION ENTRY SIGNATURE PUBLIC_KEY`. Use the publisher's ACP agent entry, its raw detached Ed25519 signature, and an independently obtained PEM public key for that publisher. Commander checks the signature, compares the host's distribution to the catalog entry, and verifies the archive using the signed digest. If the catalog also provides a digest, it must agree. Commander stores the private archive and verification receipt under the Commander data directory. The staged files are inert.

Apply a staged binary with `agentctl catalog activate STAGE PUBLISHER_KEY_SHA256`. Use the stage directory's basename and the fingerprint of the publisher key you trust. Activation checks the staged bytes again, unpacks the release into a separate directory and verifies an ACP v1 handshake before updating the pin. Run new assignments with `agentctl run --client ID DIRECTORY TASK`. Use `agentctl catalog rollback ID` to switch future launches back to the previous installation. Existing workers keep their launch paths. Manually configured profiles with the same ID take precedence.

You can press Ctrl-C while a catalog command waits for another installer. If activation is canceled before the pin changes, the current installation stays selected and you can retry the same stage. Once Commander switches the pin, activation has taken effect.

`agentctl catalog updates` reports newer stable releases from the pinned publisher and catalog after they have been staged. It checks the publisher proof and archive digest again. The notice includes the stage ID and current version. Use the same activation command when ready to apply an update.

For an installed adapter, configure the publisher's stable HTTPS endpoints for the latest signed ACP entry and its raw detached Ed25519 signature. Use the independently verified public key from the original install. A refresh reads the adapter's original catalog and checks that the signed entry identifies the exact newer version offered there. Commander downloads and verifies the archive, then returns a notice with the stage ID. It returns `null` when the catalog offers no newer stable release. The active pin changes when you explicitly activate or roll back.

```sh
agentctl catalog update-source ADAPTER_ID \
  https://publisher.example/adapter/latest/entry.json \
  https://publisher.example/adapter/latest/entry.sig publisher.pem
agentctl catalog refresh ADAPTER_ID
```

Use `agentctl catalog stage-package URL ID VERSION npm|python ENTRY SIGNATURE PUBLIC_KEY` when the publisher supplies a signed offline bundle. The signed ACP entry pins the exact package version, including when the catalog supplies only the package name. Its host `binary` record points to the bundle and its SHA-256 digest. The host record's `cmd` names the installed launcher. Commander checks the package name, any version already pinned by the catalog, and the launch arguments and environment.

- **npm** bundles contain `package.json`, a version-3 `package-lock.json`, and all dependency tarballs under `packages/`. Lock entries use local tarball references and SHA-512 integrity. The launcher is under `node_modules/.bin/`. Activation runs npm offline with install scripts disabled.
- **Python** bundles contain `requirements.txt` with exact versions and SHA-256 hashes plus a `wheels/` directory for the complete dependency set. The launcher is under `venv/bin/`. Activation builds an isolated virtual environment and installs only verified wheels.

Activate, view updates, and roll back package builds with the same catalog commands used for binaries. The required local runtime is npm and Node for npm packages or Python with venv and pip for wheels.

To read the local HTTP API directly, run `./dist/agentctl api GET /v1/runs`. For a mutation, pass a JSON body on stdin. All CLI, desktop and MCP domain operations call the same service. Each managed agent receives its own MCP connection bound to its run and worker identity.

The run response lists each live managed worker’s control generation. Taking control and handing it back advance that generation. Coordinators can call `commander_send`, `commander_interrupt`, and `commander_stop_worker` on workers they direct.

Pretty and Console subscribe to `GET /v1/ag-ui/events?projection=incremental` on the private Unix socket. The initial `STATE_SNAPSHOT` contains the workers, their messages and terminal chunks. Subsequent `STATE_DELTA` frames update those values. Reconnecting or falling behind the retained window starts from a fresh snapshot. Open a tool row for its result, **View attachment** on a user message for that prompt’s media, or **Show all fields** for the underlying record. The worker’s **Inspect Source** action also opens live ACP, provider history and the local journal. Replies use the existing request-ID endpoint. [CopilotKit reference console](poc/agui-console/README.md)

**Terminal** shows the managed runner’s live tmux screen in SwiftTerm. The display menu also offers **Console**, **Pretty**, and **Watch Terminal in Window…**. Terminal is read-only and supports selecting and copying text. Detaching and reconnecting leave the worker running, and its transcript is available while detached or when the live terminal is unavailable. Replies, approvals and interrupts use the worker’s Commander controls. The owner CLI can open a viewer with `agentctl terminal observe WORKER`. [SwiftTerm for macOS](https://github.com/migueldeicaza/SwiftTerm/tree/v1.20.0#macos-nsview)

## Local data and troubleshooting

On the private owner socket, a CopilotKit backend can submit a text follow-up with `POST /v1/ag-ui/workers/WORKER_ID/run`. Send AG-UI run input with the worker ID as `threadId`, a fresh `runId`, the new user message last, and the current held input generation in `forwardedProps.generation`. The stream returns run lifecycle events, worker messages and state with the accepted `operationId` and pending requests. Reply through `POST /v1/ag-ui/workers/WORKER_ID/requests/REQUEST_ID/reply`. Reconnect with `GET /v1/ag-ui/workers/WORKER_ID/operations/OPERATION_ID?runId=RUN_ID`. If the connection ended before returning an operation ID, retry the original POST with the same run ID and prompt. [Local CopilotKit connector](poc/agui-console/README.md#connect-an-independent-local-runtime)

### Direct HTTPS for hosted apps

Configure an OAuth authorization server to issue access tokens for your Commander audience. Its [RFC 7662 introspection endpoint](https://www.rfc-editor.org/rfc/rfc7662.html) must return `active`, `sub`, `client_id`, `iss`, `aud`, `exp`, and `scope` for accepted tokens. Give Commander its own introspection client credentials. Set `AGENT_COMMANDER_OAUTH_INTROSPECTION_SECRET` in the service environment and point `AGENT_COMMANDER_HOSTED_CONFIG` at a JSON file like this one.

```json
{
  "listen": "127.0.0.1:8443",
  "certificate": "/absolute/path/to/tls-cert.pem",
  "private_key": "/absolute/path/to/tls-key.pem",
  "introspection_url": "https://login.example.net/oauth/introspect",
  "introspection_client_id": "commander-introspection",
  "issuer": "https://login.example.net",
  "audience": "https://commander.example.net"
}
```

Use the appropriate interface and a certificate trusted by the hosted backend when exposing the listener beyond loopback. An optional `introspection_ca` PEM path adds a private CA for the authorization server. Restart `agentctl serve` to enable the listener.

Create `hosted-grants.json` in the Commander state directory with mode `0600`. Each entry binds the developer's OAuth subject and an app's client ID to explicit worker IDs. Commander requires each scope in both the access token and that worker grant.

```json
[
  {
    "subject": "developer-subject",
    "client_id": "example-copilot-app",
    "workers": {
      "w-example": ["commander:observe", "commander:prompt", "commander:reply"]
    }
  }
]
```

| Route | Required scopes |
| --- | --- |
| `GET /v1/ag-ui/workers/WORKER_ID` and operation observation | `commander:observe` |
| `GET /v1/ag-ui/workers/WORKER_ID/operations?runId=RUN_ID` | `commander:observe` |
| `POST /v1/ag-ui/workers/WORKER_ID/run` | `commander:observe`, `commander:prompt` |
| `POST /v1/ag-ui/workers/WORKER_ID/requests/REQUEST_ID/reply` | `commander:reply` |
| Register frontend tools on a run and submit their result | `commander:frontend-tools` in addition to the run scopes for registration |
| `GET /v1/workers/WORKER_ID/history` | `commander:history` |

Read the held `generation` from the worker summary and include it with the prompt or reply. The same worker input lease governs both hosted and desktop commands. Run IDs and reconnect receipts are scoped to the app and developer. Replace the grant file atomically to remove access. Active streams check the current grant and token expiry before each event and at each five-second heartbeat. OAuth token status is checked again on the next request. [Hosted CopilotKit connector](poc/agui-console/README.md#connect-a-hosted-runtime)

Use `agentctl relay CONFIG.json` when Commander must reach a hosted app through an outbound connection. The app uses the same OAuth scopes and worker routes at its assigned relay hostname. [Relay deployment and recovery](design/RELAY-DEPLOYMENT.md)

Hosted apps can offer client-side tools to managed workers whose MCP bridge advertises frontend tool support. The app includes tool definitions on the AG-UI run and responds to an addressed tool call while the worker is waiting for it. [Frontend tool integration](poc/agui-console/README.md#offer-a-frontend-tool)

Use `agentctl api GET '/v1/workers/WORKER_ID/history?limit=32'` on the local owner connection to read a page from a worker's bound provider history. Pass the returned `nextCursor` as the URL-encoded `cursor` on the next request. The page uses the SDK's observation schema, including source extensions when the provider reader supplies them. History reads are passive. A missing history binding or reader is reported separately from a provider read failure.

Add `source=journal` to inspect supplementary records from a supported local Claude or Codex journal. Commander resolves the source using the worker's recorded session and checkout. An unknown format or unavailable source produces a history gap. The same endpoint and `commander:history` grant apply to hosted clients. The reference CopilotKit console opens these pages under **Session journal**. [Journal coverage](design/verification/transcript-coverage/README.md)

When a recovered user message has `metadata.acp.kind=provider_prompt_media`, use its **View attachment** action to open the original in Pretty or Console. For a hosted client, pass the message’s `metadata.acp.cursor` as `recordCursor` to the worker’s history endpoint. Pass `metadata.acp.pageCursor` as `cursor` if present and omit `limit`. The response contains the selected provider observation or a history gap. The reference console and embeddable client use the same lookup. [Browser verification](design/verification/copilotkit-live/README.md#opening-archived-prompt-attachments)

Add `source=live` to inspect recently received ACP details, including tool arguments, results, embedded content and unfamiliar fields. Commander keeps a bounded in-memory window for each worker and marks evicted source records with a gap. The default provider-history pages and journal pages remain available after a restart if the harness retained them. The reference console opens these live records under **Live ACP source**. [ACP source coverage](design/verification/transcript-coverage/README.md)

Set `AGENT_COMMANDER_MCP_OVER_ACP=1` in the local service environment to try the pinned draft with newly launched local ACP peers. Commander declares its scoped tools over ACP only when the peer advertises that transport. The existing stdio server remains the fallback. The draft uses stateless MCP 2026-07-28 with per-request metadata and an independent logical request ID. Commander still validates each tool against the worker's assigned scope. [Pinned draft](https://github.com/agentclientprotocol/agent-client-protocol/blob/d1585b5932ec5ed2f7b02e298be92afae9462194/docs/rfds/mcp-over-acp.mdx)

The default data directory is `~/Library/Application Support/Agent Commander`. It contains the private API socket, persisted run state, recent console output and private provider launch configuration. A detached service writes its startup errors to `service.log`. Treat the directory as private, since transcripts can contain sensitive project content.

- `AGENT_COMMANDER_HOME` selects a separate data directory for development. Its default socket is `service.sock` inside that directory.
- `AGENT_COMMANDER_SOCKET` overrides the socket path for both server and clients. Use a short path for Unix sockets.
- `AGENT_COMMANDER_CLAUDE` and `AGENT_COMMANDER_TMUX` select absolute executable paths when they are installed in a custom location. Start the service with these variables set. Standard Homebrew and user-local locations are checked automatically.
- If Claude asks for authentication, run `claude auth login` in a terminal. Reopen the app or inspect the worker’s launch error. To retry a failed planning task, start a new run.

## Verify changes and publish

Run `make test` for the Go tests. Run `make smoke` where local Unix sockets are permitted to exercise scoped MCP clients, the API and a disposable tmux worker with a deterministic model fixture. Both commands use local test data. Build the native cockpit with `make app`.

On macOS, run `make test-native` for the Swift console and incremental feed tests. It uses Swift Testing from Xcode or the selected Command Line Tools. To run the private capture replay, set `COMMANDER_AGUI_REPLAY` to a local JSONL file with an AG-UI `event` and its independently computed `expected` workspace state on each line.

Run `make test-multiplayer-docker` for the isolated three-user relay rehearsal. It covers enrollment, presence, sharing, Git pushes, and relay failover using disposable identities and repositories. [Docker rehearsal instructions](multiplayer/deploy/rehearsal/README.md)

Record user-facing changes in [CHANGELOG.md](CHANGELOG.md). [RELEASING.md](RELEASING.md) documents the build inputs, version tags, CI checks, and downloadable assets. See the [MVP plan](MVP-PLAN.md) for remaining work and [AGENTS.md](AGENTS.md) for implementation and verification conventions.

# Independent Pi RPC translator verification

The independently distributed Attamusc `pi-acp` translator starts the bundled Pi CLI in its native RPC mode and exposes stable ACP v1 over stdio. The test pins the upstream Git tag `v0.2.0` and commit `ded14789b966a80e87ef62a760377491c39741fc`. That lockfile selects Pi CLI 1.1.0. [Upstream release](https://github.com/Attamusc/pi-acp/tree/ded14789b966a80e87ef62a760377491c39741fc)

The tagged adapter declines client-supplied MCP servers. Register it with `omit_commander_mcp` to send an empty list in ACP session setup. Select the profile with `agentctl run --client pi`. A standard ACP permission can still reach Commander and receive the chosen option ID. [Registration](../../README.md#register-an-installed-acp-executable)

```json
{
  "pi": {
    "command": "/absolute/path/to/node",
    "args": ["/absolute/path/to/pi-acp/dist/index.js"],
    "omit_commander_mcp": true,
    "history": {
      "format": "pi-jsonl-v3",
      "directory": "/absolute/path/to/pi/agent/sessions"
    }
  }
}
```

## Reproduce the onboarding proof

Build the translator from its separately distributed release with Node.js 22.19 or newer. Set the checkout paths to disposable directories.

```sh
git clone --branch v0.2.0 --depth 1 https://github.com/Attamusc/pi-acp.git /tmp/commander-pi-acp
git -C /tmp/commander-pi-acp rev-parse HEAD
npm --prefix /tmp/commander-pi-acp ci --ignore-scripts
npm --prefix /tmp/commander-pi-acp run build
sdk_version=$(go list -m -f '{{.Version}}' agent-acp.local/sdks/go)
sdk_release="dist/sdk/agent-acp-${sdk_version#v}"
python3 packaging/go-with-sdk.py "$sdk_release" build \
  -o /tmp/commander-pi-agentctl ./cmd/agentctl
python3 packaging/go-with-sdk.py "$sdk_release" build \
  -o /tmp/commander-pi-checker agent-acp.local/sdks/go/cmd/adapter-conformance
python3 design/verification/pi-rpc/verify.py \
  --translator /tmp/commander-pi-acp \
  --agentctl /tmp/commander-pi-agentctl \
  --conformance /tmp/commander-pi-checker \
  --verify-resume \
  --native-capture /tmp/commander-pi-recovery.json
COMMANDER_PI_REPLAY=/tmp/commander-pi-recovery.json make test-native
```

The probe runs the real Pi CLI with an isolated workspace, Pi profile and tmux server. Its loopback model fixture asks Pi to read a text file, a missing file and a 4 × 4 PNG. An isolated Pi extension asks permission for the text read through ACP. The model fixture waits for the marker returned by the actual file tool. The prompt contains a literal dollar sign and newline, and the fixture checks that both reach Pi.

- A standalone client built on the official `@agentclientprotocol/sdk` 1.8.0 opened and discovered the session, approved one read, closed it and loaded its replay. It matched all three tool calls to their input paths and compared the final content blocks between live delivery and replay. [Standalone client](pi-rpc/stock-client.mjs)
- Commander launched the same translator through the owner-registered profile, bound the native session ID, replied by Commander request ID with ACP option `allow_once`, and exposed all three results as addressed AG-UI tool messages. Each message’s source cursor located the matching final ACP update. The failed read retained Pi’s `ENOENT` diagnostic and filename. The successful image read retained its text note, MIME type and exact PNG bytes in their original order.
- All 37 upstream ACP bench fixture tests passed for the pinned checkout.

The SDK's shared adapter checker also passed through the installed Pi translator using the same loopback model fixture. It opened two sessions in the same directory, rejected a crossed permission reply, reconnected observers by cursor, and verified stale and active interrupt outcomes. The SDK runtime advertised no passive Pi history in that check. The subsequent Commander restart separately exercised its configured Pi journal reader.

With the checker installed from SDK 0.1.14, both original pi-acp processes exited before a third process resumed the second session by its original native ID. The resumed follow-up included that session’s original prompt and three file results. The first session’s image-fingerprint prompt stayed in the first session. The same new process received the addressed follow-up and cancellation. The probe records process IDs, method names and hashed session IDs while forwarding the original ACP bytes. [Resume trace](pi-rpc/trace-resume.mjs) · [Fixture and assertions](pi-rpc/verify.py)

A macOS companion CLI built from the promoted Linux frontend-tool release snapshot repeated that workflow with the pinned Pi translator and SDK checker. The standalone ACP client, live AG-UI and the restarted service agreed on all three results, including the missing-file error and original PNG. The private capture then passed the Swift replay test for both Pretty and Console. The probe used the loopback model fixture and left the running cockpit open. The companion CLI SHA-256 is `c43dada3ca14ac9e6002c9a4ac399b567deda68d959de22c7d9c400041c96962`. [Linux release identity](sdk-release/README.md#linux-release-with-frontend-tool-argument-fidelity) · [Native replay test](../../Tests/AgentCommanderTests/PiRecoveryTests.swift)

Build `adapter-conformance` from the packaged SDK and pass its path with `--conformance` to include the shared check in the probe. [Build command](sdk-release/README.md#adapter-conformance)

The checker from the 0.1.9 archive listed both completed Pi sessions through one-session pages. It sent an inline PNG to the unchanged translator. The loopback model hashed the actual bytes of the image in its current user message, and the digest matched the input. The SDK rejected an audio prompt because Pi did not advertise audio. The same run repeated the stock-client, live tool and cold-history comparisons with Commander built from the pinned archive. The native Pretty and Console projection test opened the 4 × 4 PNG from that restarted capture and verified the missing-file error under its original tool ID. [Loopback model and probe](pi-rpc/verify.py) · [Native recovery test](../../Tests/AgentCommanderTests/PiRecoveryTests.swift)

The complete workflow passed again with Commander and its checker built from SDK 0.1.10. The two native Pi session identities were found through one-session pages under the selected directory. The native projection test used this run’s fresh capture and opened the failed read and the PNG in both modes. [Installed compatibility matrix](sdk-release/compatibility.json)

The proof uses deterministic model output while exercising the real native CLI, translator and tool execution. The synthetic Pi journal used header version 3 and retained separate model, thinking-level, system, user, assistant tool-call, tool-result and assistant-text records.

## Passive history and service restart

The optional reader uses the Pi installation's `sessions` directory, normally under `~/.pi/agent` or the configured `PI_CODING_AGENT_DIR`. Its format and resolved path are part of the worker's native binding. Commander can start before that directory exists. History becomes available after Pi writes the journal. Commander never sends `session/load` to read this history.

The probe restarted Commander after the Pi turn finished. It paged the exact session two observations at a time and matched the original multiline prompt. A fresh AG-UI subscription received restored tool messages. Each restored message’s provider cursor located its own `toolResult` journal record by native call ID, including Pi’s error flag and the same content blocks that the standalone client received. The original answer stayed attached to the same addressed approval. SHA-256 digests of all JSONL journals in the disposable Pi session directory matched before and after passive recovery. Another Pi session existed in the same workspace from the standalone ACP check. This check passed with Commander built against the packaged SDK 0.1.7 and with that release’s shared adapter checker.

The optional `--native-capture` writes a new file containing the restarted service’s incremental workspace snapshot and its paged provider observations. A Swift test passed this capture through the app’s workspace reducer, Pretty and Console transcript projections, tool detail resolver and Source field renderer. Both modes retained the failed call’s diagnostic and Pi error flag. The image result’s source record decoded to the same PNG bytes and AppKit opened it as a 4 × 4 bitmap. This is a headless projection check. [Native recovery test](../../Tests/AgentCommanderTests/PiRecoveryTests.swift)

A separate Node application installed the packaged CopilotKit connector and used its worker-scoped AG-UI endpoint. It selected the one-time read approval, inspected the actual file marker in a tool-role message and received the same message and answered request when it reattached by run and operation ID. Commander's passive Pi history reader also returned the file result under the bound native session.

The Go tests reject a cursor from another Pi session and a journal whose header disagrees with its filename. They preserve multipart result data, report unsupported versions and damaged records as gaps, and verify that changing the profile source cannot retarget an existing session. Individual records above 1 MiB produce a history gap. Computer Use verified the same file marker in Pi's Provider source from both native display modes. [Native verification](native-source/README.md)


The 0.1.12 SDK candidate repeated the workflow with Pi 1.1.0, the independently installed pi-acp 0.2.0 executable and a local deterministic model. The selected worker completed the addressed one-time permission. Stock ACP, the live AG-UI feed and the restarted native-history reader agreed on all three file results, including the missing-file error and the original 73-byte, 4×4 PNG. The cold read recovered 21 observations under one native session ID and left the journal hashes intact.

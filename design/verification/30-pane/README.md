# 30-pane workspace stream verification

## Installed macOS backend with SDK 0.1.14

The installed backend repeated the incremental 30-pane workload. All six idle and six loaded approvals reached the selected adapter. The reconnect restored the pending request in 32.89 ms in one sample. After restart, the worker's history returned all 420,000 attachment bytes while the workspace snapshot kept the attachment payload out of the feed. [Raw samples](sdk-0.1.14-incremental.json)

| Loaded phase | SDK 0.1.13 incremental | Installed SDK 0.1.14 incremental |
| --- | ---: | ---: |
| Approval visible, median / maximum | 41.31 / 78.34 ms | 30.27 / 59.47 ms |
| Answer visible, median | 28.88 ms | 19.46 ms |
| Adapter acknowledgement visible, median | 272.11 ms | 267.20 ms |
| Workspace JSON bytes including reconnect | 3,746,329 | 3,350,983 |
| Peak sampled service RSS | 45.98 MiB | 46.06 MiB |

Each column describes one run with synthetic ACP peers. The emitter continued until the loaded approval phase ended, so the byte counts reflect the phase duration as well as the stream format.

### Slow workspace subscriber

A separate socket regression pauses an incremental subscriber while one worker publishes 96 revisions and a different worker has an addressed approval pending. A fresh subscriber receives the latest output and pending request. The paused connection receives a `workspace_delta_expired` snapshot carrying the same request and catches up to the latest output. After the owner selects **Allow once**, both connections receive the resolution. The fixture forces backpressure with small TCP buffers and uses the same service routes as the cockpit. It complements the 30-pane timing measurements. [Socket regression](../../../internal/service/workspace_stream_test.go)

## SDK 0.1.13 release

The same staged release CLI ran the 30-pane scenario twice on the local arm64 Mac. One run used the incremental feed consumed by the native cockpit. The other used the compatibility feed. Each answered six approvals at idle and six under load, and the ACP peer acknowledged each selected answer. Both restored the same pending request ID on reconnect. After stopping all three disposable runs and restarting the service, both feeds linked the recovered tool result to its original journal cursor. The scoped reader retrieved the exact 420,000 attachment bytes, and neither workspace feed contained the attachment marker. [Incremental samples](sdk-0.1.13-incremental.json) · [Compatibility samples](sdk-0.1.13-legacy.json)

| Loaded phase | Incremental feed | Compatibility feed |
| --- | ---: | ---: |
| Approval visible, median / maximum | 41.31 / 78.34 ms | 27.31 / 130.01 ms |
| Answer visible, median | 28.88 ms | 11.07 ms |
| Peer acknowledgement visible, median | 272.11 ms | 256.13 ms |
| Reconnect to pending request, one sample | 281.38 ms | 15.77 ms |
| Workspace JSON bytes including reconnect | 3,746,329 | 28,659,346 |
| Peak sampled service RSS | 45.98 MiB | 53.62 MiB |

The incremental run sent 86.9% fewer workspace bytes during its loaded phase. The emitter continued to run while the approvals were answered, so phase lengths and the number of text chunks could differ. One reconnect per run is insufficient to establish a latency distribution. Both reports include the executable hash. To repeat the release check, run the following for each projection on the same binary.

```sh
python3 -B design/verification/30-pane/measure.py --agentctl dist/agentctl --projection incremental --output /tmp/30-pane-incremental.json
python3 -B design/verification/30-pane/measure.py --agentctl dist/agentctl --projection legacy --output /tmp/30-pane-legacy.json
```

## Earlier measurements

On arm64 macOS 26.7.3, the driver started the pinned Commander service and confirmed 30 active tmux panes across three runs. Each pane ran a deterministic ACP subprocess with a bound session. The idle baseline kept the sessions open without streaming load. In the loaded phase one subprocess sent approximately 16 KiB every 50 ms and a different worker requested approval. Six requests were answered per phase through the owner API. The first loaded request was pending during a forced workspace SSE reconnect and retained its original request ID. [Fixture and driver](measure.py)

| Measure | Idle baseline | Under load |
| --- | ---: | ---: |
| Trigger to approval visible, median / max | 26.62 / 44.07 ms | 58.95 / 283.38 ms |
| Reply request to HTTP response, median / max | 8.06 / 17.69 ms | 12.30 / 40.29 ms |
| Reply request to answered state visible, median / max | 10.31 / 22.73 ms | 20.54 / 107.18 ms |
| Reply request to adapter acknowledgement visible, median / max | 304.97 / 445.24 ms | 289.08 / 469.41 ms |
| Peak sampled Commander service RSS | 22.88 MiB | 70.52 MiB |
| Workspace SSE JSON bytes received during the phase | 261,234 | 38,169,428 |
| Reconnect to the same pending approval | — | 51.12 ms |

The loaded byte count includes the reconnect snapshot. Timings cover the local Unix socket and a Python SSE client. RSS was sampled before and after each reply and covers the Go service. The workload used a deterministic ACP fixture rather than model calls. The workspace replaces changed run projections, so sustained text load can repeatedly send a run’s output window. This run measured the size of that traffic and set no release threshold. [Fixed-candidate samples](after.json)

Both candidates returned the complete 420,000-byte synthetic image from the worker’s scoped history endpoint. The earlier build copied a prefix of its encoded bytes into the shared workspace stream when it restored the stopped run’s Pi history. The fixed build streamed a provider-event notice instead. The driver checks the live and reopened feeds for the fixture marker. The provider regression test verifies that the history record remains byte-for-byte intact and that the console shows the omission notice. [Pre-fix samples](before.json) · [Provider test](../../../internal/provider/pi_history_test.go)

To repeat from the repository root with the staged SDK and an available tmux executable, run

```sh
python3 packaging/go-with-sdk.py dist/sdk/agent-acp-0.1.5 build -o /tmp/commander-30-pane ./cmd/agentctl
python3 design/verification/30-pane/measure.py --agentctl /tmp/commander-30-pane --output /tmp/commander-30-pane.json
```

The measured pre-fix and fixed binaries have SHA-256 digests `00c7bbbf82d1b632bac4844184f1dad8a1afe4972a9faa06fcc020452ed541b5` and `4392c9cc283d64aa24bafc8cfa2946469777ffb45ec73eb82c0289fa2756435e`, respectively.

The follow-up build with SDK 0.1.3 and live ACP source capture passed the same 30-pane scenario. Under load, the median approval became visible in 16.17 ms, the pending approval reappeared in 9.12 ms after reconnect, and peak sampled Commander RSS was 47.41 MiB. Scoped history still returned all 420,000 attachment bytes, and the reopened workspace contained none of the encoded payload. The workload stresses ordinary output. The separate executable fixture exercises capture of a large live ACP update. [Follow-up measurements](source-enabled.json) · [Live ACP fixture](../transcript-coverage/README.md#live-acp-source)

The SDK 0.1.5 build opened 30 panes and answered all six approvals under load. Approval visibility measured 28.25 ms median and 44.08 ms maximum. The original pending approval reappeared in 57.08 ms after reconnect. Peak sampled service RSS was 55.58 MiB, and the scoped attachment returned all 420,000 bytes. The measured binary has SHA-256 digest `56934ade31b9509b452ae010ae3cfcd260c075e585ea462df44be3350c6e3620`. [SDK 0.1.5 measurements](sdk-0.1.5.json)

# ACP audit candidate

Baseline Commander is `a4663f1`, SDK `0.1.14`, and transport `0.1.0`. The integrated release pins are SDK `0.1.19` and transport `0.1.3`. Commander verifies the Go module archives against `go.sum`. The SDK distribution includes its own manifest and the Go, npm, and Python artifacts. The neighboring development checkouts were preserved.

## Matched workloads

Runs used Go 1.27.4 on an Apple silicon host with 10 logical CPUs. Short series use nearest-rank p95, which is the maximum for the sample sizes shown. Reported timings cover local fixture work unless the table says otherwise.

| Workload | Baseline | Candidate | Evidence |
| --- | --- | --- | --- |
| Loaded owner reply to ACP peer receipt, 30 panes | 226.84 ms median, 288.73 ms p95 | 15.95 ms median, 39.53 ms p95 | Four alternating runs, 24 decisions per variant. All 24 delivered. The peer stamps the receipt using the host monotonic clock. |
| Loaded owner reply to Console projection, 30 panes | 257.33 ms median, 422.47 ms p95 | 46.22 ms median, 72.09 ms p95 | Same 24-decision paired series using the terminal-text projection. |
| First newline-free chunk without a message ID | 2,008–2,040 ms | 1.53–6.43 ms | Single-worker structured subscriber, three samples per variant. The later matched 30-pane test measured 2,020.40/2,050.13 ms median/p95 before and 4.02/9.26 ms after. All 12 candidate chunks arrived before terminal completion, compared with zero baseline chunks. A repeat after the publication deadline change measured 2,016.61/2,097.66 ms median/p95 before and 7.78/64.61 ms after, with all six candidate chunks arriving before terminal completion. |
| Unrelated read during a 500 ms credential check | 512.35–524.56 ms | 0.52–0.66 ms | Three samples per variant. |
| Unrelated read during a 1 s credential check | 960.40 ms median, 967.72 ms p95 | 0.96 ms median, 1.83 ms p95 | Six samples per variant. The injected check reached the configured deadline in both versions. |
| Stopped transcript with 2,048 records, paced | 16 loads, 32,768 updates, 1,545.6 ms median | One load, 2,048 updates, 89.4 ms median | Six samples per variant. Baseline unpaced replay failed. All three candidate burst runs completed. |
| Scoped live originals at 500 updates per second | Private polling received 1,158 and 1,626 of 2,000 | Continuous private streaming received 2,000 of 2,000 in each run | Both modes exercised on the same binary. The public feed stayed complete and attachment bytes stayed in the owner feed. |
| SSH, 512 KiB with 50 ms simulated RTT | 0.57 MB/s median | 4.90 MB/s median | Separate OpenSSH loopback run sent exactly 524,288 identical bytes in 294.34 ms legacy and 166.69 ms negotiated. |
| Idle transport receive allocation | About 1.08 MB/op | About 0.095 MB/op | Go microbenchmark. |
| Two workers through a compatible local peer | 203.9 ms median with isolated processes, 161.25 MiB adapter RSS | Shared 492.6 ms and 107.55 MiB. Isolated prewarm 494.3 ms and 161.09 MiB. | Five matched fixture runs. Both alternatives missed the startup latency gate. |

For 1, 10, 50 and 100 ms simulated RTT, legacy medians were 5.15, 2.03, 0.57 and 0.30 MB/s. Windowed medians were 26.31, 15.36, 4.90 and 2.55 MB/s. Each mode and RTT has three samples with allocations in the raw benchmark.

The paired incremental capacity test used 256-byte updates and a tool every fourth record. At 500 updates/s, both variants delivered every record. Median public SSE bytes increased by 4.3%, from 1.83 MB to 1.90 MB, with sampled service plus runner CPU of 0.100 and 0.090 seconds. At 50 updates/s, the 25 ms batching deadline increased median wire bytes by 43.8%, from 262,316 to 377,313, while delivering all 200 updates. Sampled CPU increased from 0.055 to 0.125 seconds at that rate. Each CPU sample had 10 ms granularity. Earlier candidates with the longer publication wait did not show the low-rate byte increase.

One six-decision candidate run recorded 78.36 ms p95 for peer receipt. That sample followed reconnect. The two reconnect samples in the larger 24-decision series were 62.18 and 23.05 ms. The performance trials used Commander `12b8f4c` with SDK `0.1.18` after the publication deadline change. SDK `0.1.19` adds a narrow explicit v1 resume fix with separate lifecycle regression coverage.

These comparisons include workstream builds. The sampled service and adapter RSS figures cover the indicated processes. Model inference, AppKit rendering, and full process-tree peak RSS need separate instrumentation. The [raw samples](samples/) preserve host load and binary digests where collected.

## Capability qualification

| Harness | Observed workflow | Startup selection |
| --- | --- | --- |
| Claude managed Opus, ACP adapter 0.109.1 | The installed account completed a synthetic v1 turn with Opus. The first v2 run found a configuration-ID mismatch. A managed Opus prompt passed over v2 with SDK 0.1.18. With the final SDK, both v1 and v2 interrupted a pending synthetic workflow and completed the next prompt on the original native session. Both versions recovered the exact marker in six history records after stopping, then explicitly reattached the same native session and negotiated the same protocol. The verifier joins streamed text chunks before comparing the literal output. | v1 by default. Full v2 qualification still requires installed permission coverage and matched interaction-latency comparisons. |
| Codex ACP adapter 2.9.0 | The installed adapter returned the synthetic marker in both v1 and v2. | v1 by default while v2 parity and performance remain open. |
| Antigravity 1.5.13 | The installed adapter selected v1 when offered v2. The delegated worker read the fixture marker and replayed the same value in eight stopped-session records. | v1. |
| Pi ACP translator 0.2.0 | The installed adapter selected v1 when offered v2. The loopback fixture exercised addressed approval, original tool results, and reattachment. | v1. |

The existing SSH path remains available through `AGENT_COMMANDER_SSH_LINK=legacy`. The windowed link requires explicit negotiation by the endpoint. New local sessions accept these independent overrides:

- `AGENT_COMMANDER_ACP_PROTOCOL=v2`
- `AGENT_COMMANDER_ACP_BROKER=share` or `prewarm`
- `AGENT_COMMANDER_MCP_OVER_ACP=1`
- `AGENT_COMMANDER_ACP_SYSTEM_PROMPT=standard`
- `AGENT_COMMANDER_ACP_ELICITATION=1`
- `AGENT_COMMANDER_ACP_SESSION_ACTIVITY=on`

The MCP draft pin is `d1585b5932ec5ed2f7b02e298be92afae9462194`. Scoped draft invocation, cancellation, and rejection paths have deterministic coverage. An installed managed Claude Opus v2 run selected the standard system prompt and `acp` for Commander tools. It exchanged six `mcp/message` frames and completed a read-only `commander_status` call. Production MCP-over-ACP activation still requires installed-peer cancellation, revocation, and result parity. Receipt expiration was left open. Existing receipts continue to preserve duplicate-request safety. An operator who explicitly resubmits an uncertain prompt after restart needs to choose its attachments again.

The upstream ACP Test Compatibility Kit at `7c71c4d1af0994e73bdc100c9f7f6b98f2319cda` passed all four selected v1 cases against the installed Pi translator using the loopback model. The subset exercised unauthenticated session creation and cancellation, and produced no full conformance verdict. [Upstream test kit](https://github.com/agentclientprotocol/acp-tck/tree/7c71c4d1af0994e73bdc100c9f7f6b98f2319cda)

## Reproduce

Use the exact release modules under `dist/sdk` in both checkouts. Benchmark the baseline and candidate serially on a single host. Use the current measurement scripts with both executables so that observations use the same timestamps.

```sh
python3 -B packaging/go-with-sdk.py build -o /tmp/agentctl-candidate ./cmd/agentctl
AGENT_COMMANDER_TEST_TMUX=1 AGENT_COMMANDER_TEST_INTEGRATION=1 \
  python3 -B packaging/go-with-sdk.py test -race -count=1 ./...
python3 -B design/verification/30-pane/measure.py \
  --agentctl /tmp/agentctl-candidate --projection incremental --output /tmp/candidate-30-pane.json
python3 -B design/verification/acp-audit/measure-admission.py /tmp/agentctl-candidate
python3 -B packaging/go-with-sdk.py test ./internal/sshlink -run '^$' -bench . -benchmem
python3 -B design/verification/sdk-release/verify.py --consumer-only dist/sdk/agent-acp-0.1.19
make test-native
```

Use the repository's capacity, transcript, and CopilotKit fixtures for additional comparisons. Run the native app against a disposable local service when comparing the Pretty and Console states, coordinator wall, and PiP.

## Verification of the integrated candidate

- The final Commander race run passed every package except a checkout branch-metadata test that hit the existing 350 ms Git probe timeout under host load. The entire service package passed its isolated release-pinned race rerun. The earlier serial Commander run with SDK 0.1.18 also passed all packages. The final local-disconnect test reproduced lost uncertainty on the old code and passed repeated race runs with the fix.
- The final SDK and transport race suites, generated-binding drift check, independent released Go/npm/Python consumer suites, and multiplayer race suite passed. The Go transport build used the checksummed 0.1.3 archive. The Swift suite passed 404 tests in 47 suites. The independent CopilotKit connector replayed a scoped Pi tool interaction after reconnect with the 0.1.16 workstream candidate.
- Computer Use checked the candidate's worker wall, focused Pretty and Console views, and approval PiP against the repository's coordinator wall, focused Pretty and attention concepts. The disposable PiP approval reached the peer. The first form popover clipped its controls. Claude Opus repaired the layout and the corrected build showed the whole form with its selection and submit controls. The same tested session accepted a typed multi-select form after a follow-up, displayed the full URL and host for a separate request, and received a decline. The app also showed the provider's unavailable resume/history states and limited the file composer to supported context modes. Attachment selection and reattachment were exercised by scoped API and native model tests. The original local cockpit was restored afterward.
- The local distribution app is ad hoc signed. The tested native binary SHA-256 is `efda5f52b67415df063e272e0723e9e6e1f2cbf48abbc8fa33ac9525325d3a2e`. Its signed bundled `agentctl` SHA-256 is `6b0e9378d52c081f336a44feba92f0ad999fbec3686d0926bea6ac33a1d4fc1c`. The build-inputs archive SHA-256 is `8d66143c8e6824741c447479c06e35889b05d3b2cdfc4c589143217ef4c9f75a`.

Managed Claude passed interruption, follow-up, stopped history and reattach in both wire versions. Real peer permission coverage, matched v2 interaction-latency qualification, and draft MCP cancellation, revocation and result parity remain open. Full process-tree RSS and rendering-only latency were outside the completed comparisons. Shared-peer metrics measure the adapter process and startup through completed fixture output. CLI and cockpit surfaces do not yet invoke SDK child-session cancellation.

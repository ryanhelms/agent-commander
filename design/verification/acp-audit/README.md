# ACP audit candidate

Baseline Commander is `a4663f1`, SDK `0.1.14`, and transport `0.1.0`. The integrated release pins are SDK `0.1.18` and transport `0.1.3`. Commander verifies the Go module archives against `go.sum`. The SDK distribution includes its own manifest and the Go, npm, and Python artifacts. The neighboring development checkouts were preserved.

## Matched workloads

Runs used Go 1.27.4 on an Apple silicon host with 10 logical CPUs. Short series use nearest-rank p95, which is the maximum for the sample sizes shown. Reported timings cover local fixture work unless the table says otherwise.

| Workload | Baseline | Candidate | Evidence |
| --- | --- | --- | --- |
| Loaded owner reply to ACP peer receipt, 30 panes | 229.94 ms median, 305.62 ms p95 | 11.64 ms median, 21.32 ms p95 | Two alternating runs, 12 decisions per variant. All 12 delivered. The peer stamps the receipt using the host monotonic clock. |
| Loaded owner reply to Console projection, 30 panes | 257.38 ms median, 422.96 ms p95 | 105.16 ms median, 122.10 ms p95 | Same paired runs. This observes the terminal-text projection. |
| First newline-free chunk without a message ID | 2,008–2,040 ms | 1.53–6.43 ms | Single-worker structured subscriber, three samples per variant. The later matched 30-pane test measured 2,020.40/2,050.13 ms median/p95 before and 4.02/9.26 ms after. All 12 candidate chunks arrived before terminal completion, compared with zero baseline chunks. |
| Unrelated read during a 500 ms credential check | 512.35–524.56 ms | 0.52–0.66 ms | Three samples per variant. |
| Stopped transcript with 2,048 records, paced | 16 loads, 32,768 updates, 1,545.6 ms median | One load, 2,048 updates, 89.4 ms median | Six samples per variant. Baseline unpaced replay failed. All three candidate burst runs completed. |
| Scoped live originals at 500 updates per second | Private polling received 1,158 and 1,626 of 2,000 | Continuous private streaming received 2,000 of 2,000 in each run | Both modes exercised on the same binary. The public feed stayed complete and attachment bytes stayed in the owner feed. |
| SSH, 512 KiB with 50 ms simulated RTT | About 0.60 MB/s | About 5.08 MB/s | Separate OpenSSH loopback run sent exactly 524,288 identical bytes in 294.34 ms legacy and 166.69 ms negotiated. |
| Idle transport receive allocation | About 1.08 MB/op | About 0.095 MB/op | Go microbenchmark. |
| Two workers through a compatible local peer | 203.9 ms median with isolated processes, 161.25 MiB adapter RSS | Shared 492.6 ms and 107.55 MiB. Isolated prewarm 494.3 ms and 161.09 MiB. | Five matched fixture runs. Both alternatives missed the startup latency gate. |

The paired incremental capacity test used 256-byte updates and a tool every fourth record. At 500 updates/s, both variants delivered every record. Median public SSE bytes increased by 4.3%, from 1.83 MB to 1.90 MB, with sampled service plus runner CPU of 0.100 and 0.090 seconds. At 50 updates/s, the 25 ms batching deadline increased median wire bytes by 43.8%, from 262,316 to 377,313, while delivering all 200 updates. Sampled CPU increased from 0.055 to 0.125 seconds at that rate. Each CPU sample had 10 ms granularity. Earlier candidates with the longer publication wait did not show the low-rate byte increase.

These comparisons include workstream builds. The sampled service and adapter RSS figures cover the indicated processes. Model inference, AppKit rendering, and full process-tree peak RSS need separate instrumentation. The [raw samples](samples/) preserve host load and binary digests where collected.

## Capability qualification

| Harness | Observed workflow | Startup selection |
| --- | --- | --- |
| Claude managed Opus, ACP adapter 0.109.1 | The installed account completed a synthetic v1 turn with Opus. The first v2 run found a configuration-ID mismatch. A managed Opus prompt passed over v2 with SDK 0.1.18. | v1 by default. Full v2 parity requires installed permissions, cancellation, reconnect, and history. |
| Codex ACP adapter 2.9.0 | The installed adapter returned the synthetic marker in both v1 and v2. | v1 by default while v2 parity and performance remain open. |
| Antigravity 1.5.13 | The installed adapter returned the marker in v1 even when offered v2. | v1. |
| Pi ACP translator 0.2.0 | The installed loopback fixture exercised addressed approval, original tool results, and reattachment. | v1. |

The existing SSH path remains available through `AGENT_COMMANDER_SSH_LINK=legacy`. The windowed link requires explicit negotiation by the endpoint. New local sessions accept these independent overrides:

- `AGENT_COMMANDER_ACP_PROTOCOL=v2`
- `AGENT_COMMANDER_ACP_BROKER=share` or `prewarm`
- `AGENT_COMMANDER_MCP_OVER_ACP=1`
- `AGENT_COMMANDER_ACP_SYSTEM_PROMPT=standard`
- `AGENT_COMMANDER_ACP_ELICITATION=1`
- `AGENT_COMMANDER_ACP_SESSION_ACTIVITY=on`

The MCP draft pin is `d1585b5932ec5ed2f7b02e298be92afae9462194`. Scoped draft invocation, cancellation, and rejection paths have deterministic coverage. An installed managed Claude Opus v2 run selected the standard system prompt and `acp` for Commander tools. It exchanged six `mcp/message` frames and completed a read-only `commander_status` call. Production MCP-over-ACP activation still requires installed-peer cancellation, revocation, and result parity. Receipt expiration was left open. Existing receipts continue to preserve duplicate-request safety.

## Reproduce

Use the exact release modules under `dist/sdk` in both checkouts. Benchmark the baseline and candidate serially on a single host. Use the current measurement scripts with both executables so that observations use the same timestamps.

```sh
python3 -B packaging/go-with-sdk.py build -o /tmp/agentctl-candidate ./cmd/agentctl
AGENT_COMMANDER_TEST_TMUX=1 AGENT_COMMANDER_TEST_INTEGRATION=1 \
  python3 -B packaging/go-with-sdk.py test -race -count=1 ./...
python3 -B design/verification/30-pane/measure.py \
  --agentctl /tmp/agentctl-candidate --projection incremental --output /tmp/candidate-30-pane.json
python3 -B packaging/go-with-sdk.py test ./internal/sshlink -run '^$' -bench . -benchmem
python3 -B design/verification/sdk-release/verify.py --consumer-only dist/sdk/agent-acp-0.1.18
make test-native
```

Use the repository's capacity, transcript, and CopilotKit fixtures for additional comparisons. Run the native app against a disposable local service when comparing the Pretty and Console states, coordinator wall, and PiP.

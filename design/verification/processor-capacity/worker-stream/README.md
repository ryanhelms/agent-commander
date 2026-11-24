# Per-worker AG-UI stream

One observer reconnects by its operation receipt, receives a retained conversation, then follows a stream of small assistant text updates until `RUN_FINISHED`. Each input adds 234 bytes of text, including a unique marker, and its own ACP source cursor. The benchmark advances when the sink has received both. It measures a reader that keeps up with the producer. [Go benchmark](../../../../internal/service/agui_run_benchmark_test.go)

The fixture uses the service's worker-output ingest, operation observation, text projection, SSE encoding, flushes and turn completion. The reader runs in process with one Go CPU. Fixture generation and release compilation occur outside the measurements. CPU and Go allocation totals cover the entire observation, including initial and terminal frames, ingestion, and the counting sink. Wire sizes count uncompressed SSE body bytes at the writer. TLS, socket framing, model execution, disk commits and rendering are outside this workload.

The baseline and candidate used the same release archive (SDK 0.1.7), toolchain (Go 1.27.4) and Apple M5. Each row uses the median of five process runs of 20 observations each. The run order alternated between builds. The old endpoint ignored the incremental query. The candidate's snapshot mode also ran in every trial for comparison. [Baseline trials](before.txt) · [Candidate trials](after.txt)

## Wire delivery

Both builds received the same `?projection=incremental` request. Every observation delivered every new marker and cursor and finished successfully. Active traffic below includes the periodic full snapshots. Startup and finish are shown separately.

| Retained rows + appends | Active full snapshots, before → after | SSE bytes per append, before → after | Startup bytes, both | Finish bytes, before → after |
| --- | ---: | ---: | ---: | ---: |
| 96 + 32 | 32 → 0 | 50,229 → 613 | 43,100 | 246 → 225 |
| 128 + 32 | 32 → 0 | 57,181 → 613 | 57,401 | 57,577 → 57,556 |
| 128 + 260 | 260 → 2 | 57,246 → 1,049 | 57,401 | 57,644 → 57,623 |

Every append in the 260-update run retired an older row. The candidate periodically replaced the client's visible window and restored the authoritative retained window at completion. The candidate's snapshot mode delivered the same number of active snapshots and the same wire bytes as the baseline in each workload.

## CPU and memory

Go's allocation counters measure all heap bytes and allocations during one complete observation. The operating-system RSS measurement is the median process peak across five separate fresh benchmark processes, including the Go runtime and test harness.

| Retained rows + appends | Process CPU ms/observation, before → after | Go MiB allocated/observation, before → after | Allocations/observation, before → after | Peak process RSS MiB, before → after |
| --- | ---: | ---: | ---: | ---: |
| 96 + 32 | 5.273 → 0.806 | 5.722 → 0.367 | 16,818 → 1,945 | 20.41 → 19.86 |
| 128 + 32 | 6.439 → 0.996 | 6.535 → 0.972 | 18,975 → 2,481 | 20.33 → 20.09 |
| 128 + 260 | 47.819 → 6.474 | 50.267 → 5.373 | 154,703 → 11,313 | 21.73 → 22.28 |

At 1,000 appends per second in repeated 260-update observations, the measured CPU and allocation totals imply about 0.025 CPU cores and 20.7 MiB/s of Go allocation traffic for this single-observer workload. The wire total including startup and finish implies about 1.42 MiB/s. This is a rate conversion from the measured costs. A running deployment also spends CPU and memory on its provider, network, authorization, clients and concurrent work. The long trial's median peak RSS increased by 0.55 MiB even as cumulative allocation traffic decreased by 89.3%.

## Reproduce

Build a test binary from each implementation with the same benchmark file present. Run each binary five times with the same flags.

```sh
sdk_version=$(go list -m -f '{{.Version}}' agent-acp.local/sdks/go)
sdk_release="dist/sdk/agent-acp-${sdk_version#v}"
python3 packaging/go-with-sdk.py "$sdk_release" test -c \
  -o /tmp/commander-worker-stream.test ./internal/service
/tmp/commander-worker-stream.test -test.run='^$' \
  -test.bench='^BenchmarkAGUIWorkerObserve$' -test.benchtime=20x -test.cpu=1 -test.benchmem
```

For an independent peak-RSS sample on macOS, run a fresh process for each workload and mode. The following command selects one of the six cases. The raw memory samples report bytes. [RSS samples](peak-rss.tsv)

```sh
/usr/bin/time -l /tmp/commander-worker-stream.test -test.run='^$' \
  -test.bench='^BenchmarkAGUIWorkerObserve$/^128_retained$/^260_appends$/^incremental$' \
  -test.benchtime=20x -test.cpu=1
```

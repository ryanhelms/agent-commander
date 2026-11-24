# ACP processor capacity

The [after-change comparison](after/README.md) repeats these workloads against the typed processor and both workspace stream formats.

The source publisher comparison measures private ACP delivery through 67-record bursts, pairs it with service and runner CPU and RSS, and reports allocations for plain and correlated updates. [Source publisher measurements](after/source-publisher.md)

The per-worker operation benchmark measures the separate SSE route used by the CopilotKit connector. It tracks delivery, periodic window snapshots and final replay boundaries. [Per-worker results](worker-stream/README.md)

An input event in this benchmark is one ACP `session/update` notification. Each event contains a unique marker. The producer schedules arrivals at a fixed rate. A reader counts a marker as delivered when it appears in the selected worker’s structured AG-UI message content or tool arguments. It can see the same marker in many successive workspace snapshots. Each reader counts it once. This measures the path from synthetic ACP stdio through a real Commander runner, service and Unix-socket AG-UI workspace subscription.

## Processor and stream contract

The runner serializes bounded batches in order. Each upload carries a stream ID and sequence number. The receiver acknowledges an identical retry once and verifies the predecessor when a sender takes over. Filling the batch triggers a flush and backpressure. If transient retries are exhausted, the next successful publication identifies a gap. Native previews stay in memory. Legacy output and its accepted receipt are written together.

The owner workspace feed negotiates incremental delivery with `GET /v1/ag-ui/events?projection=incremental`. The first event is an AG-UI `STATE_SNAPSHOT`. Apply subsequent `STATE_DELTA` operations in order. In this projection each worker has a `messages` array and an `outputChunks` array. Joining the chunks yields the bounded terminal tail. A slow subscriber that falls behind the 64-frame or 4 MiB retention window receives a replacement snapshot with `metadata.commander.reason = "workspace_delta_expired"`. A new subscription starts from current state. The established URL continues to serve the scalar `output` and whole-run patches used by existing clients.

The service exposes typed activity metadata and a worker-scoped source reference for richer updates. An authorized app can inspect a source record with `readHistory({source: "live", view: "acp"})` on the CopilotKit connector, or with `GET /v1/workers/{worker}/history?source=live&view=acp`. The view dispatches the 20 session-update variants defined by the pinned Go ACP library. Unknown members stay in the original update object. Portable observations and gaps retain their source identity. Supplemental capture covers the updates the SDK exposes after session binding and is bounded by worker-scoped retention. An observation cursor identifies a record and the page's `nextCursor` continues traversal.

## Reproduce

Run these commands on a Mac with tmux, from the repository root. The driver starts one fresh Commander service and runner for each rate and trial. It uses private temporary state, a private socket and a separate tmux server. The generated data is synthetic.

```sh
sdk_version=$(go list -m -f '{{.Version}}' agent-acp.local/sdks/go)
sdk_release="dist/sdk/agent-acp-${sdk_version#v}"
python3 -B design/verification/processor-capacity/measure.py --agentctl dist/agentctl --rates 10 50 100 --seconds 8 --idle 3 --size 256 --observers 1 --trials 2 --output /tmp/commander-text.json
python3 -B design/verification/processor-capacity/measure.py --agentctl dist/agentctl --rates 50 --seconds 30 --idle 5 --size 256 --observers 1 --output /tmp/commander-text-30s.json
python3 -B design/verification/processor-capacity/two_workers.py --agentctl dist/agentctl --rate 50 --seconds 8 --idle 3 --size 256 --trials 2 --output /tmp/commander-two-workers.json
python3 packaging/go-with-sdk.py "$sdk_release" test -run '^$' -bench '^BenchmarkAGUIWorkspaceUpdate$' -benchmem -benchtime=250ms -count=3 ./internal/service
```

The JSON reports offered and delivered events, missing IDs, ACP stdio bytes, AG-UI JSON bytes per reader, idle and loaded CPU time, and sampled median and peak resident memory (RSS) per process. The measured window includes the final delivery marker and sampling delay. The emission rate describes the producer itself. CPU in cores is cumulative user and system CPU seconds divided by wall seconds. The driver excludes tmux, the synthetic harness, observers and the native UI from the resource totals. Summing process RSS can count shared pages more than once. Slow-reader recovery, cold replay, relay traffic and long-duration memory retention need their own measurements.

## Single-session rate sweep

Two trials per rate used one fresh service, one runner and one reader. Each update carried 256 bytes of text including the unique marker and a newline. The producer sustained 9.99–10.00, 49.99 and 99.97–99.99 updates/s respectively. The CPU column sums service and runner CPU seconds and divides by the measured wall time. Peak RSS is shown separately for each process. [Raw trials](text-256.json)

| Input updates/s | Unique markers delivered per trial | Delivered/s including final drain | CPU cores | Service peak RSS (MiB) | Runner peak RSS (MiB) |
| ---: | --- | ---: | ---: | ---: | ---: |
| 10 | 80/80, 80/80 | 9.5 | 0.020–0.023 | 20.1–20.5 | 16.4–18.8 |
| 50 | 400/400, 400/400 | 37.1–48.2 | 0.031–0.036 | 21.4–22.0 | 20.6–21.2 |
| 100 | 642/800, 644/800 | 68.8–73.4 | 0.051–0.054 | 20.7–21.6 | 19.9–21.1 |

At 50 updates/s the two processes used 0.75–0.83 ms of CPU per delivered event, including background work. Sampled idle peak RSS across these six fresh trials ranged from 17.3–17.7 MiB for the service and 18.9–19.4 MiB for the runner. Variability in the drain and sampling interval matters in short trials. These data establish an initial workload comparison. They do not establish a sustained production rate or a memory reservation.

A longer 30-second run at 50/s produced **1,500 markers, of which 1,427 reached the structured AG-UI reader and all 1,500 appeared in the terminal-output field.** Across the measured 30.55 seconds, service and runner used 0.024 and 0.018 cores respectively. Peak sampled RSS was 21.28 MiB and 20.52 MiB. The AG-UI reader received 19,021,212 JSON bytes from 672,000 ACP stdio bytes, a 28.3× expansion over the measured window. The two short trials at this same rate had complete delivery. A brief successful trial cannot establish a release target. [Longer trial](text-256-30s.json)

The 100/s diagnostic trial observed all 800 markers in the worker’s terminal-output field and 642 in the structured AG-UI messages. A structured synchronization-gap notice appeared. The runner retains 12 structured records between nominal 150 ms flushes and evicts the oldest record on overflow. For newline-delimited inputs that each produce one structured record, 15 can arrive during that interval at 100/s. A responsive CPU and a healthy process can coexist with missing structured data. [Diagnostic trial](gap-100.json) · [Runner buffering](../../../internal/provider/runner.go)

For capacity planning at a fixed event mix, take the additional busy CPU-seconds above an equal-duration idle baseline and divide by delivered events. Multiply by the desired delivery rate and add the process baseline to estimate occupied cores **within the measured lossless range**. Provisioning then needs headroom measured against acceptable control latency, burst duration and queue age. For memory, measure resident baseline by session and subscriber count, then add the observed working-set increase under realistic retention and lag. An RSS plateau and a repeated burst/recovery test are prerequisites for setting a memory limit.

### Payload size, tool updates and fan-out

Each variation below had a configured rate of 50/s for 400 events. The CPU column covers the full measured window, including drain. In the four-reader trial the producer took 8.34 seconds and the measurement window lasted 15.28 seconds. The readers were separate SSE connections in one Python process. These single-trial comparisons reveal sensitivity to workload and observer behavior. The 4 KiB trial captured only three process samples, which limits the precision of its memory peak.

| Input and readers | Measured producer rate | Structured markers per reader | Terminal-output markers per reader | CPU cores | Peak RSS, service / runner (MiB) | ACP in / AG-UI out (KiB/s) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| [256 B text, four readers](fanout-4.json) | 47.84 | 362/400 each | 400/400 each | 0.029 | 24.7 / 19.9 | 11.5 / 855.7 |
| [256 B, every fourth event a tool update, one reader](mixed-50.json) | 49.97 | 400/400 | 400/400 | 0.057 | 20.9 / 19.8 | 21.3 / 507.3 |
| [4 KiB text, one reader](text-4k.json) | 49.97 | 290/400 | 304/400 | 0.044 | 26.4 / 21.8 | 194.0 / 1,821.2 |

AG-UI output bytes include every replacement snapshot or delta seen across all readers. A marker missing from a reader's observed preview locates a delivery gap for that mode. A harness history reader may still supply the original record.

### Two busy sessions on one owner

Two independently registered synthetic ACP sessions each emitted 400 text records at 50/s into one Commander run. A single workspace subscriber observed both. Their emission windows overlapped for 7.98 and 7.99 seconds in the two trials. The shared service and both runners consumed 0.096–0.099 cores in total. Peak sampled RSS was 23.1–23.3 MiB for the service and 19.5–20.0 MiB per runner. The first trial delivered 377 + 375 = 752 of 800 structured records. The second delivered all 800. At the same aggregate offered rate, one worker delivered 642–644 of 800 in the eight-second rate sweep. Independent sessions had their own runner buffers and consumed more process resources. All processes ran on the same Mac. [Two-worker trials](two-by-50.json)

## Serialization and allocation

The Go benchmark changes one 256-byte text record in one worker. It runs the existing workspace projection, computes the AG-UI patch, and encodes it for one subscriber. Each run contains up to ten workers. The patch replaces the run containing the changed worker. The figures below are medians across three Go benchmark repetitions on an Apple M5 using the pinned 0.1.7 SDK. Allocated bytes measure cumulative allocations per operation. RSS measures resident memory at an instant. [Benchmark samples](projection-benchmark.txt)

| Workers | Records per worker | AG-UI JSON bytes per update | Allocated bytes per update | Allocations per update |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 4 | 2,575 | 7,987 | 29 |
| 1 | 128 | 72,163 | 200,223 | 406 |
| 30 | 4 | 23,896 | 147,864 | 472 |
| 30 | 128 | 719,776 | 6,120,918 | 11,799 |

## Architecture implications

1. **Order by session.** Give each bound session one component responsible for applying updates in order, including setup, active turns, idle changes and disconnect. Use the ACP wire schema at the adapter boundary. A source identity and position link the typed event to authorized original data. Version the independently generated SDK observation and AG-UI projections. A schema-coverage test should fail when a newly pinned method, discriminator or field lacks a mapping, a source-only disposition for an open value, or an explicit capability decision. ACP’s optional message ID and tool-update field presence belong in that test. [ACP v1 schema](https://agentclientprotocol.com/protocol/v1/schema) · [Canonical Data Model](https://www.enterpriseintegrationpatterns.com/patterns/messaging/CanonicalDataModel.html)
2. **Separate tool observation and invocation.** A harness tool reports its own arguments, progress and result. An app frontend tool has an authorized invocation that can accept one correlated result. Use typed AG-UI activities or state for observational progress wherever executable tool messages would trigger a client handler. Verify the pinned CopilotKit runtime with matching and wildcard tool names, during-stream resolution and reconnection. [AG-UI event types](https://docs.ag-ui.com/concepts/events)
3. **Share projection work.** Build the changed worker’s projection once per revision and visibility scope. Serve immutable results to authorized viewers. Use full snapshots for attachment and recovery. The existing Swift decoder accepts whole-run replacements. A finer patch requires a compatible client or stream version. Separate volatile native preview ingestion from the whole-database rollback serialization and file sync used for durable mutations. Preserve durable receipt, lifecycle transition and legacy-worker writes. Keep media in scoped history with explicit gaps and give approval replies capacity under load. [Claim Check](https://www.enterpriseintegrationpatterns.com/patterns/messaging/StoreInLibrary.html) · [Service transaction](../../../internal/service/api.go) · [Durable state](../../../internal/service/native_session.go)
4. **Scale independent sessions and readers separately.** Slack assigns each channel to one server and fans its events out via subscribed gateways. Figma’s published design assigned each active document one process and recovered a client from fresh state on reconnect. For Commander, keep one authoritative writer per session, fence the old owner on handoff, and place independent sessions across workers or hosts when measurement warrants it. A local CLI stays attached to its owning host. Replicated relay gateways also need to route a request to the process holding that host’s outbound tunnel. [Slack Engineering](https://slack.engineering/real-time-messaging/) · [Figma Engineering](https://www.figma.com/blog/how-figmas-multiplayer-technology-works/)
5. **Bound lag and measure it.** Use count and byte limits per reader, measure oldest outstanding event age, and give a slow reader a checkpoint plus cursor-based recovery. Preserve gaps and pending requests across reconnect. For hosted capacity, track incoming bytes, outgoing bytes, CPU, connection count, queue age and delivery fidelity. Recheck these measurements after protocol or projection changes. [NATS slow consumers](https://docs.nats.io/learn/resilient-clients/slow-consumers) · [Google SRE on capacity and overload](https://sre.google/sre-book/handling-overload/)

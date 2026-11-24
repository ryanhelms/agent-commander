# Typed ACP processor measurements

**Each patched feed delivered all 7,660 input records in the 13 archived trials.** Counting each reader independently yielded 8,860 expected markers per feed, with zero missing or unexpected IDs. The terminal tail and structured messages agreed for every measured reader. At 50 updates/s for 30 seconds, the incremental feed delivered 1,500/1,500 records using 0.014 cores and 1,141,986 AG-UI JSON bytes. The archived baseline delivered 1,427/1,500 using 0.042 cores and 19,021,212 bytes.

Peak memory depended on the workload. In that 30-second trial, sampled service RSS moved from 21.3 to 21.1 MiB and runner RSS moved from 20.5 to 21.3 MiB. With 4 KiB events the incremental trial delivered 400/400 instead of 290/400, with service RSS up from 26.4 to 27.3 MiB and runner RSS up from 21.8 to 24.6 MiB. Readers using the existing feed also recovered complete delivery across this matrix and retain its whole-run wire format.

The archived workloads were repeated with the same fixed input rates, payloads, mix, session counts and SSE reader counts. Each trial used a fresh service and runner on the same Apple M5 Mac as the baseline. The incremental run negotiated granular AG-UI state patches. The compatibility run used the original workspace route and reconstructed the same bounded message and output state. Thirteen trials were run for each feed format, sequentially. The observer checked unique markers independently for each worker and reader. A workspace frame can carry multiple input records.

CPU is combined service and runner CPU seconds divided by elapsed seconds including final drain. For repeated trials the CPU figure uses the sum of CPU seconds and wall seconds. Peak RSS is the highest sampled service value or the highest individual runner value across trials. RSS excludes tmux, CLI adapters and the benchmark reader. MiB uses 1,048,576 bytes. The host was shared, sampling intervals varied, and the longest trial was 30 seconds. These measurements characterize the staged implementation and workload.

After adding scoped permission and turn-result records in SDK 0.1.10, the same 100 updates/s, 256-byte, single-reader incremental workload delivered 800/800 markers in each of two eight-second trials. Combined service and runner CPU was 0.0142 and 0.0144 cores. Peak service RSS was 21.9 and 21.5 MiB, and peak runner RSS was 21.1 and 20.9 MiB. The reader received 585,702 and 580,920 JSON bytes. The earlier incremental pair also delivered all 1,600 markers and used 1,159,790 JSON bytes in total. These trials exercise text streaming on one Mac. [0.1.10 trials](incremental/sdk-0.1.10-100.json) · [Earlier comparison](incremental/text-256.json)

## Installed macOS backend with SDK 0.1.14

The installed backend repeated the complete 13-trial incremental matrix. All 7,660 input events produced their expected 8,860 reader observations, and the structured messages and terminal output agreed. No observer reported a synchronization gap or unexpected ID. The executable was copied byte for byte out of the installed app and used a private service and tmux server. [Raw trials](sdk-0.1.14-workspace/) · [Scoped source trials](source-publisher.md#installed-macos-backend-with-sdk-0114)

| Workload | Combined CPU cores | CPU s per 1,000 delivered input events | Peak RSS, service / busiest runner (MiB) | AG-UI JSON bytes across trials and readers |
| --- | ---: | ---: | ---: | ---: |
| 256 B text, 10/s | 0.006 | 0.688 | 17.8 / 16.3 | 115,328 |
| 256 B text, 50/s | 0.017 | 0.363 | 20.2 / 19.4 | 580,300 |
| 256 B text, 100/s | 0.027 | 0.294 | 20.7 / 20.3 | 1,168,344 |
| 50/s, four readers | 0.015 | 0.325 | 21.0 / 19.9 | 1,168,356 |
| 4 KiB text, 50/s | 0.034 | 0.750 | 23.9 / 23.6 | 3,626,411 |
| 50/s, 30 seconds | 0.017 | 0.340 | 20.3 / 20.6 | 1,138,189 |
| Two sessions at 50/s each | 0.030 | 0.319 | 21.2 / 20.7 | 1,163,910 |

The 30-second trial used 94.0% fewer JSON bytes and 0.025 fewer CPU cores than the original baseline. Compared with the first patched rerun, its wire bytes were nearly unchanged and combined CPU increased from 0.014 to 0.017 cores. These measurements include drain and exclude the native app, model inference, observers and tmux.

## Reproduce

```sh
sdk_version=$(go list -m -f '{{.Version}}' agent-acp.local/sdks/go)
sdk_release="dist/sdk/agent-acp-${sdk_version#v}"
mkdir -p /tmp/commander-processor
python3 packaging/go-with-sdk.py "$sdk_release" build -o /tmp/commander-processor/agentctl ./cmd/agentctl
python3 -B design/verification/processor-capacity/repeat.py --agentctl /tmp/commander-processor/agentctl --projection incremental --output-dir /tmp/commander-processor/incremental
python3 -B design/verification/processor-capacity/repeat.py --agentctl /tmp/commander-processor/agentctl --projection legacy --output-dir /tmp/commander-processor/legacy
python3 packaging/go-with-sdk.py "$sdk_release" test -run '^$' -bench '^BenchmarkAGUIWorkspaceUpdate$' -benchmem -benchtime=250ms -count=3 ./internal/service
```

## Delivery, CPU and memory

Columns list the archived baseline, the patched incremental feed and the patched compatibility feed, in that order. Counts sum unique observations per reader and trial. Four readers observing 400 records gives 1,600 expected observations. CPU and RSS cover the service and runner processes.

| Workload | Structured observations, baseline / incremental / compatibility | Expected | CPU cores, baseline / incremental / compatibility | Peak service MiB, baseline / incremental / compatibility | Peak runner MiB, baseline / incremental / compatibility |
| --- | ---: | ---: | ---: | ---: | ---: |
| 256 B text, 10/s | 160 / 160 / 160 | 160 | 0.021 / 0.004 / 0.007 | 20.5 / 19.4 / 21.4 | 18.8 / 19.6 / 19.3 |
| 256 B text, 50/s | 800 / 800 / 800 | 800 | 0.033 / 0.011 / 0.013 | 22.0 / 21.6 / 23.1 | 21.2 / 21.6 / 21.4 |
| 256 B text, 100/s | 1,286 / 1,600 / 1,600 | 1,600 | 0.052 / 0.018 / 0.020 | 21.6 / 22.1 / 22.6 | 21.0 / 22.0 / 22.0 |
| 100/s diagnostic | 642 / 800 / 800 | 800 | 0.049 / 0.020 / 0.019 | 21.1 / 20.7 / 22.4 | 20.9 / 20.5 / 21.8 |
| 50/s, four readers | 1,448 / 1,600 / 1,600 | 1,600 | 0.029 / 0.014 / 0.017 | 24.7 / 20.4 / 23.2 | 19.9 / 19.9 / 21.0 |
| 50/s, 25% tool updates | 400 / 400 / 400 | 400 | 0.057 / 0.017 / 0.018 | 20.9 / 21.4 / 22.1 | 19.8 / 20.6 / 21.0 |
| 4 KiB text, 50/s | 290 / 400 / 400 | 400 | 0.044 / 0.030 / 0.039 | 26.4 / 27.3 / 28.9 | 21.8 / 24.6 / 24.5 |
| 50/s, 30 seconds | 1,427 / 1,500 / 1,500 | 1,500 | 0.042 / 0.014 / 0.014 | 21.3 / 21.1 / 23.1 | 20.5 / 21.3 / 21.4 |
| Two sessions at 50/s each | 1,552 / 1,600 / 1,600 | 1,600 | 0.098 / 0.020 / 0.044 | 23.3 / 22.6 / 25.0 | 20.0 / 21.6 / 20.1 |

## Serialized AG-UI JSON

Bytes sum JSON event payloads across all readers and repetitions, excluding SSE framing. The compatibility feed continues to replace whole runs to support existing decoders.

| Workload | Baseline bytes | Incremental bytes | Compatibility bytes | Incremental reduction vs baseline |
| --- | ---: | ---: | ---: | ---: |
| 256 B text, 10/s | [2,812,695](../text-256.json) | [115,424](incremental/text-256.json) | [2,812,695](legacy/text-256.json) | 95.9% |
| 256 B text, 50/s | [9,215,527](../text-256.json) | [581,987](incremental/text-256.json) | [9,193,993](legacy/text-256.json) | 93.7% |
| 256 B text, 100/s | [10,373,925](../text-256.json) | [1,159,790](incremental/text-256.json) | [10,661,409](legacy/text-256.json) | 88.8% |
| 100/s diagnostic | [5,169,844](../gap-100.json) | [579,369](incremental/gap-100.json) | [5,371,755](legacy/gap-100.json) | 88.8% |
| 50/s, four readers | [13,390,694](../fanout-4.json) | [1,156,264](incremental/fanout-4.json) | [18,422,888](legacy/fanout-4.json) | 91.4% |
| 50/s, 25% tool updates | [4,461,520](../mixed-50.json) | [380,462](incremental/mixed-50.json) | [4,799,331](legacy/mixed-50.json) | 91.5% |
| 4 KiB text, 50/s | [16,099,579](../text-4k.json) | [3,577,233](incremental/text-4k.json) | [28,752,630](legacy/text-4k.json) | 77.8% |
| 50/s, 30 seconds | [19,021,212](../text-256-30s.json) | [1,141,986](incremental/text-256-30s.json) | [20,635,850](legacy/text-256-30s.json) | 94.0% |
| Two sessions at 50/s each | [34,081,616](../two-by-50.json) | [1,166,279](incremental/two-by-50.json) | [36,487,884](legacy/two-by-50.json) | 96.6% |

Patched binary SHA-256 `e5370ae58911b8c543281c4dc18ab0290dffdb2f3ccc80989e12fef40db367bf`. Baseline SHA-256 `83bc7a8ec41698afaf0841360017709bdaa0615fa30caf5bcb9fd2c8503ca1b7`. Both link the pinned 0.1.7 session SDK.

## Allocation benchmark

The same 256-byte record correction was applied in all four workspace sizes. Each iteration changes the record. The candidate runs the production workspace reconciliation and emits the resulting patch. Values are medians of three repetitions. Allocated bytes are cumulative allocations during one update. Resident memory is measured separately in the live trials.

| Workers × records each | Wire bytes, before → after | Allocated bytes, before → after | Allocations, before → after | Elapsed µs, before → after |
| --- | ---: | ---: | ---: | ---: |
| 1 × 4 | 2,575 → 725 | 7,987 → 4,268 | 29 → 39 | 33.1 → 2.6 |
| 1 × 128 | 72,163 → 731 | 200,223 → 55,112 | 406 → 423 | 993.7 → 19.0 |
| 30 × 4 | 23,896 → 725 | 147,864 → 10,820 | 472 → 132 | 641.5 → 22.7 |
| 30 × 128 | 719,776 → 731 | 6,120,918 → 61,650 | 11,799 → 516 | 31,187.7 → 55.3 |

Absolute bytes allocated per correction fell at every workspace size. Allocation counts increased for the one-worker cases. The larger workspaces benefited from reusing unchanged worker projections. [Baseline samples](../projection-benchmark.txt) · [Patched samples](projection-benchmark.txt)

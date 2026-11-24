# Private ACP source delivery under bursts

At 100 scheduled updates per second, the previous runner retained 264 of 1,600 original ACP updates across two mixed trials. The batched runner retained all 1,600 in order. Both delivered all 1,600 markers in the public AG-UI workspace. The owner read original text and tool payloads through the selected worker’s live history and compared their private sequence numbers with their content. Both new trials had zero gaps, duplicate sequences, unexpected sequences or mismatches. No literal private sequence marker appeared in the workspace SSE. [Previous results](incremental/source-queue-rich-before-100.json) · [New results](incremental/source-queue-rich-after-100.json)

Each trial used a fresh Commander service, runner, Unix socket and tmux server on the same Apple M5 Mac. A synthetic stdio ACP peer sent 800 updates with 256 bytes of text each over an eight-second schedule. The mixed workload released groups of 67 when the last item in each group became due. Every fourth item was a tool progress update. Each text chunk carried a message ID, and all 800 items carried a private sequence in ACP `_meta`. Both binaries received 429,600 ACP bytes per mixed trial. The owner followed opaque history page cursors every 250 ms during sampling to observe more records than the 128-entry retention window holds. The private and public delivery fences both had to arrive. [Emitter](../fixture_acp.py) · [Sampling and validation](../measure.py)

| Trial | Public delivery | Private delivery | Service CPU s | Runner CPU s | Combined % of one core | Service peak RSS MiB | Runner peak RSS MiB |
|---|---|---|---|---|---|---|---|
| Plain, previous | 800 / 800 each | — | 0.03, 0.04 | 0.11, 0.13 | 1.67, 2.00 | 21.4, 21.8 | 20.5, 21.4 |
| Plain, batched | 800 / 800 each | — | 0.04, 0.04 | 0.18, 0.19 | 2.58, 2.62 | 21.9, 20.4 | 21.2, 20.4 |
| Mixed, previous | 800 / 800 each | 136 / 800, 128 / 800 | 0.07, 0.11 | 0.07, 0.09 | 1.66, 2.26 | 23.9, 22.7 | 23.7, 22.1 |
| Mixed, batched | 800 / 800 each | 800 / 800 each | 0.11, 0.12 | 0.08, 0.09 | 2.25, 2.47 | 23.6, 23.0 | 23.6, 22.9 |

The plain control used the archived single-observer incremental workload, individual scheduled sends, a three-second idle sample and 358,400 ACP bytes per trial. Its service and runner used more combined CPU on the batched build in this pair of fresh runs. The archived baseline on the identical previous binary had recorded 0.12 CPU seconds combined per trial. Process CPU times are sampled to 0.01 seconds. These two trials per build measure the observed workload and do not establish a sustained throughput limit. The service samples include the private history reads in the mixed runs. CPU and RSS exclude the Python peer and readers, tmux, native app and model inference. [Previous plain rerun](incremental/source-queue-plain-before-100.json) · [New plain rerun](incremental/source-queue-plain-100.json) · [Archived plain baseline](incremental/sdk-0.1.10-100.json)

The batched build used 0.238 and 0.263 combined service-and-runner CPU seconds per thousand successfully delivered original records in the mixed trials. The previous build used 1.03 and 1.56 seconds per thousand delivered originals while dropping most of the offered workload. Working-set peaks for both processes stayed below 24 MiB in all four mixed trials.

## Final 0.1.12 measurements

All 4,800 public markers arrived across six fresh trials of the installed 0.1.12 build. In the rich runs the private reader verified all 3,200 full payloads in sequence, with zero gaps, duplicates, unexpected IDs or invalid originals. Every eight-second trial used the same 100/s schedule and 256-byte payloads. Each mixed run sent 600 text chunks and 200 tool updates in groups of 67. The two mixed workloads each emitted exactly 429,600 measured ACP bytes per trial.

| Private marker location | Public and private originals per trial | Service CPU s | Runner CPU s | Combined % of one core | Service peak RSS MiB | Runner peak RSS MiB |
|---|---|---|---|---|---|---|
| Plain text control | 800 public each | 0.04, 0.03 | 0.12, 0.08 | 1.90, 1.30 | 21.6, 22.9 | 21.6, 22.7 |
| Inside the update | 800 public and 800 private each | 0.08, 0.08 | 0.06, 0.06 | 1.67, 1.65 | 24.4, 25.1 | 24.3, 24.5 |
| On the outer method params | 800 public and 800 private each | 0.10, 0.10 | 0.10, 0.09 | 2.35, 2.23 | 25.5, 25.5 | 26.2, 26.4 |

The inner workload placed the private sequence in `update._meta`. The service returned all 800 originals per trial as extensions. The outer workload moved the same sequence to `params._meta`. Its private reader verified each normalized tool or text observation’s `sourceRecord`, native cursor, session and turn against the original params. A separate passive notice carried the final private fence in an extension. All four rich trials used 55 scoped history page reads apiece. The literal private marker was absent from every recorded workspace event. The raw reports include the exact executable digest and separate idle samples. [Plain](incremental/sdk-0.1.12-plain-100.json) · [Inner marker](incremental/sdk-0.1.12-inner-100.json) · [Outer marker](incremental/sdk-0.1.12-outer-100.json)

## Release 0.1.13 compared with 0.1.12

Both binaries delivered 4,800 of 4,800 public markers across six trials apiece. The private reader verified 3,197 of 3,200 originals on 0.1.13 and 3,200 of 3,200 on 0.1.12. The first 0.1.13 inner trial missed sequences 671–673 and reported that earlier records had expired from the retained window. The second inner trial and both outer trials delivered all 800 private originals in order. All received originals passed content validation. The reader saw no duplicate or unexpected private ID and no private sequence marker in the workspace stream.

The service retains at most 128 records per worker. The peer releases groups of 67 and the reader polls every 250 ms, so a delayed read can outlive part of the retained history. The recorded gap identifies eviction from the live history. [0.1.12 plain](incremental/sdk-0.1.12-plain-100.json) · [0.1.12 inner](incremental/sdk-0.1.12-inner-100.json) · [0.1.12 outer](incremental/sdk-0.1.12-outer-100.json) · [0.1.13 plain](incremental/sdk-0.1.13-plain-100.json) · [0.1.13 inner](incremental/sdk-0.1.13-inner-100.json) · [0.1.13 outer](incremental/sdk-0.1.13-outer-100.json)

Each cell contains the two fresh process trials in order. Each trial offered 800 updates over eight seconds at 100/s. CPU seconds and peak resident memory cover the Commander service and runner during the measured load window.

| Marker location | SDK | Service CPU s | Runner CPU s | Combined % of one core | Service peak RSS MiB | Runner peak RSS MiB |
|---|---|---:|---:|---:|---:|---:|
| Plain text | 0.1.12 | 0.04, 0.03 | 0.12, 0.08 | 1.90, 1.30 | 21.6, 22.9 | 21.6, 22.7 |
| Plain text | 0.1.13 | 0.04, 0.04 | 0.16, 0.14 | 2.36, 2.13 | 21.5, 21.7 | 21.5, 21.5 |
| Inside the update | 0.1.12 | 0.08, 0.08 | 0.06, 0.06 | 1.67, 1.65 | 24.4, 25.1 | 24.3, 24.5 |
| Inside the update | 0.1.13 | 0.14, 0.11 | 0.10, 0.07 | 2.76, 2.13 | 23.5, 23.2 | 23.7, 23.1 |
| On the outer method params | 0.1.12 | 0.10, 0.10 | 0.10, 0.09 | 2.35, 2.23 | 25.5, 25.5 | 26.2, 26.4 |
| On the outer method params | 0.1.13 | 0.13, 0.13 | 0.11, 0.11 | 2.79, 2.89 | 24.5, 24.2 | 24.7, 25.0 |

Across each pair of trials, combined CPU seconds per thousand delivered public markers went from 0.169 to 0.237 for plain text. Per thousand verified private originals, the inner workload went from 0.175 to 0.263 and the outer workload from 0.244 to 0.300. The fixture and input byte counts matched the earlier trials. CPU sampling resolves 0.01 seconds. These observations apply to the measured rate, payload sizes and one observer.

## Release 0.1.13 with a 256-record live history window

The six trials on the updated Commander binary delivered 4,800 of 4,800 public markers and 3,200 of 3,200 private originals. Both inner trials recovered all 800 originals. All four rich trials delivered them in order with zero gaps, duplicates, unexpected IDs or invalid payloads. The private sequence marker stayed out of the public workspace stream. The previous binary delivered 3,197 of 3,200 originals in the same workloads.

Commander retained up to 256 records per worker for these trials, with the existing 4 MiB per-worker and 32 MiB aggregate limits. The SDK and transport pins, 100/s schedule, burst size, reader interval and page limit matched the initial 0.1.13 measurements. The CPU-per-thousand column uses the two trials’ combined CPU time and the number of verified originals for rich workloads or delivered public markers for the plain control.

| Marker location | Service CPU s | Runner CPU s | Combined % of one core | Service peak RSS MiB | Runner peak RSS MiB | Combined CPU s per 1,000 deliveries |
|---|---:|---:|---:|---:|---:|---:|
| Plain text | 0.02, 0.03 | 0.10, 0.10 | 1.40, 1.55 | 22.4, 21.5 | 21.7, 21.5 | 0.156 |
| Inside the update | 0.10, 0.14 | 0.08, 0.10 | 2.15, 2.89 | 23.9, 23.0 | 23.0, 22.8 | 0.263 |
| On the outer method params | 0.20, 0.20 | 0.17, 0.16 | 4.30, 4.30 | 24.2, 24.7 | 24.3, 24.4 | 0.456 |

Compared with 0.1.12, combined CPU seconds per thousand deliveries changed from 0.169 to 0.156 for plain text, 0.175 to 0.263 for inner metadata and 0.244 to 0.456 for outer metadata. Across all six trials, sampled service and runner RSS peaked at 24.7 and 24.4 MiB respectively, compared with 25.5 and 26.4 MiB on 0.1.12. The reports include the binary digest, idle samples and load duration. [Plain trial data](incremental/sdk-0.1.13-retention-plain-100.json) · [Inner trial data](incremental/sdk-0.1.13-retention-inner-100.json) · [Outer trial data](incremental/sdk-0.1.13-retention-outer-100.json)

## Installed macOS backend with SDK 0.1.14

The same six trials on a byte-identical copy of the installed Commander backend delivered 4,800 of 4,800 public markers and 3,200 of 3,200 scoped originals. The scoped reader verified original values and order with zero gaps, duplicates, invalid payloads or unexpected markers. Private sequence markers stayed out of the workspace feed. The binary used the pinned SDK 0.1.14 and transport 0.1.0. The reports record the binary digest.

| Workload at 100/s | Public workspace JSON, 0.1.13 → 0.1.14 | Combined CPU s per 1,000 deliveries, 0.1.13 → 0.1.14 | 0.1.14 peak RSS, service / runner |
| --- | ---: | ---: | ---: |
| [Plain text](incremental/sdk-0.1.14-plain-100.json) | 1,166,085 → 1,165,228 | 0.156 → 0.300 | 20.6 / 20.7 MiB |
| [Metadata inside the update](incremental/sdk-0.1.14-inner-100.json) | 1,872,128 → 1,848,511 | 0.263 → 0.238 | 23.0 / 22.4 MiB |
| [Metadata on the outer method params](incremental/sdk-0.1.14-outer-100.json) | 1,888,149 → 1,893,943 | 0.456 → 0.363 | 24.5 / 24.6 MiB |

The two plain-text trials used 0.48 combined CPU seconds, up from 0.25 in the archived 0.1.13 pair. The private-history workloads used less CPU in this rerun. These are short, separately scheduled measurements on the same Mac. They show the change in the measured workload without isolating a code path or establishing a sustained capacity limit.

### Alternating rerun of the exact plain-text binaries

The earlier plain-text increase did not recur at that magnitude. Six alternating runs on the same Mac used SHA-256-verified copies of the exact 0.1.13 and 0.1.14 executables. Each run sent 2,000 256-byte updates at 100/s with one incremental reader and a fresh service and runner. All 12,000 markers reached the structured messages and terminal output with no unexpected IDs or synchronization gaps. [Trial order, hashes and samples](incremental/paired-013-014-plain-100.json)

| Measure | SDK 0.1.13 build | Installed SDK 0.1.14 build |
| --- | ---: | ---: |
| Combined CPU seconds per 1,000 events, median | 0.260 | 0.270 |
| Combined CPU seconds per 1,000 events, range | 0.210–0.275 | 0.155–0.275 |
| AG-UI JSON bytes per event, median | 734.9 | 734.4 |
| Highest sampled RSS, service / runner (MiB) | 21.1 / 21.7 | 21.4 / 22.0 |

The observed CPU ranges overlap. The benchmark measures whole executable builds on a shared Mac, so it cannot attribute the small median difference to the SDK or identify the cause of the earlier short-run difference. To repeat an individual trial, use the plain-text command below with the selected binary, `--seconds 20` and `--trials 1`. Use independent output files and alternate the binaries in the recorded order.

## Publisher allocations

The Go benchmark feeds 16 pre-encoded updates per iteration through the production source callback and correlation lookup. The mixed case drains the admitted records in a batch of 16. The fixtures use the same 256-byte text size and 3-to-1 correlated text/tool mix as the process trials. Medians over three 350 ms samples on the batched source are shown below. The isolated loop excludes SDK decoding, HTTP, service storage and UI rendering. All 24 SDK Go sources and module files in the development checkout matched the local 0.1.10 archive. [Benchmark source](../source_publisher_benchmark_test.go.in) · [Raw allocation and timing samples](source-publisher-benchmark.txt)

| Input | ns per update | Allocated bytes per update | Allocations per update |
|---|---:|---:|---:|
| Plain text | 1,624 | 304 | 2 |
| Correlated text and tool updates | 4,389 | 1,227 | 18.75 |

## Reproduce

Both original binary SHA-256 digests are recorded in the reports. Run the following from the repository root with each corresponding binary and a separate output path.

```sh
python3 -B design/verification/processor-capacity/measure.py --agentctl "$candidate_binary" --rates 100 --seconds 8 --idle 3 --size 256 --observers 1 --projection incremental --trials 2 --output /tmp/source-plain.json
python3 -B design/verification/processor-capacity/measure.py --agentctl "$candidate_binary" --rates 100 --seconds 8 --idle 3 --size 256 --observers 1 --projection incremental --trials 2 --tool-every 4 --rich-source --burst 67 --output /tmp/source-rich.json
python3 -B design/verification/processor-capacity/measure.py --agentctl "$candidate_binary" --rates 100 --seconds 8 --idle 3 --size 256 --observers 1 --projection incremental --trials 2 --tool-every 4 --outer-source --burst 67 --output /tmp/source-outer.json
```

The allocation probe uses a Go test overlay to compile the benchmark inside the provider package.

```sh
benchmark_overlay=$(mktemp)
python3 - "$benchmark_overlay" <<'PY'
import json, pathlib, sys
root = pathlib.Path.cwd()
fixture = root / "design/verification/processor-capacity/source_publisher_benchmark_test.go.in"
virtual_test = root / "internal/provider/capacity_source_benchmark_test.go"
pathlib.Path(sys.argv[1]).write_text(json.dumps({"Replace": {str(virtual_test): str(fixture)}}))
PY
go test -overlay "$benchmark_overlay" -run '^$' -bench '^BenchmarkCapacitySourcePublisher$' -benchmem -benchtime=350ms -count=3 ./internal/provider
```

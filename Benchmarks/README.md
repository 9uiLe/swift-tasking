# Tasking benchmarks

This executable measures public operations in Release, independently of the correctness
test runner. It requires macOS 13+ and a Swift 6 toolchain. Run from the repository root:

```sh
swift run --package-path Benchmarks -c release TaskingBenchmarks
```

The executable prints one JSON line per measurement. A row identifies the scenario,
metric, run count (`size`), operation count (`operations`), sample, and elapsed
`milliseconds` for the whole batch. Each scenario has one discarded warmup.

## Workloads

| Workload | Measurements |
|---|---|
| Store | Start, lifetime hit/miss/count, duplicate rejection, lifetime cancellation, drain, idle wait |
| Runner | Sequential Action execution and terminal outcomes |
| Slot | Repeated replacement and drain |

Store batches use one Action ID, up to 100 IDs, or a distinct ID per run. IDs are
constructed before timing. Every run uses `.screenBound`; hit queries search for
`.screenBound`, and miss queries search for `.appBound`.

Store admission and cancellation are synchronous MainActor batches before operations
get a turn to run. Drain includes task scheduling and the gate fixture. Slot operations
can reach their gate while replacements are being admitted. Network services, business
logic, and cancellation handlers in a real application are outside these workloads.

| Executable option | Default | Meaning |
|---|---|---|
| `--sizes` | `100,1000,10000` | Run counts to measure |
| `--samples` | `7` | Measured repetitions after warmup |
| `--queries` | `1000` | Queries and duplicate-admission attempts per Store batch |
| `--scenario` | `all` | `all`, `store`, `runner`, or `slot` |

## Compare source snapshots

```sh
python3 Benchmarks/compare.py --baseline-ref HEAD --output Benchmarks/results/comparison
```

`baseline` is the selected git revision; `working` is a snapshot of the checkout's
Package.swift, Sources, and Tests. Both are built separately using the same benchmark
source. The script alternates process order across seven samples, running one measured
repetition plus warmup per scenario in each process. Use `--baseline-path` for a saved
source directory instead of a git revision.

The script accepts `--sizes`, `--samples`, and `--queries`. The comparison requires
both sources to support the public APIs exercised by the benchmark.

| Output | Contents |
|---|---|
| `metadata.json` | Environment, source hashes, baseline revision/path, snapshot and binary locations |
| `samples.jsonl` | Raw timing rows, with the source label and process sample number |
| `summary.json` | Medians per metric and `working / baseline` ratios |
| `memory.json` | Whole-process peak resident memory for each process |
| `baseline-build.log`, `working-build.log` | Build diagnostics |

Snapshots remain in the temporary directory printed by the script. Source hashes include
Package.swift and Sources, including source comments. Preserve measured identities when
documentation or code changes. Apple's `/usr/bin/time -l` reports peak RSS in bytes;
this includes the Swift runtime and benchmark fixture, not just Tasking allocations.

## Interpret measurements

Use the same hardware and toolchain for both builds. Do not run timing comparisons
alongside builds, tests, profiling, or other deliberate CPU-intensive work. Report
workload and variation with the medians.

Hit and miss queries have different costs: a hit may return immediately, while a miss
must scan every tracked run. Report them separately. Absolute latency thresholds do
not belong in CI correctness tests. See [performance characteristics](../docs/performance.md)
for recorded measurements and the implications for application workloads.

## Profile with Instruments

Build before launching Time Profiler:

```sh
swift build --package-path Benchmarks -c release
xcrun xctrace record --template 'Time Profiler' --time-limit 10s \
  --output /tmp/tasking.trace --launch -- \
  Benchmarks/.build/release/TaskingBenchmarks \
  --sizes 10000 --samples 200 --queries 1
```

One query per batch emphasizes admission, cancellation, and completion. Higher query
counts emphasize lookups. Time-limited launches may terminate the executable; verify
that the saved trace can be exported. Inclusive CPU sample percentages can overlap,
and captures of different durations are not direct speedup measurements. Keep profiler
observations separate from uninstrumented wall-clock timings.

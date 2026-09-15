#!/usr/bin/env python3
"""Compare isolated Release builds, retaining raw samples and the measured sources."""
import argparse
import datetime
import hashlib
import re
import json
import platform
import shutil
import statistics
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run(command, **kwargs):
    return subprocess.run(command, check=True, text=True, **kwargs)


def snapshot(source, destination):
    destination.mkdir()
    shutil.copy2(source / "Package.swift", destination)
    for name in ("Sources", "Tests"):
        shutil.copytree(source / name, destination / name)


def build(root, log):
    shutil.copytree(ROOT / "Benchmarks", root / "Benchmarks",
                    ignore=shutil.ignore_patterns(".build", ".swiftpm", "results", "__pycache__"),
                    dirs_exist_ok=True)
    with log.open("w") as output:
        run(["swift", "build", "--package-path", str(root / "Benchmarks"), "-c", "release",
             "-Xswiftc", "-warnings-as-errors"], stdout=output, stderr=subprocess.STDOUT)
    result = run(["swift", "build", "--package-path", str(root / "Benchmarks"), "-c", "release",
                  "--show-bin-path"], capture_output=True)
    return Path(result.stdout.strip()) / "TaskingBenchmarks"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--baseline-ref", default="HEAD")
    source.add_argument("--baseline-path", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--samples", default=7, type=int)
    parser.add_argument("--sizes", default="100,1000,10000")
    parser.add_argument("--queries", default=1000, type=int)
    args = parser.parse_args()
    if args.samples <= 0 or args.queries <= 0:
        parser.error("samples and queries must be positive")
    args.output.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="tasking-performance-"))
    baseline = work / "baseline"
    working = work / "working"
    if args.baseline_path:
        snapshot(args.baseline_path.resolve(), baseline)
        revision = str(args.baseline_path.resolve())
    else:
        revision = run(["git", "rev-parse", args.baseline_ref], cwd=ROOT, capture_output=True).stdout.strip()
        baseline.mkdir()
        archive = work / "baseline.tar"
        with archive.open("wb") as output:
            subprocess.run(["git", "archive", revision], cwd=ROOT, stdout=output, check=True)
        run(["tar", "-xf", str(archive), "-C", str(baseline)])
    snapshot(ROOT, working)
    binaries = {name: build(path, args.output / (name + "-build.log"))
                for name, path in [("baseline", baseline), ("working", working)]}
    def source_hash(path):
        digest = hashlib.sha256()
        for file in [path / "Package.swift", *sorted((path / "Sources").rglob("*.swift"))]:
            digest.update(str(file.relative_to(path)).encode())
            digest.update(file.read_bytes())
        return digest.hexdigest()

    metadata = {
        "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "source_hashes": {"baseline": source_hash(baseline), "working": source_hash(working)},
        "baseline": revision, "snapshots": str(work), "platform": platform.platform(),
        "cpu": run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True).stdout.strip(),
        "swift": run(["swift", "--version"], capture_output=True).stdout.strip(),
        "samples": args.samples, "sizes": args.sizes, "queries": args.queries,
        "binaries": {key: str(value) for key, value in binaries.items()},
        "method": "Separate Release processes, alternating order, one discarded warmup per scenario."
    }
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(metadata), flush=True)
    rows = []
    memory = []
    with (args.output / "samples.jsonl").open("w") as output:
        for sample in range(args.samples):
            order = ["baseline", "working"] if sample % 2 == 0 else ["working", "baseline"]
            for name in order:
                result = run(["/usr/bin/time", "-l", str(binaries[name]), "--samples", "1",
                              "--sizes", args.sizes, "--queries", str(args.queries)],
                             capture_output=True, timeout=180)
                match = re.search(r"(\d+)\s+maximum resident set size", result.stderr)
                if not match:
                    raise RuntimeError("Could not read maximum resident set size")
                memory.append(dict(build=name, sample=sample, maximum_rss_bytes=int(match.group(1))))
                for line in result.stdout.splitlines():
                    row = json.loads(line)
                    row.update(build=name, sample=sample)
                    rows.append(row)
                    output.write(json.dumps(row) + "\n")
            output.flush()
            print("Finished sample", sample + 1, "of", args.samples, flush=True)
    (args.output / "memory.json").write_text(json.dumps(memory, indent=2) + "\n")
    grouped = {}
    for row in rows:
        key = (row["scenario"], row["metric"], row["size"], row["operations"])
        grouped.setdefault(key, {}).setdefault(row["build"], []).append(row["milliseconds"])
    summary = []
    for (scenario, metric, size, operations), values in sorted(grouped.items()):
        medians = {name: statistics.median(samples) for name, samples in values.items()}
        summary.append(dict(scenario=scenario, metric=metric, size=size, operations=operations,
                            baseline_ms=medians["baseline"], working_ms=medians["working"],
                            ratio=medians["working"] / medians["baseline"]))
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()

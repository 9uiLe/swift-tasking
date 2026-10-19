#!/usr/bin/env python3
"""現行 Release と標準実装の測定値・実行条件・プロセス最大 RSS を保存する。"""
import argparse
import datetime
import hashlib
import json
import math
import platform
import re
import statistics
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run(command, **kwargs):
    return subprocess.run(command, check=True, text=True, **kwargs)


def source_hash():
    digest = hashlib.sha256()
    paths = [ROOT / "Package.swift", *sorted((ROOT / "Sources").rglob("*.swift")),
             ROOT / "Benchmarks/Package.swift", *sorted((ROOT / "Benchmarks/Sources").rglob("*.swift"))]
    for file in paths:
        digest.update(str(file.relative_to(ROOT)).encode())
        digest.update(file.read_bytes())
    return digest.hexdigest()


def percentile(values, fraction):
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower, upper = math.floor(position), math.ceil(position)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--samples", default=7, type=int)
    parser.add_argument("--sizes", default="1,8,32,128,1000,10000")
    parser.add_argument("--queries", default=1000, type=int)
    parser.add_argument("--scenario", default="all", choices=["all", "store", "runner", "slot", "ownership"])
    args = parser.parse_args()
    try:
        sizes = [int(size) for size in args.sizes.split(",")]
    except ValueError:
        parser.error("sizes は正の整数のカンマ区切りにしてください")
    if args.samples <= 0 or args.queries <= 0 or not all(size > 0 for size in sizes):
        parser.error("samples・queries・sizes は正の値にしてください")
    args.output.mkdir(parents=True, exist_ok=False)
    before = source_hash()
    with (args.output / "build.log").open("w") as log:
        run(["swift", "build", "--package-path", str(ROOT / "Benchmarks"), "-c", "release",
             "-Xswiftc", "-strict-concurrency=complete", "-Xswiftc", "-warnings-as-errors"],
            stdout=log, stderr=subprocess.STDOUT)
    bin_path = run(["swift", "build", "--package-path", str(ROOT / "Benchmarks"), "-c", "release",
                    "--show-bin-path"], capture_output=True).stdout.strip()
    if source_hash() != before:
        raise RuntimeError("ビルド中にソースが変更されました")
    metadata = {
        "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "source_hash": before,
        "source_hash_scope": "ルートとBenchmarksのPackage.swift、および両Sourcesの相対パスと内容（コメントを含む）",
        "platform": platform.platform(),
        "cpu": run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True).stdout.strip(),
        "swift": run(["swift", "--version"], capture_output=True).stdout.strip(),
        "samples": args.samples, "sizes": sizes, "queries": args.queries, "scenario": args.scenario,
        "method": "独立したReleaseプロセス。各プロセスで1回ウォームアップ後に1サンプル。Taskingと標準対照の実行順をプロセスごとに反転。"
    }
    rows, memory = [], []
    with (args.output / "samples.jsonl").open("w") as output:
        for sample in range(args.samples):
            order = "tasking-first" if sample % 2 == 0 else "native-first"
            result = run(["/usr/bin/time", "-l", str(Path(bin_path) / "TaskingBenchmarks"),
                          "--samples", "1", "--sizes", args.sizes, "--queries", str(args.queries),
                          "--scenario", args.scenario, "--order", order], capture_output=True, timeout=180)
            match = re.search(r"(\d+)\s+maximum resident set size", result.stderr)
            if not match:
                raise RuntimeError("最大常駐メモリを読み取れませんでした")
            memory.append(int(match.group(1)))
            identities = set()
            for line in result.stdout.splitlines():
                row = json.loads(line)
                identity = (row["scenario"], row["metric"], row["size"], row["operations"], row["unit"])
                if identity in identities or not math.isfinite(row["value"]):
                    raise RuntimeError("重複または有限数値でないサンプルです")
                identities.add(identity)
                row.update(sample=sample, order=order)
                rows.append(row)
                output.write(json.dumps(row) + "\n")
            if not identities:
                raise RuntimeError("測定値がありません")
            if sample == 0:
                expected = identities
            elif identities != expected:
                raise RuntimeError("プロセス間で測定条件が一致しません")
            output.flush()
            print(f"サンプル {sample + 1}/{args.samples} 完了", flush=True)
    if source_hash() != before:
        raise RuntimeError("測定中にソースが変更されました")
    grouped = {}
    for row in rows:
        key = (row["scenario"], row["metric"], row["size"], row["operations"], row["unit"])
        grouped.setdefault(key, []).append(row["value"])
    summary = []
    for (scenario, metric, size, operations, unit), values in sorted(grouped.items()):
        summary.append(dict(scenario=scenario, metric=metric, size=size, operations=operations, unit=unit,
                            samples=len(values), median=statistics.median(values), minimum=min(values),
                            maximum=max(values), p95=percentile(values, .95), p99=percentile(values, .99)))
    report = {"schema_version": 2, "metadata": metadata, "summary": summary,
              "process_maximum_rss_bytes": {"samples": memory, "median": statistics.median(memory),
                                            "minimum": min(memory), "maximum": max(memory)}}
    (args.output / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"report": str(args.output / "report.json"), "source_hash": before}, ensure_ascii=False))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Summarize Bomu animation delays without exporting trace environment data."""

import argparse
import json
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path


THRESHOLD_NS = 33_000_000
SCHEMAS = ("potential-hangs", "hitches-updates")


def table_rows(path: Path, expected_schema: str) -> list[dict[str, tuple[str | None, str | None]]]:
    root = ET.parse(path).getroot()
    node = root.find("node")
    if node is None or node.find("schema") is None:
        raise ValueError(f"Missing {expected_schema} table")
    if node.find("schema").get("name") != expected_schema:
        raise ValueError(f"Unexpected schema for {expected_schema}")
    columns = [column.findtext("mnemonic") for column in node.find("schema").findall("col")]
    values_by_id: dict[str, tuple[str | None, str | None]] = {}
    rows = []
    for row in node.findall("row"):
        values = []
        for element in row:
            reference = element.get("ref")
            if reference is not None:
                if reference not in values_by_id:
                    raise ValueError(f"Unknown XML value reference in {expected_schema}")
                value = values_by_id[reference]
            else:
                value = (element.get("fmt"), element.text)
                identifier = element.get("id")
                if identifier is not None:
                    values_by_id[identifier] = value
            values.append(value)
        if len(values) != len(columns):
            raise ValueError(f"Column mismatch in {expected_schema}")
        rows.append(dict(zip(columns, values)))
    return rows


def duration_ns(row: dict[str, tuple[str | None, str | None]]) -> int:
    raw = row["duration"][1]
    if raw is None:
        raise ValueError("Missing raw duration")
    return int(raw)


def summarize(hangs_path: Path, updates_path: Path, process: str = "Bomu") -> dict:
    hangs = [
        row for row in table_rows(hangs_path, "potential-hangs")
        if process in (row["thread"][0] or "")
    ]
    updates = [
        row for row in table_rows(updates_path, "hitches-updates")
        if (row["process"][0] or "").startswith(f"{process} (")
    ]
    unique_updates = {
        (row["start"][1], duration_ns(row), row["process"][0], row["display"][0])
        for row in updates
    }
    long_updates = [duration for _, duration, _, _ in unique_updates if duration > THRESHOLD_NS]
    hang_types = Counter(row["hang-type"][0] or "Unknown" for row in hangs)
    return {
        "process": process,
        "threshold_ms": 33,
        "main_thread_delays": {
            "count": len(hangs),
            "types": dict(sorted(hang_types.items())),
            "max_ms": round(max((duration_ns(row) for row in hangs), default=0) / 1_000_000, 2),
        },
        "display_updates": {
            "raw_rows": len(updates),
            "unique_events": len(unique_updates),
            "above_threshold": len(long_updates),
            "max_above_threshold_ms": round(max(long_updates, default=0) / 1_000_000, 2),
        },
    }


def export_table(trace: Path, schema: str, output: Path) -> None:
    query = f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'
    subprocess.run(
        ["xcrun", "xctrace", "export", str(trace), "--xpath", query, "--output", str(output)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path, help="completed .trace bundle")
    parser.add_argument("--output", type=Path, help="sanitized JSON summary")
    parser.add_argument("--remove-trace", action="store_true",
                        help="remove an input trace located under this repo's .build/benchmarks")
    args = parser.parse_args()
    trace = args.trace.resolve()
    if not trace.is_dir() or trace.suffix != ".trace" or args.trace.is_symlink():
        parser.error("expected a non-symlink .trace directory")
    if args.remove_trace:
        benchmark_root = (Path(__file__).resolve().parent.parent / ".build/benchmarks").resolve()
        if not trace.is_relative_to(benchmark_root):
            parser.error("--remove-trace only accepts a trace under .build/benchmarks")
    try:
        with tempfile.TemporaryDirectory(prefix="bomu-hitches-") as temporary:
            paths = {schema: Path(temporary) / f"{schema}.xml" for schema in SCHEMAS}
            for schema, path in paths.items():
                export_table(trace, schema, path)
            result = summarize(paths["potential-hangs"], paths["hitches-updates"])
        result["trace_name"] = trace.name
        output = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(output)
        else:
            print(output, end="")
    finally:
        # An incomplete trace still contains the recorded process environment.
        if args.remove_trace:
            shutil.rmtree(trace)


if __name__ == "__main__":
    main()

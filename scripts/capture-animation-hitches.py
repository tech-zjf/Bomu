#!/usr/bin/env python3
"""Bound a local Animation Hitches recording and keep only its sanitized summary."""

import argparse
import json
import os
import resource
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
BENCHMARKS = ROOT / ".build" / "benchmarks"
SUMMARIZER = ROOT / "scripts" / "summarize-animation-hitches.py"


def tree_size(directory: Path) -> int:
    total = 0
    if not directory.exists():
        return total
    for base, _, filenames in os.walk(directory):
        for filename in filenames:
            try:
                total += (Path(base) / filename).stat().st_size
            except FileNotFoundError:
                pass
    return total


def stop_group(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


def limit_trace_file_size(maximum_bytes: int) -> None:
    # xctrace can write a large file between total-directory-size polls. Child
    # processes inherit this per-file limit; the directory poll still handles
    # traces split across multiple files.
    resource.setrlimit(resource.RLIMIT_FSIZE, (maximum_bytes, maximum_bytes))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True, help="verified Bomu process ID")
    parser.add_argument("--seconds", type=int, default=8, help="recording time, 3–60 seconds")
    parser.add_argument("--window-seconds", type=int, default=5,
                        help="retain only this many final seconds")
    parser.add_argument("--timeout-seconds", type=int, default=45,
                        help="maximum wall time, including trace finalization")
    parser.add_argument("--max-mib", type=int, default=768,
                        help="single-file hard limit and total trace polling threshold")
    args = parser.parse_args()
    if args.pid <= 0 or not 3 <= args.seconds <= 60:
        parser.error("expected a positive PID and a 3–60 second recording")
    if not 1 <= args.window_seconds <= args.seconds:
        parser.error("window must be between 1 second and recording duration")
    if args.timeout_seconds <= args.seconds or args.max_mib < 64:
        parser.error("timeout must exceed recording duration; max-mib must be at least 64")

    BENCHMARKS.mkdir(parents=True, exist_ok=True)
    name = f"animation-{time.strftime('%Y%m%d-%H%M%S')}-{args.pid}"
    trace = BENCHMARKS / f"{name}.trace"
    summary = BENCHMARKS / f"{name}-summary.json"
    if trace.exists() or summary.exists():
        parser.error("output already exists")
    command = [
        "xcrun", "xctrace", "record", "--no-prompt", "--template", "Animation Hitches",
        "--attach", str(args.pid), "--time-limit", f"{args.seconds}s",
        "--window", f"{args.window_seconds}s", "--output", str(trace),
    ]
    maximum_bytes = args.max_mib * 1024 * 1024
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, start_new_session=True,
                               preexec_fn=lambda: limit_trace_file_size(maximum_bytes))
    print(f"Recording {args.seconds}s for Bomu PID {args.pid}; "
          f"{args.timeout_seconds}s wall limit, {args.max_mib} MiB per-file limit "
          "and total-size polling threshold.", flush=True)
    started = time.monotonic()
    failure = None
    try:
        while process.poll() is None:
            if time.monotonic() - started > args.timeout_seconds:
                failure = "finalization timeout"
                break
            if tree_size(trace) > maximum_bytes:
                failure = "raw trace size limit"
                break
            time.sleep(0.5)
        if failure is not None:
            stop_group(process)
            print(f"No measurement: {failure}; raw trace removed.", file=sys.stderr)
            return 1
        if process.returncode == -signal.SIGXFSZ:
            print("No measurement: single trace file size limit; raw trace removed.",
                  file=sys.stderr)
            return 1
        if process.returncode != 0 or not trace.is_dir():
            print(f"No measurement: xctrace exited {process.returncode}; raw trace removed.",
                  file=sys.stderr)
            return 1
        result = subprocess.run(
            [sys.executable, str(SUMMARIZER), str(trace), "--output", str(summary),
             "--remove-trace"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=30, check=False,
        )
        if result.returncode != 0 or not summary.is_file():
            print("No measurement: trace export failed; raw trace removed.", file=sys.stderr)
            return 1
        report = json.loads(summary.read_text())
        print(json.dumps({"summary": str(summary),
                          "main_thread_delays": report["main_thread_delays"],
                          "display_updates": report["display_updates"]},
                         ensure_ascii=False), flush=True)
        return 0
    except subprocess.TimeoutExpired:
        print("No measurement: trace export timed out; raw trace removed.", file=sys.stderr)
        return 1
    finally:
        stop_group(process)
        if trace.is_dir() and not trace.is_symlink():
            shutil.rmtree(trace)


if __name__ == "__main__":
    raise SystemExit(main())

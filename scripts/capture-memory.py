#!/usr/bin/env python3
"""Record bounded memory samples for an already running canonical Debug Bomu."""

import argparse
import ctypes
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parent.parent
EXECUTABLE = ROOT / '.build/DerivedData/Build/Products/Debug/Bomu.app/Contents/MacOS/Bomu'


class Usage(ctypes.Structure):
    # Darwin sys/resource.h, RUSAGE_INFO_V0. Size and order are the native ABI.
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            'user_time', 'system_time', 'idle_wakeups', 'interrupt_wakeups',
            'pageins', 'wired_bytes', 'resident_bytes', 'footprint_bytes',
            'start_abstime', 'exit_abstime')]


class ProcessReader:
    def __init__(self, pid):
        self.pid = pid
        self.lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        self.lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.lib.proc_pidpath.restype = ctypes.c_int
        self.lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.lib.proc_pid_rusage.restype = ctypes.c_int
        self.identity = None

    def read(self):
        buffer = ctypes.create_string_buffer(4096)
        if self.lib.proc_pidpath(self.pid, buffer, len(buffer)) <= 0:
            raise OSError(ctypes.get_errno(), 'Cannot read target executable')
        if Path(os.fsdecode(buffer.value)).resolve() != EXECUTABLE.resolve():
            raise ValueError('PID does not belong to canonical Debug Bomu')
        usage = Usage()
        if self.lib.proc_pid_rusage(self.pid, 0, ctypes.byref(usage)) != 0:
            raise OSError(ctypes.get_errno(), 'Cannot read target memory')
        identity = (bytes(usage.uuid), usage.start_abstime)
        if self.identity is not None and self.identity != identity:
            raise ValueError('Target process identity changed; recording stopped')
        self.identity = identity
        return usage


def capture_map(reader, output):
    reader.read()  # Recheck PID identity immediately before inspecting regions.
    try:
        result = subprocess.run(['/usr/bin/vmmap', '-summary', str(reader.pid)],
                                capture_output=True, text=True, timeout=15, check=False)
        reader.read()
        if result.returncode != 0:
            return {'captured': False, 'reason': 'vmmap failed', 'exitCode': result.returncode}
        (output / 'threshold-vmmap.txt').write_text(result.stdout)
        return {'captured': True, 'file': 'threshold-vmmap.txt'}
    except subprocess.TimeoutExpired:
        return {'captured': False, 'reason': 'vmmap exceeded 15 seconds'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--seconds', type=int, default=120)
    parser.add_argument('--interval', type=float, default=1)
    parser.add_argument('--threshold-mib', type=int, default=2048,
                        help='capture vmmap once above this footprint; not a pass/fail limit')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('macOS is required')
    if args.pid <= 0 or not 1 <= args.seconds <= 3600:
        parser.error('positive PID and 1–3600 seconds required')
    if not 0.5 <= args.interval <= 30 or args.threshold_mib < 1:
        parser.error('interval must be 0.5–30 seconds and threshold positive')
    reader = ProcessReader(args.pid)
    # Refuse wrong/exited processes before creating any output.
    reader.read()
    output = ROOT / '.build/benchmarks' / f'memory-{time.strftime("%Y%m%d-%H%M%S")}-{args.pid}'
    output.mkdir(parents=True, exist_ok=False)
    report = {'schemaVersion': 1, 'pid': args.pid, 'requestedSeconds': args.seconds,
              'intervalSeconds': args.interval, 'thresholdMiB': args.threshold_mib,
              'scope': 'External proc_pid_rusage; no window control, heap dump, media paths or environment',
              'completed': False, 'samples': 0, 'maximumFootprintBytes': 0,
              'maximumResidentBytes': 0, 'thresholdCapture': None}
    started = time.monotonic()
    print(output, flush=True)
    try:
        with (output / 'samples.jsonl').open('x') as stream:
            while True:
                usage = reader.read()
                elapsed = time.monotonic() - started
                row = {'recordedAt': datetime.now(timezone.utc).isoformat(),
                       'elapsedSeconds': elapsed, 'residentBytes': usage.resident_bytes,
                       'physicalFootprintBytes': usage.footprint_bytes}
                stream.write(json.dumps(row) + '\n')
                stream.flush()
                report['samples'] += 1
                report['maximumFootprintBytes'] = max(report['maximumFootprintBytes'], usage.footprint_bytes)
                report['maximumResidentBytes'] = max(report['maximumResidentBytes'], usage.resident_bytes)
                if usage.footprint_bytes >= args.threshold_mib * 2**20 and report['thresholdCapture'] is None:
                    report['thresholdCapture'] = capture_map(reader, output)
                remaining = args.seconds - (time.monotonic() - started)
                if remaining <= 0:
                    report['completed'] = True
                    break
                time.sleep(min(args.interval, remaining))
    except (OSError, ValueError) as error:
        report['failure'] = str(error)
    except KeyboardInterrupt:
        report['failure'] = 'Interrupted by operator'
    finally:
        report['elapsedSeconds'] = time.monotonic() - started
        (output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report), flush=True)
    return 0 if report['completed'] else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)

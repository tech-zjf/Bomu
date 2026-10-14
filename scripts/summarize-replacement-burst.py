#!/usr/bin/env python3
"""Validate production-model rapid replacement and cancellation evidence."""
import json
from pathlib import Path
import sys


def main():
    root = Path(sys.argv[1])
    report = json.loads((root / 'window-lifecycle.json').read_text())
    result = report.get('replacementBurst') or {}
    cancelled = result.get('cancelledRequestIDs', [])
    replacements = result.get('replacementRequestIDs', [])
    final_id = result.get('finalRequestID')
    playing = result.get('playing') or {}
    after_seek = result.get('afterSeek') or {}
    shutdown = report.get('shutdown') or {}
    valid = (
        report.get('schemaVersion') == 4 and report.get('completed')
        and len(cancelled) == 12 and len(set(cancelled)) == 12
        and len(replacements) == 24 and len(set(replacements)) == 24
        and replacements[-1] == final_id and final_id > max(cancelled)
        and result.get('stoppedBeforeReplacement') and result.get('finalRequestPlayed')
        and result.get('seekRecovered')
        and (result.get('before') or {}).get('idle') is True
        and playing.get('coreCreationCount') == 1 and playing.get('renderContextCreationCount') == 1
        and playing.get('videoOutputConfigured') is True and playing.get('videoFrameCount', 0) > 0
        and after_seek.get('videoFrameCount', 0) > playing.get('videoFrameCount', 0)
        and shutdown.get('coreAlive') is False and shutdown.get('renderContextAlive') is False
    )
    if not valid:
        raise SystemExit('Rapid replacement report is incomplete or failed its acceptance checks.')
    print('Production-model burst: cancelled 12 opens, issued 24 replacements, final TS request sought and resumed successfully.')
    print(f'Native session creations: {playing["coreCreationCount"]} core / {playing["renderContextCreationCount"]} render context.')
    print(f'After shutdown: coreAlive={shutdown["coreAlive"]}, renderContextAlive={shutdown["renderContextAlive"]}.')


if __name__ == '__main__':
    main()

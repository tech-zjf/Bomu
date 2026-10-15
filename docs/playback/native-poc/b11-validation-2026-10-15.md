# B11 native playback validation — 2026-10-15

## Completed in this run

The first recorded app-host XCTest suite passed 8/8 cases in one Bomu host window. A later 2026-10-15 rerun expanded the native integration coverage and passed 10/10; the result bundle was subsequently removed from local `.build`, so per-test activity logs are not retained in this report. The suite exercised real libmpv playback, pause/seek, rapid replacement, unavailable-media recovery, saved-position restoration in a new native session, shutdown while opening, native resource release, and local thumbnail extraction. This is integration evidence, not the full 60-sample/100-switch/30-minute B11 acceptance.

The 60-sample licensed suite and 33-minute synchronization fixture both passed manifest verification. The `BomuBenchmark` target builds with the shared playback and media-library domain contracts. Its first build exposed and fixed two target-specific issues: the benchmark omitted media-library protocol value types, and Xcode 27 does not import `TASK_POWER_INFO_V2_COUNT`; the Mach message count now follows the actual struct layout.

## Prior full-length run and regression fix

An earlier B11 report, `.build/benchmarks/20261014-202046/window-lifecycle.json`, contains 60 media results, 100 acknowledged switches, and 180 visible soak checkpoints spanning 1,800.1 seconds on display 1. The same window stayed visible, and shutdown released both native resources. The only media failure was `50-mpeg2-pal-program-stream.mpg`: paused precise seek timed out. The production mpv configuration now uses the general `hr-seek-demuxer-offset=0.5` option so demuxers that return a later keyframe can read earlier and decode forward; the targeted real-libmpv regression `testMPEG2ProgramStreamPausedAbsoluteSeekSettlesAtRequestedPosition` subsequently passed in the 8/8 app-host suite. This establishes a targeted fix, while a complete 60-sample rerun remains necessary to confirm the whole suite against it.

## Long-run attempt

The current single-window B11 benchmark was attempted on the built-in display (display ID 1). macOS reported the session locked, so its active-and-visible-window gate timed out before opening media. This attempt recorded no sample playback, file switches, or soak interval. It exited through its failure path and recorded `coreAlive: false` and `renderContextAlive: false` after shutdown. The local report is `.build/benchmarks/20261015-001601/window-lifecycle.json`.

## Remaining acceptance

After Screen 1 is unlocked, rerun `./scripts/benchmark-dev.sh --b11-suite` in its one benchmark window. Confirm the MPEG-2 PS seek now passes; review all 60 media results, all 100 acknowledged file switches, the 30-minute synchronized playback checkpoints, and final stopped-render/resource counters. Sleep recovery is only verified if a real sleep/wake occurs during the run; do not synthesize it by changing display or desktop spaces. Human picture and audio review remains separate from muted automation.

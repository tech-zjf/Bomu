import AppKit
import Darwin

/// Development-only executable. The shipping app has no benchmark entry point.
@main
@MainActor
enum BenchmarkApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = BenchmarkAppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        let quit = NSMenuItem(title: "Quit Bomu Playback Benchmark",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = app
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        app.mainMenu = menu
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class BenchmarkAppDelegate: NSObject, NSApplicationDelegate {
    private var task: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        task = Task {
            do {
                let environment = ProcessInfo.processInfo.environment
                guard let mediaPath = environment["BOMU_BENCHMARK_MEDIA"],
                      let outputPath = environment["BOMU_BENCHMARK_OUTPUT"] else {
                    throw BenchmarkError.failed("Run scripts/benchmark-dev.sh to supply media and output paths")
                }
                switch environment["BOMU_BENCHMARK_MODE"] {
                case "playback":
                    guard let syncPath = environment["BOMU_BENCHMARK_SYNC_MEDIA"] else {
                        throw BenchmarkError.failed("Missing synchronization fixture")
                    }
                    NSApplication.shared.activate()
                    try await PlaybackBenchmark().run(
                        media: URL(fileURLWithPath: mediaPath, isDirectory: true),
                        syncMedia: URL(fileURLWithPath: syncPath), output: URL(fileURLWithPath: outputPath))
                case "single-window", "media-suite", "display-transitions":
                    guard let rawScenario = environment["BOMU_BENCHMARK_MODE"],
                          let scenario = WindowScenario(rawValue: rawScenario) else {
                        throw BenchmarkError.failed("Unknown window scenario")
                    }
                    guard let cycles = Int(environment["BOMU_BENCHMARK_CYCLES"] ?? "100"), (1...100).contains(cycles),
                          let soak = Double(environment["BOMU_BENCHMARK_SOAK_SECONDS"] ?? "120"),
                          soak.isFinite, (0...600).contains(soak),
                          let preview = Double(environment["BOMU_BENCHMARK_PREVIEW_SECONDS"] ?? "0"),
                          preview.isFinite, (0...10).contains(preview) else {
                        throw BenchmarkError.failed("Window cycles must be 1–100; soak seconds 0–600; media preview seconds 0–10")
                    }
                    let suiteDirectory: URL?
                    if scenario == .mediaSuite {
                        guard let path = environment["BOMU_BENCHMARK_SUITE"] else {
                            throw BenchmarkError.failed("Missing A04 media suite directory")
                        }
                        suiteDirectory = URL(fileURLWithPath: path, isDirectory: true)
                    } else {
                        suiteDirectory = nil
                    }
                    let initialDisplayID: UInt32?
                    if let value = environment["BOMU_BENCHMARK_DISPLAY_ID"] {
                        guard let id = UInt32(value), id > 0 else {
                            throw BenchmarkError.failed("Initial display ID must be a positive UInt32")
                        }
                        initialDisplayID = id
                    } else {
                        initialDisplayID = nil
                    }
                    try await WindowLifecycleBenchmark().run(media: URL(fileURLWithPath: mediaPath),
                        output: URL(fileURLWithPath: outputPath), scenario: scenario,
                        cycles: cycles, soakSeconds: soak, suiteDirectory: suiteDirectory, previewSeconds: preview,
                        initialDisplayID: initialDisplayID)
                default:
                    throw BenchmarkError.failed("Supply an explicit benchmark mode using scripts/benchmark-dev.sh")
                }
                print("Playback benchmark completed")
                exit(EXIT_SUCCESS)
            } catch {
                print("Playback benchmark failed: \(error)")
                exit(EXIT_FAILURE)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Cancellation unwinds the current measurement, shuts down its engine and saves partial evidence.
        task?.cancel()
        return .terminateLater
    }
}

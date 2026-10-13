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
        NSApplication.shared.activate()
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
                    try await PlaybackBenchmark().run(
                        media: URL(fileURLWithPath: mediaPath, isDirectory: true),
                        syncMedia: URL(fileURLWithPath: syncPath), output: URL(fileURLWithPath: outputPath))
                case "single-window", "display-transitions":
                    guard let rawScenario = environment["BOMU_BENCHMARK_MODE"],
                          let scenario = WindowScenario(rawValue: rawScenario) else {
                        throw BenchmarkError.failed("Unknown window scenario")
                    }
                    guard let cycles = Int(environment["BOMU_BENCHMARK_CYCLES"] ?? "100"), (1...100).contains(cycles),
                          let soak = Double(environment["BOMU_BENCHMARK_SOAK_SECONDS"] ?? "120"),
                          soak.isFinite, (0...600).contains(soak) else {
                        throw BenchmarkError.failed("Window cycles must be 1–100; soak seconds must be 0–600")
                    }
                    try await WindowLifecycleBenchmark().run(media: URL(fileURLWithPath: mediaPath),
                        output: URL(fileURLWithPath: outputPath), scenario: scenario,
                        cycles: cycles, soakSeconds: soak)
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

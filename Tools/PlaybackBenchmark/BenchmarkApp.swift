import AppKit
import Darwin

private struct BenchmarkLaunchConfiguration: Decodable {
    let mode: String
    let media: String
    let output: String
    let syncMedia: String?
    let suite: String?
    let replacementMedia: String?
    let displayID: String?
    let cycles: String?
    let soakSeconds: String?
    let previewSeconds: String?
    let activationGraceSeconds: String?
    let minimizeRestoreProbe: Bool?
}

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
                let configuration: BenchmarkLaunchConfiguration?
                if let index = CommandLine.arguments.firstIndex(of: "--config"),
                   CommandLine.arguments.indices.contains(index + 1) {
                    let configURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                    configuration = try JSONDecoder().decode(BenchmarkLaunchConfiguration.self,
                        from: Data(contentsOf: configURL))
                } else {
                    configuration = nil
                }
                guard let mediaPath = configuration?.media ?? environment["BOMU_BENCHMARK_MEDIA"],
                      let outputPath = configuration?.output ?? environment["BOMU_BENCHMARK_OUTPUT"] else {
                    throw BenchmarkError.failed("Run scripts/benchmark-dev.sh to supply media and output paths")
                }
                let mode = configuration?.mode ?? environment["BOMU_BENCHMARK_MODE"]
                switch mode {
                case "playback":
                    guard let syncPath = configuration?.syncMedia ?? environment["BOMU_BENCHMARK_SYNC_MEDIA"] else {
                        throw BenchmarkError.failed("Missing synchronization fixture")
                    }
                    NSApplication.shared.activate()
                    try await PlaybackBenchmark().run(
                        media: URL(fileURLWithPath: mediaPath, isDirectory: true),
                        syncMedia: URL(fileURLWithPath: syncPath), output: URL(fileURLWithPath: outputPath))
                case "single-window", "ordinary-resize", "media-suite", "b11-suite", "replacement-burst", "display-transitions":
                    guard let rawScenario = mode,
                          let scenario = WindowScenario(rawValue: rawScenario) else {
                        throw BenchmarkError.failed("Unknown window scenario")
                    }
                    guard let cycles = Int(configuration?.cycles ?? environment["BOMU_BENCHMARK_CYCLES"] ?? "100"), (1...100).contains(cycles),
                          let soak = Double(configuration?.soakSeconds ?? environment["BOMU_BENCHMARK_SOAK_SECONDS"] ?? "120"),
                          soak.isFinite, (0...1_800).contains(soak),
                          let preview = Double(configuration?.previewSeconds ?? environment["BOMU_BENCHMARK_PREVIEW_SECONDS"] ?? "0"),
                          preview.isFinite, (0...10).contains(preview),
                          let activationGrace = Double(configuration?.activationGraceSeconds
                            ?? environment["BOMU_BENCHMARK_ACTIVATION_GRACE_SECONDS"] ?? "0"),
                          activationGrace.isFinite, (0...30).contains(activationGrace) else {
                        throw BenchmarkError.failed("Window cycles must be 1–100; soak seconds 0–1,800; media preview seconds 0–10; activation grace 0–30")
                    }
                    let suiteDirectory: URL?
                    if scenario == .mediaSuite || scenario == .b11Suite {
                        guard let path = configuration?.suite ?? environment["BOMU_BENCHMARK_SUITE"] else {
                            throw BenchmarkError.failed("Missing A04 media suite directory")
                        }
                        suiteDirectory = URL(fileURLWithPath: path, isDirectory: true)
                    } else {
                        suiteDirectory = nil
                    }
                    let replacementMedia: URL?
                    if scenario == .replacementBurst,
                       let path = configuration?.replacementMedia ?? environment["BOMU_BENCHMARK_REPLACEMENT_MEDIA"] {
                        replacementMedia = URL(fileURLWithPath: path)
                    } else {
                        replacementMedia = nil
                    }
                    let initialDisplayID: UInt32?
                    if let value = configuration?.displayID ?? environment["BOMU_BENCHMARK_DISPLAY_ID"] {
                        guard let id = UInt32(value), id > 0 else {
                            throw BenchmarkError.failed("Initial display ID must be a positive UInt32")
                        }
                        initialDisplayID = id
                    } else {
                        initialDisplayID = nil
                    }
                    let minimizeRestoreProbe: Bool
                    if scenario == .ordinaryResize {
                        minimizeRestoreProbe = false
                    } else if let configured = configuration?.minimizeRestoreProbe {
                        minimizeRestoreProbe = configured
                    } else if let raw = environment["BOMU_BENCHMARK_MINIMIZE_RESTORE_PROBE"] {
                        guard raw == "0" || raw == "1" else {
                            throw BenchmarkError.failed("Minimize/restore probe must be 0 or 1")
                        }
                        minimizeRestoreProbe = raw == "1"
                    } else {
                        minimizeRestoreProbe = true
                    }
                    try await WindowLifecycleBenchmark().run(media: URL(fileURLWithPath: mediaPath),
                        output: URL(fileURLWithPath: outputPath), scenario: scenario,
                        cycles: cycles, soakSeconds: soak, suiteDirectory: suiteDirectory, previewSeconds: preview,
                        initialDisplayID: initialDisplayID, replacementMedia: replacementMedia,
                        activationGraceSeconds: activationGrace,
                        minimizeRestoreProbe: minimizeRestoreProbe,
                        syncMedia: (configuration?.syncMedia ?? environment["BOMU_BENCHMARK_SYNC_MEDIA"]).map {
                            URL(fileURLWithPath: $0)
                        })
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

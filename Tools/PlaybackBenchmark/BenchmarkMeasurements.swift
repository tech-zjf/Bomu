import AppKit
import Darwin
import QuartzCore

enum BenchmarkError: Error { case failed(String), processStatistics(Int32) }

struct BenchmarkReport: Encodable {
    let schemaVersion = 6
    let recordedAt = Date()
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    let logicalProcessors = ProcessInfo.processInfo.activeProcessorCount
    let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    let measurement = "Debug standalone AppKit benchmark process using production playback/render sources; first frame submitted to layer FBO; fresh engine, warm filesystem cache; muted audio"
    var failure: String?
    var completed = false
    var completedResizes = 0
    var firstFrames: [FirstFrameMeasurement] = []
    var activity: [ActivityMeasurement] = []
    var switches: [SwitchCheckpoint] = []

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

struct FirstFrameMeasurement: Encodable {
    let sample: String
    let iteration: Int
    let milliseconds: Double
    let decoder: String?
    let width: Int?
    let height: Int?
}

struct ActivityMeasurement: Encodable {
    let phase: String
    let process: [ProcessSample]
    let before: PlaybackDiagnostics
    let after: PlaybackDiagnostics
}

struct SwitchCheckpoint: Encodable {
    let completed: Int
    let process: ProcessSample
    let playback: PlaybackDiagnostics
}

struct ProcessSample: Encodable {
    let uptime: Double
    let cpuSeconds: Double
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
    let windowVisible: Bool

    @MainActor
    static func read(window: NSWindow) throws -> ProcessSample {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { throw BenchmarkError.processStatistics(errno) }
        // getrusage exposes seconds + microseconds. proc_pid_rusage CPU counters use
        // Mach time units, which must not be assumed to be nanoseconds on Apple Silicon.
        var cpu = rusage()
        guard getrusage(RUSAGE_SELF, &cpu) == 0 else { throw BenchmarkError.processStatistics(errno) }
        let cpuSeconds = Double(cpu.ru_utime.tv_sec) + Double(cpu.ru_stime.tv_sec)
            + (Double(cpu.ru_utime.tv_usec) + Double(cpu.ru_stime.tv_usec)) / 1_000_000
        return ProcessSample(uptime: CACurrentMediaTime(),
            cpuSeconds: cpuSeconds,
            residentBytes: usage.ri_resident_size, physicalFootprintBytes: usage.ri_phys_footprint,
            windowVisible: window.occlusionState.contains(.visible))
    }
}

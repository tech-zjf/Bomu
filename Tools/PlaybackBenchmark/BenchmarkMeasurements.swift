import AppKit
import Darwin
import QuartzCore

enum BenchmarkError: Error { case failed(String), processStatistics(Int32) }

struct BenchmarkReport: Encodable {
    let schemaVersion = 9
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
    let taskEnergyCounterDelta: UInt64?
    let gpuUtilisationCounterDelta: UInt64?
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
    let taskEnergyCounterRaw: UInt64?
    let gpuUtilisationCounterRaw: UInt64?
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
        let powerCounters = Self.readPowerCounters()
        return ProcessSample(uptime: CACurrentMediaTime(),
            cpuSeconds: cpuSeconds,
            residentBytes: usage.ri_resident_size, physicalFootprintBytes: usage.ri_phys_footprint,
            taskEnergyCounterRaw: powerCounters.taskEnergy,
            gpuUtilisationCounterRaw: powerCounters.gpuUtilisation,
            windowVisible: window.occlusionState.contains(.visible))
    }

    private static func readPowerCounters() -> (taskEnergy: UInt64?, gpuUtilisation: UInt64?) {
        var power = task_power_info_v2_data_t()
        let wordSize = MemoryLayout<natural_t>.size
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: power) / wordSize)
        let result = withUnsafeMutablePointer(to: &power) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (nil, nil) }
        #if arch(arm64)
        return (power.task_energy, power.gpu_energy.task_gpu_utilisation)
        #else
        return (nil, power.gpu_energy.task_gpu_utilisation)
        #endif
    }

    static func counterDelta(start: UInt64?, end: UInt64?) -> UInt64? {
        guard let start, let end, end >= start else { return nil }
        return end - start
    }
}

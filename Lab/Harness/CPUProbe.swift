import Darwin
import Foundation

// V5 L5 — CPU cost of a workload per second of audio, written to `Lab/results` (§10).
//
// The battery question for ambient listening is "how much of a core does it keep busy while it
// listens in real time?". That is CPU seconds spent per second of audio processed, which can be
// measured offline at any speed: process N seconds of audio as fast as possible, read this process's
// user + system CPU time before and after (`getrusage`), divide. Work the Neural Engine or GPU does is
// not CPU time — which is exactly why L5 puts the always-on VAD on the ANE.

/// This process's user + system CPU time, in seconds.
public enum ProcessCPU {
    public static func seconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }
}

/// One measured phase ("listening, silence", "listening, speech", …).
public struct CPUPhase: Codable, Equatable, Sendable {
    public var name: String
    /// Seconds of audio the workload processed.
    public var audioSeconds: Double
    /// CPU seconds (user + system) the workload took.
    public var cpuSeconds: Double
    /// Wall-clock seconds it took.
    public var wallSeconds: Double
    /// What ran in this phase (e.g. "silero vad (cpuAndNeuralEngine)", "parakeet-tdt-v3 on 3 segments").
    public var detail: String

    public init(name: String, audioSeconds: Double, cpuSeconds: Double, wallSeconds: Double, detail: String = "") {
        self.name = name; self.audioSeconds = audioSeconds; self.cpuSeconds = cpuSeconds
        self.wallSeconds = wallSeconds; self.detail = detail
    }

    /// Percent of one core kept busy when this audio arrives in real time.
    public var percentOfOneCore: Double { audioSeconds > 0 ? 100 * cpuSeconds / audioSeconds : 0 }
}

public struct CPUReport: Codable, Equatable, Sendable {
    public var name: String
    public var date: String
    public var hardware: String
    public var phases: [CPUPhase]
    public var peakRSSMB: Double
    public var notes: [String]

    public init(name: String, date: String, hardware: String, phases: [CPUPhase], peakRSSMB: Double, notes: [String] = []) {
        self.name = name; self.date = date; self.hardware = hardware; self.phases = phases
        self.peakRSSMB = peakRSSMB; self.notes = notes
    }

    public var table: String {
        var lines = ["# cpu — \(name) · \(date) · \(hardware)", "",
                     "| phase | audio s | CPU s | % of one core (real time) | detail |", "|---|---|---|---|---|"]
        for p in phases {
            lines.append(String(format: "| %@ | %.1f | %.3f | %.2f | %@ |", p.name, p.audioSeconds, p.cpuSeconds, p.percentOfOneCore, p.detail))
        }
        lines.append(String(format: "\npeak RSS %.0f MB", peakRSSMB))
        notes.forEach { lines.append("note: \($0)") }
        return lines.joined(separator: "\n")
    }
}

public enum CPUProbe {
    /// Runs `body` (which processes `audioSeconds` of audio) and measures its CPU time.
    public static func measure(_ name: String, audioSeconds: Double, detail: String = "",
                               cpu: () -> Double = ProcessCPU.seconds,
                               wall: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                               _ body: () async throws -> Void) async rethrows -> CPUPhase {
        let c0 = cpu(), w0 = wall()
        try await body()
        return CPUPhase(name: name, audioSeconds: audioSeconds, cpuSeconds: max(0, cpu() - c0),
                        wallSeconds: max(0, wall() - w0), detail: detail)
    }

    /// `Lab/results/<date>-<name>-cpu.json`.
    @discardableResult
    public static func write(_ report: CPUReport, paths: EvalPaths = EvalPaths()) throws -> URL {
        try FileManager.default.createDirectory(at: paths.resultsDirectory, withIntermediateDirectories: true)
        let url = paths.resultsDirectory.appendingPathComponent("\(report.date)-\(report.name)-cpu.json")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(report).write(to: url)
        return url
    }
}

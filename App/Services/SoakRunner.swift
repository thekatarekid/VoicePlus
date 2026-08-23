import Darwin
import Foundation
import Injection
import Shared

/// P1.12 T3 — `VoicePlusApp --soak <minutes> [--fixture name]`: loops fixture dictations
/// through the full landing path (mock engine at fixture speed → pipeline → mock injector),
/// sampling `ProcessInfo.thermalState`, process CPU and RSS every few seconds. Headless: no
/// AppKit, no TCC. `Packaging/soak.sh` wraps it and archives the log.
public enum SoakRunner {
    public struct Sample: Codable, Sendable {
        public var t: Double
        public var thermal: String
        public var cpuPercent: Double
        public var rssMB: Double
        public var dictations: Int
        public var landedP50Ms: Double
        public var landedP95Ms: Double
    }

    public static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// CPU seconds consumed by this process (user + system).
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }

    /// Runs for `minutes`; returns the samples (also printed as TSV lines as they happen).
    public static func run(minutes: Double, fixture: String = "email_reply", sampleEvery: TimeInterval = 5,
                           delayScale: Double = 0.25, output: @escaping (String) -> Void = { print($0) }) async -> [Sample] {
        let engine = (try? MockEngine(fixtureNamed: fixture, delayScale: delayScale))
            ?? MockEngine(fixture: TranscriptFixture(name: "inline", spans: [
                .init(text: "Soak test utterance number one.", confidence: 0.95, audioStart: 0, audioEnd: 2, delayMs: 200),
            ]), delayScale: delayScale)
        var options = AppContainer.Options()
        options.database = try? AppDatabase.inMemory()
        options.flags = .inMemory()
        options.settings = InMemorySettingsStore()
        options.system = MockSystemAccess()
        options.discoverProviders = false
        options.environment["VOICEPLUS_FIXTURE"] = fixture
        let container = await AppContainer.build(options: options)
        let lander = container.lander

        let start = Date()
        let deadline = start.addingTimeInterval(minutes * 60)
        var samples: [Sample] = []
        var latencies: [Double] = []
        var dictations = 0
        var lastSample = start
        var lastCPU = cpuSeconds()
        output("t_s\tthermal\tcpu%\trss_mb\tdictations\tp50_ms\tp95_ms")

        while Date() < deadline {
            let startedAt = Date()
            do {
                try await engine.start(prewarm: true)
                let spans = try await engine.stop()
                let t0 = Date()
                let result = await lander.land(spans, startedAt: startedAt, focus: container.system.frontmostApp())
                _ = result
                latencies.append(Date().timeIntervalSince(t0) * 1000)
                dictations += 1
            } catch {
                output("error: \(error)")
            }
            let now = Date()
            if now.timeIntervalSince(lastSample) >= sampleEvery {
                let cpu = cpuSeconds()
                let pct = (cpu - lastCPU) / now.timeIntervalSince(lastSample) * 100
                let s = Sample(t: now.timeIntervalSince(start), thermal: thermalName(ProcessInfo.processInfo.thermalState),
                               cpuPercent: pct, rssMB: residentMB(), dictations: dictations,
                               landedP50Ms: percentile(latencies, 0.5), landedP95Ms: percentile(latencies, 0.95))
                samples.append(s)
                output(String(format: "%.0f\t%@\t%.1f\t%.1f\t%d\t%.1f\t%.1f", s.t, s.thermal, s.cpuPercent, s.rssMB, s.dictations, s.landedP50Ms, s.landedP95Ms))
                lastSample = now
                lastCPU = cpu
                latencies.removeAll(keepingCapacity: true)
            }
        }
        return samples
    }

    /// `--soak N [--fixture F]` → (minutes, fixture); nil when the flag is absent.
    public static func parse(_ args: [String]) -> (minutes: Double, fixture: String)? {
        guard let i = args.firstIndex(of: "--soak") else { return nil }
        let minutes = args.indices.contains(i + 1) ? Double(args[i + 1]) ?? 3 : 3
        var fixture = "email_reply"
        if let f = args.firstIndex(of: "--fixture"), args.indices.contains(f + 1) { fixture = args[f + 1] }
        return (minutes, fixture)
    }
}

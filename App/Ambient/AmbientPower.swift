import CoreML
import Engine
import Foundation
import Lab

// V5 L5 · battery. What ambient listening may run, and when:
//
//   VAD     — always while listening, on the Neural Engine (`SileroVAD` loads `.cpuAndNeuralEngine`);
//   ASR     — only on a closed speech segment (`AmbientListener`: silence never reaches a recognizer);
//   decide  — only at segment end, once per kept segment (`AmbientDecisionPipeline`, fed by the listener);
//   camera  — only when a lip-reading mode is on (`CameraModeGate`; ambient never starts it).
//
// `AmbientPowerBench` measures the CPU each phase costs per second of audio (`CPUProbe`, written to
// `Lab/results/<date>-ambient-cpu.json`), with the counterfactual L5 avoids — transcribing every
// 4 s chunk whether or not anyone spoke — beside it.

public enum AmbientPowerPolicy {
    /// The compute units the always-on VAD asks for. Must match `SileroVAD.loadIfAvailable`
    /// (`AmbientPowerTests` loads the real model through a recording loader to check).
    public static let vadComputeUnits: MLComputeUnits = .cpuAndNeuralEngine

    /// The camera runs for a lip-reading mode only — never because ambient listening is on.
    public static func cameraMayRun(lipMode: LipMode, ambient: AmbientMode) -> Bool { lipMode.needsCamera }
}

/// Replays audio through the ambient listening path (VAD → segmenter → ASR on closed segments) as
/// fast as it can, and measures CPU per second of audio.
public struct AmbientPowerBench: Sendable {
    public var vad: any VADProtocol
    public var transcribe: AmbientListener.Transcribe?
    public var recognizerName: String
    public var config: AmbientSegmenter.Config

    public init(vad: any VADProtocol, transcribe: AmbientListener.Transcribe?, recognizerName: String = "none",
                config: AmbientSegmenter.Config = AmbientSegmenter.Config()) {
        self.vad = vad; self.transcribe = transcribe; self.recognizerName = recognizerName; self.config = config
    }

    public struct Counts: Equatable, Sendable {
        public var segments = 0
        public var asrRuns = 0
    }

    /// The listening path over `samples`: VAD on every frame, ASR only on segments it closes.
    public func listen(_ samples: [Float]) async throws -> Counts {
        await vad.reset()
        var segmenter = AmbientSegmenter(config: config)
        var counts = Counts()
        _ = segmenter.handle(.started(device: nil))
        var i = 0
        let frame = vad.frameSize
        while i < samples.count {
            let end = min(i + frame, samples.count)
            var block = Array(samples[i..<end])
            var closed = segmenter.handle(.audio(samples: block, position: Double(i) / 16_000))
            if block.count < frame { block.append(contentsOf: [Float](repeating: 0, count: frame - block.count)) }
            if let event = try await vad.process(frame: block).event { closed += segmenter.handle(.vad(event)) }
            for segment in closed { try await run(segment, &counts) }
            i = end
        }
        for segment in segmenter.handle(.stopped(totalSamples: samples.count)) { try await run(segment, &counts) }
        return counts
    }

    private func run(_ segment: AmbientSpeechSegment, _ counts: inout Counts) async throws {
        counts.segments += 1
        guard let transcribe else { return }
        counts.asrRuns += 1
        _ = try await transcribe(segment.samples)
    }

    /// The counterfactual: ASR on every `chunk` seconds, speech or not.
    public func transcribeEverything(_ samples: [Float], chunk: TimeInterval = 4) async throws -> Int {
        guard let transcribe else { return 0 }
        let n = Int(chunk * 16_000)
        var runs = 0
        var i = 0
        while i < samples.count {
            _ = try await transcribe(Array(samples[i..<min(i + n, samples.count)]))
            runs += 1
            i += n
        }
        return runs
    }

    /// The report: off (no capture), listening over silence, listening over speech, and the
    /// always-transcribe counterfactual over the same speech.
    public func measure(silence: [Float], speech: [Float], date: String, hardware: String = LabRunner.hardwareDescription(),
                        cpu: () -> Double = ProcessCPU.seconds) async throws -> CPUReport {
        let silenceSeconds = Double(silence.count) / 16_000, speechSeconds = Double(speech.count) / 16_000
        var phases = [CPUPhase(name: "off", audioSeconds: silenceSeconds, cpuSeconds: 0, wallSeconds: 0,
                               detail: "no capture graph: nothing runs (by construction)")]
        var quiet = Counts()
        phases.append(try await CPUProbe.measure("listening · silence", audioSeconds: silenceSeconds, cpu: cpu) {
            quiet = try await listen(silence)
        })
        phases[phases.count - 1].detail = "\(vad.name) vad · \(quiet.asrRuns) ASR runs"
        var talk = Counts()
        phases.append(try await CPUProbe.measure("listening · speech", audioSeconds: speechSeconds, cpu: cpu) {
            talk = try await listen(speech)
        })
        phases[phases.count - 1].detail = "\(vad.name) vad · \(talk.segments) segments · \(talk.asrRuns) × \(recognizerName)"
        if transcribe != nil {
            for (label, audio, seconds) in [("silence", silence, silenceSeconds), ("speech", speech, speechSeconds)] {
                var runs = 0
                phases.append(try await CPUProbe.measure("counterfactual · ASR every 4 s · \(label)", audioSeconds: seconds, cpu: cpu) {
                    runs = try await transcribeEverything(audio)
                })
                phases[phases.count - 1].detail = "\(runs) × \(recognizerName), no VAD gate"
            }
        }
        var notes = ["offline replay at full speed; % of one core = CPU s / audio s (ANE/GPU time is not CPU time)",
                     "the in-app number (live mic, AudioPipeline resampling + mic-quality) needs the owner's Mac → T1"]
        if transcribe == nil { notes.append("no local recognizer: speech phase is VAD + segmentation only") }
        return CPUReport(name: "ambient", date: date, hardware: hardware, phases: phases,
                         peakRSSMB: Double(EvalMetrics.peakRSSBytes()) / 1_048_576, notes: notes)
    }
}

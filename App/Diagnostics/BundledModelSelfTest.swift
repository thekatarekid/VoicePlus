import AVFoundation
import Engine
import FluidAudio
import Foundation

/// Explicit headless installer diagnostic. Uses only verified app resources and deterministic
/// synthesized audio: no microphone, recordings, user model caches, or download-capable loaders.
/// This is an inference smoke check, not a recognition-accuracy or speaker-quality benchmark.
enum BundledModelSelfTest {
    private struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static func run() async -> Int32 {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("voiceplus-bundle-check-\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let candidates = BundledModelResources.candidates()
        // Exercise the production local loaders, with every user cache and fetcher excluded.
        let manager = ModelManager(root: scratch, fetchers: [:], externalCaches: candidates.mapValues { [$0] }, maintenance: .skip)
        let samples = syntheticSamples()
        do {
            for id in ModelStack.models {
                guard let expected = candidates[id], await manager.locate(id) == expected else {
                    print("bundle-check: missing bundled \(id.rawValue)"); return 2
                }
                guard await manager.verify(id).isEmpty,
                      ModelManifest.load(from: expected) != nil else {
                    print("bundle-check: integrity failure \(id.rawValue)"); return 3
                }
                print("bundle-check: inference starting \(id.rawValue) from app resources")
                switch id {
                case .parakeetTDTv3:
                    guard let models = try await manager.load(id).asrModels else {
                        throw Failure(reason: "TDT loader returned the wrong model")
                    }
                    try await checkTDT(models, samples: samples)
                case .parakeetEOU160:
                    guard let eou = try await manager.load(id).eouManager else {
                        throw Failure(reason: "EOU loader returned the wrong model")
                    }
                    try await checkEOU(eou, samples: samples)
                case .speakerEmbedding:
                    guard let speaker = FluidSpeakerEmbedder.load(from: expected) else {
                        throw Failure(reason: "Speaker model load failed")
                    }
                    let vector = try speaker.embed(samples).vector
                    let squaredNorm = vector.reduce(Float.zero) { $0 + $1 * $1 }
                    try require(vector.count == 256 && vector.allSatisfy(\.isFinite)
                        && squaredNorm.isFinite && abs(squaredNorm - 1) < 0.01,
                        "Speaker inference returned an invalid 256-dimensional embedding")
                    print("bundle-check: speaker inference PASS (256 finite normalized values)")
                default:
                    throw Failure(reason: "No inference check defined for \(id.rawValue)")
                }
                await manager.unload(id)
            }
            print("bundle-check: PASS — bundled TDT, EOU and speaker inference; synthetic audio; empty user cache; no fetchers")
            return 0
        } catch {
            await manager.unloadAll()
            print("bundle-check: failed \(error.localizedDescription)")
            return 5
        }
    }

    /// Two seconds of fixed, tapered harmonics at 16 kHz. Nonzero input exercises the models;
    /// non-speech may legitimately decode to an empty string, so never require a specific phrase.
    private static func syntheticSamples() -> [Float] {
        (0..<32_000).map { index in
            let t = Double(index) / 16_000
            let envelope = min(1, min(t / 0.1, (2 - t) / 0.1))
            let carrier = sin(2 * .pi * 180 * t) + 0.35 * sin(2 * .pi * 420 * t)
            return Float(0.08 * envelope * carrier)
        }
    }

    private static func checkTDT(_ models: AsrModels, samples: [Float]) async throws {
        let recognizer = AsrManager(config: .default, models: nil)
        do {
            try await recognizer.loadModels(models)
            var state = try TdtDecoderState(decoderLayers: models.version.decoderLayers)
            let result = try await recognizer.transcribe(samples, decoderState: &state, language: .english)
            let duration = Double(samples.count) / 16_000
            try require(result.confidence.isFinite && (0...1).contains(result.confidence)
                && result.duration.isFinite && abs(result.duration - duration) < 0.01
                && result.processingTime.isFinite && result.processingTime >= 0,
                "TDT inference returned invalid metrics")
            let timings = result.tokenTimings ?? []
            var previousStart: TimeInterval = 0
            for token in timings {
                try require(token.startTime.isFinite && token.endTime.isFinite
                    && token.startTime >= previousStart && token.endTime >= token.startTime
                    && token.endTime <= duration + 0.5 && token.tokenId >= 0
                    && token.confidence.isFinite && (0...1).contains(token.confidence),
                    "TDT inference returned invalid token timing/confidence")
                previousStart = token.startTime
            }
            try require(result.text.utf8.count <= 16_384 && timings.count <= 4096, "TDT output exceeded the smoke-check bound")
            await recognizer.cleanup()
            print("bundle-check: TDT inference PASS (\(timings.count) tokens; finite metrics)")
        } catch {
            await recognizer.cleanup()
            throw error
        }
    }

    private static func checkEOU(_ recognizer: StreamingEouAsrManager, samples: [Float]) async throws {
        await recognizer.reset()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
            throw Failure(reason: "Cannot create synthetic audio format")
        }
        var chunks = 0
        for start in stride(from: 0, to: samples.count, by: 2560) {
            let end = min(start + 2560, samples.count)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(end - start)),
                  let channel = buffer.floatChannelData?[0] else {
                throw Failure(reason: "Cannot allocate synthetic audio buffer")
            }
            buffer.frameLength = buffer.frameCapacity
            for index in start..<end { channel[index - start] = samples[index] }
            _ = try await recognizer.process(audioBuffer: buffer)
            chunks += 1
        }
        let timestamps = await recognizer.getTokenTimestampsMs()
        let tokens = await recognizer.getRawTokenStrings()
        let eouTimestamps = await recognizer.getEouTimestampsMs()
        let maximumTimestamp = Int(Double(samples.count) / 16_000 * 1000) + 500
        for values in [timestamps, eouTimestamps] {
            try require(values.allSatisfy { (0...maximumTimestamp).contains($0) }
                && zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "EOU inference returned invalid timestamps")
        }
        try require(timestamps.count == tokens.count && tokens.count <= 4096, "EOU inference returned invalid token metadata")
        let text = try await recognizer.finish()
        try require(text.utf8.count <= 16_384, "EOU output exceeded the smoke-check bound")
        await recognizer.reset()
        let resetText = await recognizer.getPartialTranscript()
        try require(resetText.isEmpty, "EOU reset retained the previous transcript")
        print("bundle-check: EOU inference PASS (\(chunks) input chunks plus final flush)")
    }

    private static func require(_ condition: Bool, _ reason: String) throws {
        guard condition else { throw Failure(reason: reason) }
    }
}

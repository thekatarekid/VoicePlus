import CoreGraphics
import Foundation
import Shared
import Testing
@testable import Engine

/// V5 LR2/LR3 — Auto-AVSR recogniser mechanics against a mock model (no weights on this machine),
/// plus the LR6 eval gated on the owner's LRS3 manifest.
@Suite struct AVSRRecognizerTests {
    static let vocab = AVSRVocabulary(tokens: ["<blank>", "\u{2581}HEL", "LO", "\u{2581}WORLD", "<unk>"])

    /// One-hot-ish log-probs: each row puts 0.9 on `id`, the rest spread.
    static func frames(_ ids: [Int], vocab: Int = 5) -> CTCOutput {
        CTCOutput(logProbs: ids.map { id in
            (0..<vocab).map { $0 == id ? log(0.9) : log(0.1 / Float(vocab - 1)) }
        }, frameDuration: 0.04)
    }

    final class MockModel: AVSRModelRunning, @unchecked Sendable {
        let vocabulary = AVSRRecognizerTests.vocab
        var installed: Set<AVSRVariant> = [.audioVisual, .visualOnly]
        var calls: [(AVSRVariant, hasAudio: Bool, frames: Int)] = []
        var output = AVSRRecognizerTests.frames([1, 1, 0, 2, 0, 3, 3, 0])
        func isAvailable(_ v: AVSRVariant) -> Bool { installed.contains(v) }
        func run(_ input: AVSRInput, variant: AVSRVariant) async throws -> CTCOutput {
            calls.append((variant, input.audio != nil, input.video.count))
            return output
        }
    }

    final class FixedClip: VisualClipProviding, @unchecked Sendable {
        var clip: VisualClip?
        init(_ clip: VisualClip?) { self.clip = clip }
        func visualClip(duration: TimeInterval) -> VisualClip? { clip }
    }

    final class AudioOnly: FinalRecognizer, @unchecked Sendable {
        let name = "parakeet"
        var calls = 0
        func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] {
            calls += 1
            return [TranscriptSpan(text: "audio", confidence: 0.9, audioRange: 0...1, provenance: [.asr])]
        }
    }

    static func clip(seconds: Double, faceFraction: Double) -> VisualClip {
        let n = Int(seconds * 25)
        let frames = (0..<n).map { i in
            MouthCropFrame(time: Double(i) / 25 + 0.02,
                           pixels: Double(i) < Double(n) * faceFraction ? [UInt8](repeating: 128, count: 88 * 88) : nil)
        }
        return VisualClip(start: 0, end: seconds, frames: frames)
    }

    // MARK: CTC search

    @Test func ctcCollapsesRepeatsAndBlanks() {
        let best = CTCPrefixBeamSearch().decode(Self.frames([1, 1, 0, 2, 0, 3, 3, 0]))
        #expect(best.tokens.map(\.id) == [1, 2, 3])
        let doubled = CTCPrefixBeamSearch().decode(Self.frames([2, 0, 2]))
        #expect(doubled.tokens.map(\.id) == [2, 2], "a blank between repeats keeps both")
    }

    @Test func ctcBeamBeatsGreedyWhenMassIsSplit() {
        // Greedy picks blank,blank (0.4 each) → "", but "token 1" has more total mass across paths.
        let lp: [[Float]] = [[log(0.4), log(0.35), log(0.25)], [log(0.4), log(0.35), log(0.25)]]
        let out = CTCPrefixBeamSearch(beamWidth: 8, tokensPerFrame: 3).decode(CTCOutput(logProbs: lp, frameDuration: 0.04))
        #expect(out.tokens.map(\.id) == [1])
    }

    // MARK: Recogniser

    @Test func fusedWhenAFaceIsTracked() async throws {
        let model = MockModel(), fallback = AudioOnly()
        let rec = AVSRRecognizer(model: model, visual: FixedClip(Self.clip(seconds: 1, faceFraction: 1)), fallback: fallback)
        let spans = try await rec.recognize([Float](repeating: 0.01, count: 16_000))
        #expect(spans.map(\.text) == ["hello", "world"])
        #expect(rec.lastPath == .fused && fallback.calls == 0)
        #expect(model.calls.first?.0 == .audioVisual && model.calls.first?.hasAudio == true && model.calls.first?.frames == 25)
        #expect(spans.allSatisfy { $0.provenance == [.asr, AVSRRecognizer.fusedStage] })
        #expect(spans[0].audioRange.lowerBound == 0 && abs(spans[1].audioRange.upperBound - 0.24) < 1e-9)
        #expect(spans.allSatisfy { $0.confidence > 0.8 })
    }

    @Test func audioOnlyWhenNoFace() async throws {
        let model = MockModel(), fallback = AudioOnly()
        let rec = AVSRRecognizer(model: model, visual: FixedClip(Self.clip(seconds: 1, faceFraction: 0.3)), fallback: fallback)
        let spans = try await rec.recognize([Float](repeating: 0, count: 16_000))
        #expect(spans.map(\.text) == ["audio"] && rec.lastPath == .audioFallback && model.calls.isEmpty)
        let noCamera = AVSRRecognizer(model: model, visual: FixedClip(nil), fallback: fallback)
        _ = try await noCamera.recognize([0])
        #expect(noCamera.lastPath == .audioFallback)
    }

    @Test func audioOnlyWhenModelNotInstalled() async throws {
        let model = MockModel(); model.installed = []
        let fallback = AudioOnly()
        let rec = AVSRRecognizer(model: model, visual: FixedClip(Self.clip(seconds: 1, faceFraction: 1)), fallback: fallback)
        _ = try await rec.recognize([Float](repeating: 0, count: 16_000))
        #expect(rec.lastPath == .audioFallback && model.calls.isEmpty)
    }

    @Test func gappyTrackingIsFilledDense() {
        var frames = Self.clip(seconds: 1, faceFraction: 1).frames
        frames[10].pixels = nil
        let clip = VisualClip(start: 0, end: 1, frames: frames)
        #expect(clip.faceCoverage > 0.9)
        #expect(clip.denseFrames().count == 25 && clip.denseFrames().allSatisfy { $0.count == 88 * 88 })
        // 15 fps source resampled onto the 25 fps model grid.
        let fifteen = VisualClip(start: 0, end: 2, frames: (0..<30).map { MouthCropFrame(time: Double($0) / 15, pixels: [UInt8($0)]) })
        #expect(fifteen.resampled().count == 50 && fifteen.faceCoverage == 1)
    }

    @Test func mouthCropFromAGrayImage() throws {
        // 100×100 image: left half black, right half white; mouth centred at (0.5, 0.5).
        let img = GrayImage(width: 100, height: 100, pixels: (0..<10_000).map { $0 % 100 < 50 ? 0 : 255 })
        let crop = try #require(MouthCropper.crop(img, mouthRect: CGRect(x: 0.4, y: 0.45, width: 0.2, height: 0.1)))
        #expect(crop.count == 88 * 88)
        #expect(crop[44 * 88 + 2] < 10 && crop[44 * 88 + 85] > 245, "left dark, right bright")
        #expect(MouthCropper.crop(img, mouthRect: .zero) == nil)
    }

    @Test func frameBufferIsBoundedAndClears() {
        let buf = VisualFrameBuffer(maxSeconds: 2, now: { 10 })
        for i in 0..<100 { buf.append(MouthCropFrame(time: Double(i) / 25, pixels: [1])) }
        #expect(buf.count <= 51)
        #expect(buf.visualClip(duration: 1) != nil)
        buf.clear()
        #expect(buf.count == 0)
    }

    @Test func vocabularyFileAndCatalog() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tok-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "<blank> 0\n\u{2581}A 1\nB 2\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(try AVSRVocabulary(contentsOf: url).tokens == ["<blank>", "\u{2581}A", "B"])
        #expect(AVSRCatalog.residencyKey(.audioVisual) == "vision.auto-avsr.avsr")
        let locator = AVSRModelLocator(root: URL(fileURLWithPath: "/nonexistent"))
        #expect(!locator.isInstalled(.visualOnly))
        #expect(CoreMLAVSRModel(locator: locator, residency: ModelResidency()) == nil, "no vocabulary → no model")
    }

    // MARK: LR6 — real eval, owner's data only

    static var manifest: URL? {
        ProcessInfo.processInfo.environment["VOICEPLUS_LRS3_MANIFEST"].map { URL(fileURLWithPath: $0) }
    }

    @Test(.enabled(if: AVSRRecognizerTests.manifest != nil && AVSRModelLocator().isInstalled(.audioVisual)
                    && AVSRModelLocator().isInstalled(.visualOnly)))
    func lrs3Eval() async throws {
        let model = try #require(CoreMLAVSRModel())
        let lines = try String(contentsOf: Self.manifest!, encoding: .utf8).split(separator: "\n")
        var lipsErr = 0, fusedErr = 0, audioErr = 0, words = 0
        for line in lines {
            let row = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
            let raw = try Data(contentsOf: URL(fileURLWithPath: row["crops"]!))
            let side = 88 * 88, n = raw.count / side
            let frames = (0..<n).map { MouthCropFrame(time: Double($0) / 25 + 0.02, pixels: [UInt8](raw[($0 * side)..<(($0 + 1) * side)])) }
            let visual = FixedClip(VisualClip(start: 0, end: Double(n) / 25, frames: frames))
            let speech = try WAVFile.read(url: URL(fileURLWithPath: row["wav"]!)).mono
            let noise = try WAVFile.read(url: URL(fileURLWithPath: row["noise"]!)).mono
            let mixed = Self.mix(speech, noise, snrDB: 0)
            let ref = row["ref"]!
            let lips = try await AVSRRecognizer(videoOnly: true, model: model, visual: visual).recognizeLips(duration: Double(n) / 25)
            let fused = try await AVSRRecognizer(model: model, visual: visual, fallback: nil).recognize(mixed)
            lipsErr += Self.edits(ref, lips.map(\.text).joined(separator: " "))
            fusedErr += Self.edits(ref, fused.map(\.text).joined(separator: " "))
            audioErr += Self.edits(ref, row["audio_only_noisy_hyp"] ?? "")
            words += ref.split(separator: " ").count
        }
        let w = Double(max(1, words))
        print("LR6 lips-only WER \(Double(lipsErr) / w) · fused@0dB \(Double(fusedErr) / w) · audio-only@0dB \(Double(audioErr) / w)")
        #expect(fusedErr < audioErr, "fused + MUSAN 0 dB must beat audio-only")
    }

    static func mix(_ s: [Float], _ n: [Float], snrDB: Float) -> [Float] {
        guard !n.isEmpty else { return s }
        func power(_ x: [Float]) -> Float { x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count)) }
        let noise = (0..<s.count).map { n[$0 % n.count] }
        let g = (power(s) / max(1e-12, power(noise) * pow(10, snrDB / 10))).squareRoot()
        return zip(s, noise).map { $0 + g * $1 }
    }

    static func edits(_ ref: String, _ hyp: String) -> Int {
        let r = ref.lowercased().split(separator: " "), h = hyp.lowercased().split(separator: " ")
        var d = Array(0...h.count)
        for i in 1...max(1, r.count) where !r.isEmpty {
            var prev = d[0]; d[0] = i
            for j in stride(from: 1, through: h.count, by: 1) {
                let tmp = d[j]
                d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] == h[j - 1] ? 0 : 1))
                prev = tmp
            }
        }
        return r.isEmpty ? h.count : d[h.count]
    }

    @Test func werHelper() {
        #expect(Self.edits("a b c", "a x c") == 1)
        #expect(Self.edits("a b", "") == 2)
    }
}

import Foundation
import Shared

/// V5 LR2/LR3 — Auto-AVSR as a `FinalRecognizer`.
///
/// * **Fused** (`videoOnly: false`, LR2, the default when a camera mode is on): when a face is
///   tracked for the utterance (≥ `minFaceCoverage` of its 25 fps slots) the audio and the mouth
///   crops go through the audio-visual model. With no face — or the model not installed — it falls
///   back to the audio-only `fallback` recogniser (the normal Parakeet final pass), so turning the
///   camera on can never make dictation worse than off.
/// * **Lips only** (`videoOnly: true`, LR3): the audio is ignored (the mic is muted); no face is
///   an error (`AVSRError.noFaceTracked`), not a silent empty result.
///
/// Spans carry per-word confidence from the CTC peaks, an `audioRange` on the utterance clock and
/// provenance `[.asr, asr.avsr|asr.vsr]`.
public final class AVSRRecognizer: FinalRecognizer, @unchecked Sendable {
    public static let fusedStage: StageID = "asr.avsr"
    public static let lipsStage: StageID = "asr.vsr"

    public let videoOnly: Bool
    public var name: String { videoOnly ? "auto-avsr-vsr" : "auto-avsr-av" }
    public let minFaceCoverage: Double

    private let model: AVSRModelRunning
    private let visual: VisualClipProviding
    private let fallback: FinalRecognizer?
    private let search: CTCPrefixBeamSearch
    private let sampleRate: Double = 16_000

    /// Last path taken (diagnostics / tests).
    public private(set) var lastPath: Path = .none
    public enum Path: String, Sendable, Equatable { case none, fused, lipsOnly, audioFallback }

    public init(model: AVSRModelRunning, visual: VisualClipProviding, fallback: FinalRecognizer?,
                videoOnly: Bool = false, minFaceCoverage: Double = 0.6,
                search: CTCPrefixBeamSearch = CTCPrefixBeamSearch()) {
        self.model = model; self.visual = visual; self.fallback = fallback
        self.videoOnly = videoOnly; self.minFaceCoverage = minFaceCoverage; self.search = search
    }

    /// LR3 convenience.
    public convenience init(videoOnly: Bool, model: AVSRModelRunning, visual: VisualClipProviding) {
        self.init(model: model, visual: visual, fallback: nil, videoOnly: videoOnly)
    }

    public func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] {
        let duration = Double(samples.count) / sampleRate
        if videoOnly { return try await recognizeLips(duration: duration) }
        let variant = AVSRVariant.audioVisual
        guard model.isAvailable(variant), let clip = visual.visualClip(duration: duration),
              clip.faceCoverage >= minFaceCoverage else {
            return try await audioOnly(samples)
        }
        let video = clip.denseFrames()
        guard !video.isEmpty else { return try await audioOnly(samples) }
        let out = try await model.run(AVSRInput(audio: samples, video: video), variant: variant)
        lastPath = .fused
        return spans(from: out, stage: Self.fusedStage)
    }

    /// Lips-only over the last `duration` seconds of crops.
    public func recognizeLips(duration: TimeInterval) async throws -> [TranscriptSpan] {
        guard model.isAvailable(.visualOnly) else { throw AVSRError.modelNotInstalled(.visualOnly) }
        guard let clip = visual.visualClip(duration: duration), clip.faceCoverage >= minFaceCoverage else {
            throw AVSRError.noFaceTracked
        }
        let out = try await model.run(AVSRInput(audio: nil, video: clip.denseFrames()), variant: .visualOnly)
        lastPath = .lipsOnly
        return spans(from: out, stage: Self.lipsStage)
    }

    private func audioOnly(_ samples: [Float]) async throws -> [TranscriptSpan] {
        guard let fallback else { throw AVSRError.noFaceTracked }
        lastPath = .audioFallback
        return try await fallback.recognize(samples)
    }

    /// CTC tokens → one span per word.
    func spans(from out: CTCOutput, stage: StageID) -> [TranscriptSpan] {
        let tokens = search.decode(out).tokens
        let vocab = model.vocabulary
        var words: [(text: String, tokens: [CTCToken])] = []
        for tok in tokens {
            var piece = vocab.piece(tok.id)
            guard !piece.isEmpty, piece != "<unk>", piece != "<blank>" else { continue }
            if piece.hasPrefix(AVSRVocabulary.wordMarker) || words.isEmpty {
                piece = String(piece.drop { String($0) == AVSRVocabulary.wordMarker })
                words.append((piece, [tok]))
            } else {
                words[words.count - 1].text += piece
                words[words.count - 1].tokens.append(tok)
            }
        }
        return words.compactMap { w in
            let text = w.text.lowercased()
            guard !text.isEmpty, let first = w.tokens.first, let last = w.tokens.last else { return nil }
            let meanLog = w.tokens.map(\.logProb).reduce(0, +) / Float(w.tokens.count)
            let start = Double(first.frame) * out.frameDuration
            let end = Double(last.frame + 1) * out.frameDuration
            return TranscriptSpan(text: text, confidence: exp(meanLog), audioRange: start...end,
                                  provenance: [.asr, stage])
        }
    }
}

import Engine
import Foundation
import Shared

/// P6.1/P6.2 integration — the personal adaptation loop as one seam:
/// corrections (voice repair, dual-path) + post-dictation keyboard edits (zero-edit tracker)
/// → `TrainingPairStore` → periodic `AdaptationLoop.retrain()` (bias-list learning; LoRA
/// reports infeasible on-device) → `PersonalLexicon` feeding the Biasing ranker
/// (`LearnedLexiconSource`) and the `RegressionGuard` pipeline stage; `PersonalWERTracker`
/// keeps the day-by-day "you" numbers for the Lab.
public final class AdaptationService: @unchecked Sendable {
    public let store: TrainingPairStore
    public let loop: AdaptationLoop
    public let personalWER: PersonalWERTracker
    public let pronunciation: PronunciationCapture?
    public let rememberToast: RememberToastModel
    private let lock = NSLock()
    private var dirty = false

    public init(root: URL = TrainingPairStore.defaultRoot(),
                werFile: URL? = nil, toastFile: URL? = nil) throws {
        store = try TrainingPairStore(root: root)
        loop = AdaptationLoop(store: store)
        personalWER = PersonalWERTracker(file: werFile)
        pronunciation = try? PronunciationCapture(directory: root.appendingPathComponent("Pronunciations"), store: store)
        rememberToast = RememberToastModel(file: toastFile)
        if store.count > 0 { loop.retrain() }
    }

    /// A correction (voice repair / dual-path / manual) becomes training pairs + a WER sample.
    /// Multi-word corrections are word-diffed so the lexicon learns the *word-level* variant
    /// ("kotari" → "Kothari"), which is what the regression guard needs.
    public func ingest(_ correction: CorrectionRecord) {
        let words = correction.original.split(separator: " ").map(String.init)
        let range = correction.audioStart...max(correction.audioEnd, correction.audioStart + 0.01)
        let step = (range.upperBound - range.lowerBound) / Double(max(words.count, 1))
        let spans = words.enumerated().map { i, w in
            TranscriptSpan(text: w, confidence: 1,
                           audioRange: (range.lowerBound + Double(i) * step)...(range.lowerBound + Double(i + 1) * step))
        }
        do {
            let pairs = try store.ingestEdit(utteranceID: correction.utteranceID, spans: spans,
                                             editedText: correction.corrected, at: correction.createdAt)
            if pairs.isEmpty { _ = try store.ingest(correction) }
        } catch { Log.app.error("adapt ingest failed: \(error)") }
        personalWER.record(hypothesis: correction.original, finalText: correction.corrected, at: correction.createdAt)
        markDirty()
    }

    /// A post-dictation keyboard edit (from the zero-edit tracker) becomes training pairs.
    public func ingestEdit(utteranceID: String, original: String, edited: String, at date: Date = Date()) {
        guard !original.isEmpty, !edited.isEmpty, original != edited else { return }
        // `edited` comes from the zero-edit tracker's AX readback: the whole focused field, which
        // usually contains text this utterance never produced. Comparing the two then teaches the
        // lexicon nonsense (see `LexiconSanity`), so a readback that cannot be this utterance is
        // dropped — including from the WER series, where it would be equally meaningless.
        guard LexiconSanity.isPlausibleEdit(of: original, edited: edited) else {
            Log.app.notice("adapt: skipping edit readback that is not this utterance (\(LexiconSanity.wordCount(original)) → \(LexiconSanity.wordCount(edited)) words)")
            return
        }
        let words = original.split(separator: " ").map(String.init)
        let step = 0.3
        let spans = words.enumerated().map { i, w in
            TranscriptSpan(text: w, confidence: 1, audioRange: (Double(i) * step)...(Double(i + 1) * step))
        }
        do { _ = try store.ingestEdit(utteranceID: utteranceID, spans: spans, editedText: edited, at: date) }
        catch { Log.app.error("adapt edit ingest failed: \(error)") }
        personalWER.record(hypothesis: original, finalText: edited, at: date)
        markDirty()
    }

    /// A perfect landing still counts toward the day's denominator.
    public func recordCleanLanding(text: String, at date: Date = Date()) {
        guard !text.isEmpty else { return }
        personalWER.record(hypothesis: text, finalText: text, at: date)
    }

    private func markDirty() { lock.lock(); dirty = true; lock.unlock() }

    /// Timer-driven (and on-demand) retrain; cheap no-op while nothing changed.
    public func retrainIfNeeded() {
        lock.lock()
        let needed = dirty
        dirty = false
        lock.unlock()
        if needed { retrain() }
    }

    @discardableResult
    public func retrain() -> PersonalLexicon {
        let results = loop.retrain()
        if let bias = results.first(where: { $0.feasibility == .trained }) {
            Log.app.info("adapt retrain: \(bias.backend) → \(bias.lexicon.terms.count) terms, \(bias.lexicon.variants.count) variants")
        }
        return loop.lexicon
    }

    /// P6.2 — "Train by voice": store the clip + pair, retrain, and hand back the one-time
    /// "I'll remember …" toast (nil when it was already shown for this word, ever).
    public func trainByVoice(word: String, samples: [Float], heard: String? = nil) -> String? {
        guard let pronunciation, !word.isEmpty else { return nil }
        do { _ = try pronunciation.capture(word: word, samples: samples, heard: heard) }
        catch { Log.app.error("pronunciation capture failed: \(error)"); return nil }
        retrain()
        return rememberToast.toast(forLearned: word)?.message
    }
}

/// P6.1 — `RegressionGuard` as a pipeline stage over the *live* lexicon (re-read per utterance,
/// so a retrain takes effect on the next dictation).
public struct RegressionGuardStage: PipelineStage {
    public let id: StageID = RegressionGuard.stageID
    private let lexicon: @Sendable () -> PersonalLexicon

    public init(lexicon: @escaping @Sendable () -> PersonalLexicon) { self.lexicon = lexicon }

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        RegressionGuard(lexicon: lexicon()).apply(spans)
    }
}

/// Fan-out `CorrectionSink`: history DB + adaptation loop see every correction.
public final class CompositeCorrectionSink: CorrectionSink, @unchecked Sendable {
    private let sinks: [any CorrectionSink]
    public init(sinks: [any CorrectionSink]) { self.sinks = sinks }
    public func record(_ correction: CorrectionRecord) { sinks.forEach { $0.record(correction) } }
}

/// `CorrectionSink` face of the adaptation service.
public final class AdaptationCorrectionSink: CorrectionSink, @unchecked Sendable {
    private let service: AdaptationService
    public init(service: AdaptationService) { self.service = service }
    public func record(_ correction: CorrectionRecord) { service.ingest(correction) }
}

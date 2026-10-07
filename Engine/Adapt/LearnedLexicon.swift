import Foundation
import Shared

/// "Train by voice": the user says the word, we keep the audio + spelling on device and add a
/// training pair so the learner and the regression guard pick it up immediately.
public final class PronunciationCapture: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var word: String
        public var clipFile: String
        public var capturedAt: Date
        public var durationSec: Double
    }
    public let directory: URL
    public let sampleRate: Int
    private let store: TrainingPairStore?
    private let lock = NSLock()
    private var index: [Entry]
    private var indexFile: URL { directory.appendingPathComponent("index.json") }

    public init(directory: URL, sampleRate: Int = 16_000, store: TrainingPairStore? = nil) throws {
        self.directory = directory; self.sampleRate = sampleRate; self.store = store
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        index = (try? Data(contentsOf: directory.appendingPathComponent("index.json"))).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    public var entries: [Entry] { lock.lock(); defer { lock.unlock() }; return index }
    public func entries(for word: String) -> [Entry] { entries.filter { $0.word.lowercased() == word.lowercased() } }

    /// Stores the clip and records a pair (`heard` = what the decoder produced for that clip, if any).
    @discardableResult
    public func capture(word: String, samples: [Float], heard: String? = nil, at: Date = Date()) throws -> Entry {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !samples.isEmpty else { throw CaptureError.empty }
        let name = "\(UUID().uuidString).wav"
        try WAVFile(sampleRate: sampleRate, samples: samples).write(to: directory.appendingPathComponent(name))
        let e = Entry(word: w, clipFile: name, capturedAt: at, durationSec: Double(samples.count) / Double(sampleRate))
        lock.lock(); index.append(e); let snap = index; lock.unlock()
        try JSONEncoder().encode(snap).write(to: indexFile)
        if let store {
            try store.add(TrainingPair(utteranceID: "train:\(e.clipFile)", createdAt: at, original: heard ?? "", corrected: w,
                                       audioRange: 0...e.durationSec, source: "trainByVoice", clipFile: nil))
        }
        return e
    }
    public enum CaptureError: Error { case empty }
}

/// One-time "I'll remember *Kothari*" toast. Shown once per word, ever; the never-repeat set
/// is persisted so a reinstall of the lexicon does not re-toast.
public final class RememberToastModel: @unchecked Sendable {
    public struct Toast: Equatable, Sendable { public var word: String; public var message: String }
    private let file: URL?
    private let lock = NSLock()
    private var shown: Set<String>

    public init(file: URL? = nil) {
        self.file = file
        shown = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
    }

    public static func key(_ word: String) -> String { word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Returns a toast the first time a word is learned; nil every time after.
    public func toast(forLearned word: String) -> Toast? {
        let k = Self.key(word)
        guard !k.isEmpty else { return nil }
        lock.lock()
        let inserted = shown.insert(k).inserted
        let snap = shown
        lock.unlock()
        guard inserted else { return nil }
        if let file { try? JSONEncoder().encode(snap).write(to: file) }
        return Toast(word: word, message: "I'll remember \u{201C}\(word)\u{201D}")
    }

    public func hasShown(_ word: String) -> Bool { lock.lock(); defer { lock.unlock() }; return shown.contains(Self.key(word)) }
}

/// Regression guard: a corrected word is never re-mis-heard. Post-decode `[TranscriptSpan] ->
/// [TranscriptSpan]` pass that replaces a span whose text is a known misheard variant (exact
/// or Double-Metaphone match) with the learned correction. Confidence carries over from the
/// original span; the original text is kept as a `.repair` alternate and provenance is appended.
public struct RegressionGuard: Sendable {
    public static let stageID: StageID = "adapt.lexicon"
    public var lexicon: PersonalLexicon
    public var metaphoneLength: Int
    /// Minimum variant count before phonetic (non-exact) matching kicks in.
    public var phoneticMinCount: Int
    /// Never rewrite spans that sit in an already-learned term's correction (avoid ping-pong).
    private let protected: Set<String>
    private let phonetic: [(codes: DoubleMetaphone.Codes, corrected: String, heard: String)]

    public init(lexicon: PersonalLexicon, metaphoneLength: Int = 6, phoneticMinCount: Int = 1) {
        self.lexicon = lexicon; self.metaphoneLength = metaphoneLength; self.phoneticMinCount = phoneticMinCount
        protected = Set(lexicon.terms.keys)
        let dm = DoubleMetaphone(maxLength: metaphoneLength)
        phonetic = lexicon.variants.values.filter { $0.count >= phoneticMinCount && !$0.heard.contains(" ")
                                                    && LexiconSanity.isPlausibleCorrection(heard: $0.heard, corrected: $0.corrected) }
            .sorted { $0.count > $1.count }
            .map { (dm.encode($0.heard), $0.corrected, $0.heard) }
    }

    public func correction(for text: String) -> String? {
        let k = text.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard !k.isEmpty else { return nil }
        // Already the learned term: only normalise casing ("kothari" -> "Kothari").
        if protected.contains(k) { let t = lexicon.terms[k]!.text; return t == text.trimmingCharacters(in: .punctuationCharacters) ? nil : t }
        // A variant that is not shaped like a respelling of what was heard is not trusted, however
        // it got into the lexicon: pass the decoded word through untouched rather than guess.
        if let v = lexicon.variants[k] {
            return LexiconSanity.isPlausibleCorrection(heard: k, corrected: v.corrected) ? v.corrected : nil
        }
        guard !k.contains(" ") else { return nil }
        let codes = DoubleMetaphone(maxLength: metaphoneLength).encode(k)
        guard !codes.primary.isEmpty else { return nil }
        // C1 undo: a written form the user has undone for this heard word is never proposed again,
        // even when another heard variant of it collides phonetically.
        return phonetic.first { $0.codes.matches(codes) && !lexicon.isBlocked(heard: k, written: $0.corrected) }?.corrected
    }

    public func apply(_ spans: [TranscriptSpan]) -> [TranscriptSpan] {
        spans.map { span in
            guard let fix = correction(for: span.text) else { return span }
            // Preserve trailing punctuation from the decoded token.
            let trailing = String(span.text.reversed().prefix { ".,!?;:".contains($0) }.reversed())
            var out = span
            out.text = fix + trailing
            out.alternates = [Alternate(text: span.text, score: span.confidence, source: .repair)] + span.alternates.filter { $0.text != fix }
            out.provenance.append(Self.stageID)
            out.needsRepair = false
            return out
        }
    }
}

import Foundation

/// P5.1 — the feature vector fed to `DirectedSpeechClassifier`. Every value is roughly unit-scaled
/// so hand-initialised weights stay interpretable. Nothing here is persisted.
public struct DirectedSpeechFeatures: Equatable, Sendable {
    // Prosody
    public var snrDB: Double            // speech level over noise floor, dB / 20
    public var meanLevelDB: Double      // mean speech-frame level, (dBFS + 30) / 20
    public var energyContourSlope: Double // rising (+) vs falling (−) energy across the utterance
    public var voicedRatio: Double      // fraction of frames with a clear autocorrelation pitch peak
    public var zeroCrossingRate: Double // mean ZCR (crossings / sample), ×10
    public var speakingRate: Double     // energy onsets per second / 5
    // Content
    public var keywordScore: Double     // leading-verb / address keyword spotter, 0…1
    public var previewEmpty: Double     // 1 when the streaming preview produced no words
    // Context
    public var isTextFieldFocused: Double
    public var addressedRecently: Double

    public init(snrDB: Double = 0, meanLevelDB: Double = 0, energyContourSlope: Double = 0, voicedRatio: Double = 0,
                zeroCrossingRate: Double = 0, speakingRate: Double = 0, keywordScore: Double = 0, previewEmpty: Double = 0,
                isTextFieldFocused: Double = 0, addressedRecently: Double = 0) {
        self.snrDB = snrDB; self.meanLevelDB = meanLevelDB; self.energyContourSlope = energyContourSlope
        self.voicedRatio = voicedRatio; self.zeroCrossingRate = zeroCrossingRate; self.speakingRate = speakingRate
        self.keywordScore = keywordScore; self.previewEmpty = previewEmpty
        self.isTextFieldFocused = isTextFieldFocused; self.addressedRecently = addressedRecently
    }

    public static let names = ["snrDB", "meanLevelDB", "energyContourSlope", "voicedRatio", "zeroCrossingRate",
                               "speakingRate", "keywordScore", "previewEmpty", "isTextFieldFocused", "addressedRecently"]

    public var vector: [Double] {
        [snrDB, meanLevelDB, energyContourSlope, voicedRatio, zeroCrossingRate, speakingRate,
         keywordScore, previewEmpty, isTextFieldFocused, addressedRecently]
    }
}

/// Context the app knows without any camera/gaze: is a text field focused, were we addressed recently.
public struct DirectedSpeechContext: Equatable, Sendable {
    public var isTextFieldFocused: Bool
    public var addressedRecently: Bool
    public init(isTextFieldFocused: Bool = false, addressedRecently: Bool = false) {
        self.isTextFieldFocused = isTextFieldFocused; self.addressedRecently = addressedRecently
    }
}

/// Tiny keyword spotter over the first words of the streaming ASR preview. Leading imperatives and
/// address forms score high; overheard-conversation openers score zero.
public struct KeywordSpotter: Sendable {
    public static let leadingVerbs: Set<String> = ["type", "send", "write", "reply", "remind", "note", "search", "open", "dear", "please", "tell", "email", "message"]
    public static let addressForms: Set<String> = ["hey", "okay", "ok", "computer", "voice"]
    public static let pronounStarts: Set<String> = ["can", "could", "would", "let", "i", "we", "thanks", "sounds"]

    public init() {}

    public func score(preview: String) -> Double {
        let words = preview.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        guard let first = words.first else { return 0 }
        if Self.leadingVerbs.contains(first) { return 1 }
        if Self.addressForms.contains(first) { return 0.8 }
        let secondIsVerb = words.count > 1 && Self.leadingVerbs.contains(words[1])
        if Self.addressForms.contains(first) && secondIsVerb { return 1 }
        if Self.pronounStarts.contains(first) { return 0.35 }
        return 0
    }
}

/// Prosody + content + context extractor over one VAD-delimited utterance (16 kHz mono).
public struct DirectedSpeechFeatureExtractor: Sendable {
    public var sampleRate: Int = 16_000
    public var frameSize: Int = 320 // 20 ms
    public var spotter = KeywordSpotter()

    public init() {}

    public func extract(samples: [Float], preview: String, context: DirectedSpeechContext) -> DirectedSpeechFeatures {
        var f = DirectedSpeechFeatures()
        let n = samples.count / frameSize
        guard n > 0 else {
            f.previewEmpty = 1; f.isTextFieldFocused = context.isTextFieldFocused ? 1 : 0
            f.addressedRecently = context.addressedRecently ? 1 : 0
            return f
        }
        var levels: [Double] = [], zcrs: [Double] = [], voiced = 0, pitchFrames = 0
        for i in 0..<n {
            let frame = Array(samples[i * frameSize ..< (i + 1) * frameSize])
            var acc: Float = 0, crossings = 0
            for j in 0..<frame.count {
                acc += frame[j] * frame[j]
                if j > 0, (frame[j] >= 0) != (frame[j - 1] >= 0) { crossings += 1 }
            }
            let rms = Double((acc / Float(frame.count)).squareRoot())
            levels.append(20 * log10(max(rms, 1e-6)))
            zcrs.append(Double(crossings) / Double(frame.count))
            if i % 3 == 0 { pitchFrames += 1; if Self.hasPitchPeak(frame, sampleRate: sampleRate) { voiced += 1 } }
        }
        let sorted = levels.sorted()
        let floor = sorted[sorted.count / 10]
        let speechLevel = sorted[sorted.count * 8 / 10]
        let speechFrames = levels.enumerated().filter { $0.element > floor + 6 }
        f.snrDB = (speechLevel - floor) / 20
        f.meanLevelDB = ((speechFrames.isEmpty ? speechLevel : speechFrames.map(\.element).reduce(0, +) / Double(speechFrames.count)) + 30) / 20
        f.energyContourSlope = Self.slope(levels) * Double(n) / 20
        f.voicedRatio = Double(voiced) / Double(max(1, pitchFrames))
        f.zeroCrossingRate = zcrs.reduce(0, +) / Double(n) * 10
        f.speakingRate = Double(Self.onsets(levels, floor: floor)) / (Double(n) * Double(frameSize) / Double(sampleRate)) / 5
        f.keywordScore = spotter.score(preview: preview)
        f.previewEmpty = preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0
        f.isTextFieldFocused = context.isTextFieldFocused ? 1 : 0
        f.addressedRecently = context.addressedRecently ? 1 : 0
        return f
    }

    /// Normalised autocorrelation peak in the 60–400 Hz lag band ≥ 0.5 ⇒ voiced frame.
    static func hasPitchPeak(_ frame: [Float], sampleRate: Int) -> Bool {
        let minLag = sampleRate / 400, maxLag = min(sampleRate / 60, frame.count - 1)
        guard maxLag > minLag else { return false }
        var energy: Float = 0
        for s in frame { energy += s * s }
        guard energy > 1e-6 else { return false }
        var best: Float = 0
        var lag = minLag
        while lag <= maxLag {
            var acc: Float = 0
            for i in 0..<(frame.count - lag) { acc += frame[i] * frame[i + lag] }
            best = max(best, acc / energy)
            lag += 2
        }
        return best >= 0.5
    }

    static func slope(_ y: [Double]) -> Double {
        let n = Double(y.count); guard y.count > 1 else { return 0 }
        let xm = (n - 1) / 2, ym = y.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (i, v) in y.enumerated() { let dx = Double(i) - xm; num += dx * (v - ym); den += dx * dx }
        return den == 0 ? 0 : num / den
    }

    /// Energy onsets: transitions from below floor+6 dB to above, ≥ 80 ms apart (syllable-ish rate proxy).
    static func onsets(_ levels: [Double], floor: Double) -> Int {
        var count = 0, above = false, last = -100
        for (i, l) in levels.enumerated() {
            let now = l > floor + 6
            if now && !above && i - last >= 4 { count += 1; last = i }
            above = now
        }
        return count
    }
}

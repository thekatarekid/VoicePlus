import Foundation

/// Frame-level precision/recall/F1 of predicted speech spans against labelled spans.
public struct VADScore: Equatable, Sendable {
    public var precision: Double
    public var recall: Double
    public var f1: Double { precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall) }

    public static func score(predicted: [ClosedRange<TimeInterval>], truth: [ClosedRange<TimeInterval>], duration: TimeInterval, resolution: TimeInterval = 0.01) -> VADScore {
        let n = Int(duration / resolution)
        var tp = 0, fp = 0, fn = 0
        for i in 0..<n {
            let t = (Double(i) + 0.5) * resolution
            let p = predicted.contains { $0.contains(t) }
            let g = truth.contains { $0.contains(t) }
            if p && g { tp += 1 } else if p { fp += 1 } else if g { fn += 1 }
        }
        let precision = tp + fp == 0 ? 1 : Double(tp) / Double(tp + fp)
        let recall = tp + fn == 0 ? 1 : Double(tp) / Double(tp + fn)
        return VADScore(precision: precision, recall: recall)
    }
}

/// `Fixtures/audio/vad/labels.json`: `{"spans": {file: [[start, end], ...]}}`.
public struct VADLabels: Decodable, Sendable {
    public var spans: [String: [[Double]]]
    public func ranges(for file: String) -> [ClosedRange<TimeInterval>] {
        (spans[file] ?? []).compactMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0]...$0[1] : nil }
    }
    public static func load(url: URL) throws -> VADLabels {
        try JSONDecoder().decode(VADLabels.self, from: Data(contentsOf: url))
    }
}

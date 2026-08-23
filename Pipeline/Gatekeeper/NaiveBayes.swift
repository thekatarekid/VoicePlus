import Foundation

/// Tiny multinomial naive-Bayes over unigram+bigram features with Laplace smoothing.
/// Trained once at init from a seed corpus; classification is a dictionary walk (µs).
struct NaiveBayesClassifier<Label: Hashable & Sendable>: Sendable {
    private var logPrior: [Label: Double] = [:]
    private var logLikelihood: [Label: [String: Double]] = [:]
    private var unseenLogLikelihood: [Label: Double] = [:]
    let labels: [Label]

    init(examples: [(Label, String)]) {
        var counts: [Label: [String: Int]] = [:]
        var totals: [Label: Int] = [:]
        var docs: [Label: Int] = [:]
        var vocab = Set<String>()
        for (label, text) in examples {
            docs[label, default: 0] += 1
            for f in GatekeeperTokenizer.features(GatekeeperTokenizer.words(text)) {
                counts[label, default: [:]][f, default: 0] += 1
                totals[label, default: 0] += 1
                vocab.insert(f)
            }
        }
        labels = Array(docs.keys)
        let v = Double(vocab.count) + 1
        let n = Double(examples.count)
        for label in labels {
            logPrior[label] = log(Double(docs[label] ?? 0) / n)
            let denom = Double(totals[label] ?? 0) + v
            unseenLogLikelihood[label] = log(1 / denom)
            var table: [String: Double] = [:]
            for (f, c) in counts[label] ?? [:] { table[f] = log((Double(c) + 1) / denom) }
            logLikelihood[label] = table
        }
    }

    /// Posterior distribution over labels (normalised), or nil for empty input.
    func posterior(_ text: String) -> [Label: Double]? {
        let feats = GatekeeperTokenizer.features(GatekeeperTokenizer.words(text))
        guard !feats.isEmpty, !labels.isEmpty else { return nil }
        var scores: [Label: Double] = [:]
        for label in labels {
            var s = logPrior[label] ?? 0
            let table = logLikelihood[label] ?? [:]
            let unseen = unseenLogLikelihood[label] ?? 0
            for f in feats { s += table[f] ?? unseen }
            scores[label] = s
        }
        let maxScore = scores.values.max() ?? 0
        var total = 0.0
        var probs: [Label: Double] = [:]
        for (label, s) in scores { let p = exp(s - maxScore); probs[label] = p; total += p }
        for label in probs.keys { probs[label]! /= total }
        return probs
    }

    func best(_ text: String) -> (label: Label, probability: Double)? {
        guard let p = posterior(text), let top = p.max(by: { $0.value < $1.value }) else { return nil }
        return (top.key, top.value)
    }
}

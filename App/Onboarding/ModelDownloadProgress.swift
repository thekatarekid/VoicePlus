import Foundation

/// One progress report for the model install.
///
/// The old callback was a bare `Double`, so the only thing the screen could say was "Downloading…
/// 46%". A percentage with no denominator is exactly what the 1.6.6 user could not act on: they
/// picked a model, saw the next screen instantly, and had no way to tell whether a 900 MB download
/// had even started. Bytes and the name of the model currently being fetched come from
/// `DownloadProgressInfo`, which has carried them all along.
public struct ModelDownloadProgress: Equatable, Sendable {
    /// 0…1 across the whole install, not just the model in flight.
    public var fraction: Double
    public var bytesReceived: Int64
    /// Total for the whole install. Zero when the server sent no length.
    public var bytesExpected: Int64
    /// Catalog display name of the model being fetched right now.
    public var modelName: String
    /// 1-based position of that model in the install, and how many there are.
    public var index: Int
    public var count: Int

    public init(fraction: Double, bytesReceived: Int64, bytesExpected: Int64,
                modelName: String, index: Int = 1, count: Int = 1) {
        self.fraction = min(max(fraction, 0), 1)
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
        self.modelName = modelName
        self.index = index
        self.count = count
    }

    public var percent: Int { Int((fraction * 100).rounded()) }
}

/// Decimal MB/GB, the way download sizes are advertised — and identical in every locale, so the
/// copy is assertable in a test (`ByteCountFormatter` is not).
public enum ByteText {
    public static func short(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 MB" }
        if bytes < 1_000_000 { return "\(max(1, Int((Double(bytes) / 1_000).rounded()))) KB" }
        if bytes < 1_000_000_000 { return "\(Int((Double(bytes) / 1_000_000).rounded())) MB" }
        return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}

/// Turns progress + elapsed time into the sentence under the bar. Pure, so "a sense of time" is a
/// test rather than something only observable on a slow connection.
public enum DownloadProgressText {
    /// Below this fraction an estimate is noise — a 900 MB download that is 1 % done after two
    /// seconds would claim "about 3 minutes" and then triple it.
    public static let minimumFractionForEstimate = 0.05
    /// And below this much elapsed time there is not enough of a rate to extrapolate from.
    public static let minimumElapsedForEstimate: TimeInterval = 3

    /// e.g. `Downloading Parakeet TDT 0.6B v3 — 412 MB of 900 MB (46%), about 2 min left`
    public static func line(_ progress: ModelDownloadProgress, elapsed: TimeInterval) -> String {
        var text = "Downloading \(progress.modelName)"
        if progress.count > 1 { text += " (\(progress.index) of \(progress.count))" }
        text += " — "
        if progress.bytesExpected > 0 {
            text += "\(ByteText.short(progress.bytesReceived)) of \(ByteText.short(progress.bytesExpected)) (\(progress.percent)%)"
        } else {
            text += "\(progress.percent)%"
        }
        if let remaining = remaining(progress, elapsed: elapsed) { text += ", \(remaining) left" }
        return text
    }

    /// Nil until the estimate would mean anything — saying nothing beats saying a number that moves
    /// by a factor of three on the next tick.
    public static func remaining(_ progress: ModelDownloadProgress, elapsed: TimeInterval) -> String? {
        guard progress.fraction >= minimumFractionForEstimate,
              progress.fraction < 1,
              elapsed >= minimumElapsedForEstimate else { return nil }
        let total = elapsed / progress.fraction
        return duration(total - elapsed)
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return "a few seconds" }
        if seconds < 90 { return "about \(Int((seconds / 5).rounded()) * 5) seconds" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) min" }
        let hours = Double(minutes) / 60
        return "about \(String(format: "%.1f", hours)) hours"
    }
}

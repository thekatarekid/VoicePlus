import Foundation

// V5 J5 — the Sparkle-compatible appcast `Packaging/release.sh` publishes (`Packaging/appcast.xml`),
// read without a Sparkle dependency. One `<item>` per release; the full enclosure is the
// self-contained DMG (bundled models), an optional `<sparkle:deltas>` enclosure keyed by
// `sparkle:deltaFrom` is the small DMG (thin app, models carried over from the installed copy).

/// Which releases a user is offered. Items without `<sparkle:channel>` belong to `.release`.
public enum UpdateChannel: String, CaseIterable, Sendable, Codable {
    case release
    /// Nightly / pre-release builds (`release.sh nightly …` writes `<sparkle:channel>beta`).
    case beta

    /// Channels whose items this channel sees: beta users also get every release.
    public var accepts: Set<String> {
        switch self {
        case .release: return ["release"]
        case .beta: return ["release", "beta"]
        }
    }

    public var title: String {
        switch self {
        case .release: return "Release"
        case .beta: return "Beta (nightly builds)"
        }
    }
}

public struct AppcastEnclosure: Equatable, Sendable {
    public var url: URL
    /// Bytes; 0 when the feed did not say.
    public var length: Int64
    /// Lower-case hex SHA-256 of the DMG (`sha256="…"`, written by release.sh). Nil on older items.
    public var sha256: String?
    /// `sparkle:edSignature` — kept for a future EdDSA key; not verified (no key, documented deviation).
    public var edSignature: String?
    /// For a delta: the installed build (`sparkle:version`) this small DMG applies to.
    public var deltaFrom: String?
}

public struct AppcastItem: Equatable, Sendable {
    public var title: String
    /// `sparkle:version` — the build number compared against `CFBundleVersion`.
    public var build: String
    /// `sparkle:shortVersionString` — what the user is shown.
    public var shortVersion: String
    public var minimumSystemVersion: String?
    /// Nil means the default (`release`) channel.
    public var channel: String?
    public var releaseNotes: URL?
    public var full: AppcastEnclosure?
    public var deltas: [AppcastEnclosure]

    public var displayVersion: String { shortVersion.isEmpty ? build : shortVersion }
}

/// Which DMG an update downloads.
public enum UpdatePayloadKind: String, Equatable, Sendable {
    /// Small DMG for exactly the installed build (`deltaFrom` matches).
    case delta
    /// Self-contained DMG.
    case full
}

public struct UpdateOffer: Equatable, Sendable {
    public var item: AppcastItem
    public var kind: UpdatePayloadKind
    public var enclosure: AppcastEnclosure
}

// MARK: - Version ordering

public enum BuildVersion {
    /// Numeric, component-wise ("1.10.0" > "1.9.9"; "202609191856" > "202609110439"); a trailing
    /// missing component counts as 0. Non-numeric runs separate components.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let lhs = components(a), rhs = components(b)
        for i in 0..<max(lhs.count, rhs.count) {
            let x = i < lhs.count ? lhs[i] : 0, y = i < rhs.count ? rhs[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }

    static func components(_ s: String) -> [UInt64] {
        s.split(whereSeparator: { !$0.isNumber }).map { UInt64($0) ?? 0 }
    }

    /// `OperatingSystemVersion` as "major.minor.patch".
    public static func string(_ v: OperatingSystemVersion) -> String {
        "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

// MARK: - Selection

public enum AppcastSelector {
    /// The newest item newer than `installedBuild` on `channel` that this OS can run, with the
    /// payload to fetch: the delta when one is keyed to the installed build, else the full DMG.
    /// Items with no usable https enclosure are skipped (never offered half-formed).
    public static func offer(in items: [AppcastItem], installedBuild: String, channel: UpdateChannel,
                             systemVersion: String) -> UpdateOffer? {
        let eligible = items.filter { item in
            channel.accepts.contains(item.channel ?? "release")
                && BuildVersion.isNewer(item.build, than: installedBuild)
                && item.minimumSystemVersion.map { BuildVersion.compare(systemVersion, $0) != .orderedAscending } ?? true
        }
        let ordered = eligible.sorted { BuildVersion.isNewer($0.build, than: $1.build) }
        for item in ordered {
            if let delta = item.deltas.first(where: { $0.deltaFrom == installedBuild && isSecure($0.url) }) {
                return UpdateOffer(item: item, kind: .delta, enclosure: delta)
            }
            if let full = item.full, isSecure(full.url) {
                return UpdateOffer(item: item, kind: .full, enclosure: full)
            }
        }
        return nil
    }

    /// Only https downloads are ever offered.
    public static func isSecure(_ url: URL) -> Bool { url.scheme?.lowercased() == "https" }
}

// MARK: - Parsing

public enum AppcastParseError: Error, Equatable {
    case malformed(String)
}

public enum AppcastParser {
    public static func parse(_ data: Data) throws -> [AppcastItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw AppcastParseError.malformed(parser.parserError?.localizedDescription ?? "unknown")
        }
        return delegate.items
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var current: AppcastItem?
        private var text = ""
        private var inDeltas = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "item":
                current = AppcastItem(title: "", build: "", shortVersion: "", minimumSystemVersion: nil,
                                      channel: nil, releaseNotes: nil, full: nil, deltas: [])
            case "sparkle:deltas":
                inDeltas = true
            case "enclosure":
                guard current != nil, let raw = attributes["url"], let url = URL(string: raw) else { return }
                let enclosure = AppcastEnclosure(
                    url: url, length: Int64(attributes["length"] ?? "") ?? 0,
                    sha256: attributes["sha256"]?.lowercased(), edSignature: attributes["sparkle:edSignature"],
                    deltaFrom: attributes["sparkle:deltaFrom"])
                if inDeltas {
                    current?.deltas.append(enclosure)
                } else {
                    current?.full = enclosure
                    // Sparkle also allows version attributes on the enclosure itself.
                    if let v = attributes["sparkle:version"] { current?.build = v }
                    if let v = attributes["sparkle:shortVersionString"] { current?.shortVersion = v }
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { text = "" }
            guard current != nil else { return }
            switch name {
            case "title": current?.title = value
            case "sparkle:version": current?.build = value
            case "sparkle:shortVersionString": current?.shortVersion = value
            case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = value.isEmpty ? nil : value
            case "sparkle:channel": current?.channel = value.isEmpty ? nil : value
            case "sparkle:releaseNotesLink": current?.releaseNotes = URL(string: value)
            case "sparkle:deltas": inDeltas = false
            case "item":
                if let item = current, !item.build.isEmpty { items.append(item) }
                current = nil
            default: break
            }
        }
    }
}

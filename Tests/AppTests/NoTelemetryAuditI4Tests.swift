import Foundation
import Lab
import Shared
import Testing

/// V5 I4 [keep] — no telemetry, enforced on the source tree: no analytics / crash-reporting SDK is
/// imported or depended on, no such host is named anywhere in product code, and every host product
/// code names is on the reviewed egress list (`EgressReview`).
@Suite("V5 I4 — no telemetry (source audit)")
struct NoTelemetryAuditI4Tests {
    static let productDirectories = ["Shared", "Engine", "Pipeline", "Injection", "App", "Providers", "Lab",
                                     "Actions", "Sync", "iOS/KeyboardCore"]

    static let forbiddenModules = ["Sentry", "PostHog", "Mixpanel", "Amplitude", "AmplitudeSwift", "Segment",
                                   "Analytics", "FirebaseAnalytics", "FirebaseCrashlytics", "FirebaseCore",
                                   "Crashlytics", "AppCenter", "AppCenterAnalytics", "AppCenterCrashes",
                                   "Bugsnag", "DatadogCore", "DatadogRUM", "TelemetryDeck", "TelemetryClient",
                                   "Countly", "Instabug", "Aptabase", "NewRelic", "Rollbar", "Heap"]

    static func root() throws -> URL {
        try #require(AppPaths.fixturesDirectory()).deletingLastPathComponent()
    }

    /// (relative path, contents) of every product Swift file.
    static func productSources() throws -> [(String, String)] {
        let root = try root()
        var out: [(String, String)] = []
        for dir in productDirectories {
            let base = root.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                out.append((String(url.path.dropFirst(root.path.count + 1)), text))
            }
        }
        return out
    }

    static func hosts(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"https?://([A-Za-z0-9.-]+)"#)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
    }

    @Test func auditSeesTheWholeTree() throws {
        let sources = try Self.productSources()
        #expect(sources.count > 300)
        #expect(sources.contains { $0.0 == "Lab/DataPanel/EgressGate.swift" })
        #expect(sources.contains { $0.0.hasPrefix("iOS/KeyboardCore/") })
    }

    @Test func noAnalyticsOrCrashReportingImports() throws {
        var offenders: [String] = []
        for (path, text) in try Self.productSources() {
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("import ") || t.hasPrefix("@_exported import ") || t.hasPrefix("@testable import ") else { continue }
                let module = t.split(separator: " ").last.map(String.init) ?? ""
                if Self.forbiddenModules.contains(module) { offenders.append("\(path): \(t)") }
            }
        }
        #expect(offenders.isEmpty, "telemetry SDK imported: \(offenders)")
    }

    /// Word lists that are data, not code: a brand's casing ("PostHog") is dictation vocabulary.
    static let vocabularyData: Set<String> = ["Pipeline/Dictionaries/CasingLexicon+Bundled.swift"]

    /// Hosts written with a scheme, or as a bare quoted literal ("api.mixpanel.com").
    static func hostLiterals(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #""([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)[/"]"#)
        let ns = text as NSString
        let bare = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).lowercased()
        }
        return hosts(in: text) + bare
    }

    @Test func noTelemetryHostOrVendorNamedInProductCode() throws {
        var offenders: [String] = []
        for (path, text) in try Self.productSources() where path != "Lab/DataPanel/EgressReview.swift" {
            for host in Self.hostLiterals(in: text) where EgressReview.isForbidden(host: host) {
                offenders.append("\(path): \(host)")
            }
            guard !Self.vocabularyData.contains(path) else { continue }
            // The two vendors the build doc names, as whole words in any form.
            let lower = text.lowercased()
            for word in ["posthog", "sentry"] where lower.range(of: "\\b\(word)\\b", options: .regularExpression) != nil {
                offenders.append("\(path): \(word)")
            }
        }
        #expect(offenders.isEmpty, "telemetry vendor named: \(offenders)")
    }

    @Test func forbiddenHostLiteralsAreCaught() {
        let sample = #"let a = URL(string: "https://us.i.posthog.com/e")!; let b = "api.mixpanel.com"; segment.command"#
        let hosts = Self.hostLiterals(in: sample)
        #expect(hosts.contains("us.i.posthog.com") && hosts.contains("api.mixpanel.com"))
        #expect(hosts.filter(EgressReview.isForbidden).count == 2)
    }

    @Test func noTelemetryDependency() throws {
        let root = try Self.root()
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8).lowercased()
        let resolved = (try? String(contentsOf: root.appendingPathComponent("Package.resolved"), encoding: .utf8))?.lowercased() ?? ""
        for vendor in ["sentry", "posthog", "mixpanel", "amplitude", "segment", "firebase", "crashlytics", "appcenter",
                       "bugsnag", "datadog", "telemetrydeck", "countly", "instabug", "aptabase", "newrelic", "rollbar"] {
            #expect(!manifest.contains(vendor), "Package.swift mentions \(vendor)")
            #expect(!resolved.contains(vendor), "Package.resolved pins \(vendor)")
        }
    }

    @Test func everyNamedHostIsReviewed() throws {
        var unreviewed: [String: String] = [:]
        for (path, text) in try Self.productSources() {
            for host in Self.hosts(in: text) where !EgressReview.isReviewed(host: host) {
                unreviewed[host] = path
            }
        }
        #expect(unreviewed.isEmpty, "add each host to EgressReview.hosts with its reason, or remove it: \(unreviewed)")
    }

    @Test func reviewedListHasNoTelemetryAndEveryEntryHasAReason() {
        for (host, reason) in EgressReview.hosts {
            #expect(!EgressReview.isForbidden(host: host), "\(host) is a telemetry host")
            #expect(!reason.trimmingCharacters(in: .whitespaces).isEmpty, "\(host) has no reason")
            #expect(host == host.lowercased())
        }
        #expect(EgressReview.isForbidden(host: "us.i.posthog.com"))
        #expect(EgressReview.isForbidden(host: "o1.ingest.sentry.io"))
        #expect(!EgressReview.isReviewed(host: "api.mixpanel.com"))
    }

    @Test func killSwitchStillDeniesReviewedHosts() {
        let name = "i4-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = EgressGate(defaults: defaults)
        gate.isKillSwitchOn = true
        for host in EgressReview.hosts.keys.sorted() { #expect(!gate.isAllowed(host: host)) }
        gate.isKillSwitchOn = false
        #expect(gate.isAllowed(host: "huggingface.co"))
    }
}

import Foundation
import Shared
import Testing

/// V5 J2 — the CI workflow and the script it runs. The workflow itself only runs on GitHub; this
/// checks its shape so a local edit cannot silently re-enable push triggers (owner decision 0b35cf7:
/// manual only) or drop the non-hardware / --no-parallel contract.
@Suite("V5 J2 — CI workflow")
struct CIWorkflowJ2Tests {
    static func root() throws -> URL { try #require(AppPaths.fixturesDirectory()).deletingLastPathComponent() }
    static func read(_ path: String) throws -> String {
        try String(contentsOf: try root().appendingPathComponent(path), encoding: .utf8)
    }

    /// The `on:` block, up to the next top-level key.
    static func triggers(_ yml: String) -> String {
        var lines: [Substring] = []
        var inside = false
        for line in yml.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("on:") { inside = true; continue }
            if inside, let first = line.first, !first.isWhitespace, first != "#" { break }
            if inside { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    @Test func manualTriggerOnly() throws {
        let on = Self.triggers(try Self.read(".github/workflows/ci.yml"))
        #expect(on.contains("workflow_dispatch:"))
        for trigger in ["push:", "pull_request:", "schedule:", "pull_request_target:", "workflow_run:"] {
            #expect(!on.contains(trigger), "CI must stay manual-only; found \(trigger)")
        }
    }

    @Test func runsTheSharedScriptOnMacOS15AndUploadsTheLog() throws {
        let yml = try Self.read(".github/workflows/ci.yml")
        #expect(yml.contains("run: Scripts/ci-test.sh"))
        #expect(yml.contains("'macos-15'"))
        #expect(yml.contains("self-hosted"))
        #expect(yml.contains("actions/upload-artifact"))
        #expect(yml.contains(".build-ci/test.log"))
        #expect(yml.contains("if: always()"))
    }

    @Test func scriptBootstrapsBuildsAndTestsSerially() throws {
        let script = try Self.read("Scripts/ci-test.sh")
        #expect(script.contains("bootstrap-toolchain.sh"))
        #expect(script.contains("swift build --scratch-path"))
        #expect(script.contains("--no-parallel"))
        #expect(script.contains("unset \"$var\""))
        #expect(script.contains("VOICEPLUS_HARDWARE_TESTS"))
        let root = try Self.root()
        #expect(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("Scripts/ci-test.sh").path))
    }

    @Test func scriptParses() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", try Self.root().appendingPathComponent("Scripts/ci-test.sh").path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    /// Every test target is in the CI filter (a new target must be added deliberately).
    @Test func filterCoversEveryTestTarget() throws {
        let manifest = try Self.read("Package.swift")
        let script = try Self.read("Scripts/ci-test.sh")
        let regex = try NSRegularExpression(pattern: #"testTarget\(name: "([A-Za-z]+)""#)
        let ns = manifest as NSString
        let targets = regex.matches(in: manifest, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
        #expect(!targets.isEmpty)
        for target in targets { #expect(script.contains(target), "\(target) missing from the CI filter") }
    }
}

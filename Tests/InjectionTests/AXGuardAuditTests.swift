import Foundation
import Testing
import Shared
@testable import Injection

/// K18 — every AX caller goes through the own-pid / main-thread guards. The source audit (pattern
/// of `AmbientNeverInjectsTests`) fails if anyone creates an AX root outside the guarded places.
@Suite struct AXGuardAuditTests {
    /// The only files allowed to create AX roots: the guard itself, and the two guarded live accessors.
    static let allowed: Set<String> = ["Shared/Services/AXGuard.swift",
                                       "Injection/LiveSystemAccess.swift",
                                       "Injection/AXReader/LiveAXNodeAccess.swift"]
    static let patterns = ["AXUIElementCreateApplication(", "AXUIElementCreateSystemWide("]
    static let sourceDirectories = ["App", "Actions", "Engine", "Injection", "Lab", "Pipeline", "Providers", "Shared", "Sync"]

    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func offenders(root: URL) -> [String] {
        var hits: [String] = []
        let base = root.resolvingSymlinksInPath().path
        let fm = FileManager.default
        for dir in sourceDirectories {
            guard let walker = fm.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let relative = String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1))
                guard !allowed.contains(relative), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for (n, line) in text.components(separatedBy: "\n").enumerated() {
                    let code = line.components(separatedBy: "//").first ?? line
                    if patterns.contains(where: code.contains) { hits.append("\(relative):\(n + 1)") }
                }
            }
        }
        return hits
    }

    @Test func noAXRootIsCreatedOutsideTheGuards() throws {
        let root = Self.packageRoot
        try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path),
                     "the audit could not find the checkout — it must fail, not pass quietly")
        let hits = Self.offenders(root: root)
        #expect(hits.isEmpty, "AX roots created outside AXGuard / LiveSystemAccess / LiveAXNodeAccess: \(hits)")
    }

    @Test func theAuditCatchesAPlantedOffender() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("k18-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("App/UI")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "let a = AXUIElementCreateApplication(pid)\n// AXUIElementCreateSystemWide() in a comment is fine\n"
            .write(to: dir.appendingPathComponent("Bad.swift"), atomically: true, encoding: .utf8)
        #expect(Self.offenders(root: root) == ["App/UI/Bad.swift:1"])
    }

    @Test func theTenK18SitesUseTheGuard() throws {
        let sites = ["Pipeline/Transform/SelectionDetector.swift", "App/Overlay/TapeFlightTarget.swift",
                     "App/UI/Marks/DestinationMarksOverlay.swift", "App/Settings/RecoverySheetServices.swift",
                     "App/Repair/RepairFanoutPanel.swift", "Injection/AXReader/LiveAXNodeAccess.swift",
                     "Actions/Deterministic/LiveActionSystem.swift", "Actions/Deixis/AXRegionText.swift",
                     "Actions/Deixis/AXHitTesting.swift", "Engine/Biasing/LiveProviders.swift"]
        for site in sites {
            let text = try String(contentsOf: Self.packageRoot.appendingPathComponent(site), encoding: .utf8)
            #expect(text.contains("AXGuard."), "\(site) does not route through AXGuard")
        }
    }

    // MARK: The rule itself

    @Test func ownPidIsRefused() {
        #expect(AXGuard.application(pid: AXGuard.ownPID) == nil)
        #expect(AXGuard.application(pid: 0) == nil)
        #expect(AXGuard.application(pid: AXGuard.ownPID + 1) != nil)
    }

    @Test func ownElementOffMainIsRefusedOnMainAdmitted() {
        #expect(AXGuard.refuses(elementPID: 42, ownPID: 42, isMainThread: false))
        #expect(!AXGuard.refuses(elementPID: 42, ownPID: 42, isMainThread: true))
        #expect(!AXGuard.refuses(elementPID: 7, ownPID: 42, isMainThread: false))
    }

    @Test func onMainHopsAndReturnsTheValue() async {
        let onMain = await Task.detached { AXGuard.onMain { Thread.isMainThread } }.value
        #expect(onMain == true)
    }

    @Test func liveSettleObserverRefusesOwnPid() {
        #expect(LiveSystemAccess().waitForFocusedChange(pid: AXGuard.ownPID, timeoutMilliseconds: 30) == nil)
    }
}

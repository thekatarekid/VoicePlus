import Foundation

/// The four layers of the stack (Build doc P1.8 T1). Raw values are what `injection_outcomes.method` stores.
public enum InjectionMethod: String, CaseIterable, Codable, Sendable, Equatable {
    case ax          // ① AXUIElement value / selected-text insertion at the caret
    case keystroke   // ② synthesized Unicode CGEvents posted to the focused PID
    case adapter     // ③ per-app adapter (bracketed paste, cell mode, …)
    case paste       // ④ clipboard paste with full save/restore — last resort

    public static let defaultOrder: [InjectionMethod] = [.ax, .keystroke, .adapter, .paste]
}

public struct InjectionRequest: Equatable, Sendable {
    public var text: String
    public var utteranceID: String?
    /// Focus captured at hotkey release; injection aborts if the frontmost app/element differs.
    public var expectedFocus: FocusSnapshot?

    public init(text: String, utteranceID: String? = nil, expectedFocus: FocusSnapshot? = nil) {
        self.text = text
        self.utteranceID = utteranceID
        self.expectedFocus = expectedFocus
    }
}

public enum InjectionOutcome: Equatable, Sendable {
    /// Landed; `verified` is true when AX readback confirmed the text.
    case injected(method: InjectionMethod, verified: Bool)
    /// Focus changed between key-release and injection — nothing was typed; request was queued.
    case abortedFocusChanged(expected: FocusSnapshot?, actual: FocusSnapshot?)
    /// Every method was tried (or refused) and none landed.
    case failed(attempts: [InjectionMethod])

    public var succeeded: Bool {
        if case .injected = self { return true }
        return false
    }
}

/// Minimal interface the rest of the app depends on.
public protocol Injector: AnyObject {
    func inject(_ request: InjectionRequest) -> InjectionOutcome
}

/// Where outcome telemetry lives. Local only — never leaves the machine.
public protocol InjectionOutcomeStore: AnyObject {
    func record(_ outcome: Shared.InjectionOutcomeRecord)
    func outcomes(appBundleID: String, limit: Int) -> [Shared.InjectionOutcomeRecord]
}

import Shared

public final class InMemoryOutcomeStore: InjectionOutcomeStore {
    public private(set) var records: [InjectionOutcomeRecord] = []
    public init() {}
    public func record(_ outcome: InjectionOutcomeRecord) { records.append(outcome) }
    public func outcomes(appBundleID: String, limit: Int) -> [InjectionOutcomeRecord] {
        Array(records.filter { $0.appBundleID == appBundleID }.suffix(limit).reversed())
    }
}

/// GRDB-backed store using the `injection_outcomes` table from P1.0.
public final class DatabaseOutcomeStore: InjectionOutcomeStore {
    private let db: AppDatabase
    public init(database: AppDatabase) { db = database }
    public func record(_ outcome: InjectionOutcomeRecord) {
        do { try db.insert(outcome) } catch { Log.injection.error("outcome insert failed: \(error)") }
    }
    public func outcomes(appBundleID: String, limit: Int) -> [InjectionOutcomeRecord] {
        (try? db.injectionOutcomes(appBundleID: appBundleID, limit: limit)) ?? []
    }
}

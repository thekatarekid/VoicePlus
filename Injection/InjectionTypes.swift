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

/// Why the stack refused to post anything at all (R2.3). Distinct from `.failed`: no method ran,
/// so nothing can have landed anywhere.
public enum InjectionRefusal: String, Codable, Sendable, Equatable, CaseIterable {
    /// The focused element is a password field (`AXSecureTextField`, or that subrole).
    case secureField = "secure field"
    /// The destination app is on the never-inject list in settings.
    case neverInject = "never-inject list"

    /// Whether the committed text survives the refusal as *held* text the user can still
    /// insert elsewhere or copy. A password field is a hard no — dictation into a password
    /// field is never what the user wanted, and keeping it around keeps a secret in memory.
    /// A never-inject app is a routing choice, so the text is kept for Copy / Insert here.
    public var holdsText: Bool { self == .neverInject }
}

public enum InjectionOutcome: Equatable, Sendable {
    /// Landed (or possibly landed); `verified` is true only when readback confirmed the text.
    ///
    /// **Readback rule (V3 §6, §14.4).** A method that posted anything without throwing has
    /// *possibly landed*. When readback cannot confirm it the outcome is
    /// `.injected(method:, verified: false)` — never a retry with another method.
    case injected(method: InjectionMethod, verified: Bool)
    /// Focus changed before anything was posted — nothing was typed; the text is now *held*
    /// (`FocusGuard.held`) and waits for Insert here / Copy / Discard. Returning focus alone
    /// does not insert it.
    case abortedFocusChanged(expected: FocusSnapshot?, actual: FocusSnapshot?)
    /// Every method threw before posting anything (or there was no destination at all).
    case failed(attempts: [InjectionMethod])
    /// The stack declined to post: a secure field, or an app on the never-inject list.
    case refused(InjectionRefusal)

    public var succeeded: Bool {
        if case .injected = self { return true }
        return false
    }
}

public extension InjectionOutcome {
    /// The R2.1 `DeliveryOutcome` this maps to — what the pill and the log store show.
    /// `held` is not terminal: it is waiting for the user.
    var delivery: DeliveryOutcome {
        switch self {
        case let .injected(method, verified):
            return .delivered(verified: verified, method: method.rawValue)
        case .abortedFocusChanged:
            return .held(reason: DeliveryReason.destinationChanged)
        case let .failed(attempts):
            return .failed(reason: attempts.isEmpty ? DeliveryReason.noDestination : DeliveryReason.everyMethodThrew)
        case let .refused(refusal):
            return refusal.holdsText ? .held(reason: refusal.rawValue) : .failed(reason: refusal.rawValue)
        }
    }
}

/// The exact reason strings that travel in `DeliveryOutcome` and into held rows, in one place so
/// the pill copy (R2.4) and the tests agree on them.
public enum DeliveryReason {
    public static let destinationChanged = "destination changed"
    public static let noDestination = "no destination"
    public static let everyMethodThrew = "every method threw"
    public static let secureField = InjectionRefusal.secureField.rawValue
    public static let neverInject = InjectionRefusal.neverInject.rawValue
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

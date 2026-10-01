import Foundation

// MARK: - V5 CU1 · consent defaults (Settings › Computer use)
//
// The classifier decides how dangerous an action is (Bet 7). The policy decides how the user wants
// each class handled. It can only ever make handling *stricter*: a reversible action may be made to
// show an undo toast or ask first, a semi-reversible one may be made to ask first, and an
// irreversible one always asks — there is no setting that lets anything irreversible run unasked.

public struct ConsentPolicy: Equatable, Sendable, Codable {
    /// How reversible actions (focus, scroll, open a tab) are handled.
    public enum ReversibleHandling: String, CaseIterable, Sendable, Codable {
        /// Default: just do it.
        case run
        /// Do it, then show the undo toast.
        case undoToast
        /// Ask first.
        case confirm
    }

    /// How semi-reversible actions (archive, move, close) are handled.
    public enum SemiHandling: String, CaseIterable, Sendable, Codable {
        /// Default: do it, then show the undo toast.
        case undoToast
        /// Ask first.
        case confirm
    }

    public var reversible: ReversibleHandling
    public var semi: SemiHandling

    public init(reversible: ReversibleHandling = .run, semi: SemiHandling = .undoToast) {
        self.reversible = reversible
        self.semi = semi
    }

    /// Reversible → run, semi → undo toast, irreversible → confirm.
    public static let `default` = ConsentPolicy()

    /// The class the engine treats `classified` as. Never less dangerous than `classified`.
    public func effective(_ classified: Reversibility) -> Reversibility {
        switch classified {
        case .irreversible:
            return .irreversible
        case .semi:
            return semi == .confirm ? .irreversible : .semi
        case .reversible:
            switch reversible {
            case .run: return .reversible
            case .undoToast: return .semi
            case .confirm: return .irreversible
            }
        }
    }
}

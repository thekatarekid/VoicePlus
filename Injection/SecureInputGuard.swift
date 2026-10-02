import Carbon
import Foundation
import Shared

/// N4 — whether macOS secure event input is on (`IsSecureEventInputEnabled`). A password prompt,
/// a terminal's "Secure Keyboard Entry", 1Password's unlock field: all turn it on. A separate
/// protocol so existing `SystemAccess` conformers compile unchanged.
public protocol SecureInputReading: AnyObject {
    var isSecureEventInputEnabled: Bool { get }
}

/// N4 — the one safety check right before a write: never type into a password field, and never
/// write blind (no readable field) while macOS secure input is on — the likeliest blind target then
/// is a password prompt. Pure over its inputs; the live probe is `SecureInputGuard.isActive`.
/// L3's pull-back uses `blocksWrite(focused:secureInput:)` before re-typing into the original window.
public enum SecureInputGuard {
    /// Live: is macOS secure event input enabled right now (by any process)?
    public static var isActive: Bool { IsSecureEventInputEnabled() }

    /// Why a write must not happen, or `nil` when it may.
    public enum Block: String, Equatable, Sendable {
        /// The focused element is a password field (role or subrole `AXSecureTextField`).
        case passwordField = "password field"
        /// Secure input is on and the focused field cannot be read (nothing to prove it is not a password prompt).
        case secureInputBlindWrite = "secure input on, field unreadable"
    }

    /// A field is readable when it exists and exposes its value.
    public static func isReadable(_ focused: FocusedElementInfo?) -> Bool { focused?.value != nil }

    /// Password field → always blocked. Secure input on + no readable field → blocked.
    /// Secure input on with a readable, non-secure field → allowed (secure input is often held by
    /// another app, e.g. a terminal with Secure Keyboard Entry, and the field proves itself).
    public static func blocksWrite(focused: FocusedElementInfo?, secureInput: Bool) -> Block? {
        if focused?.isSecure == true { return .passwordField }
        if secureInput, !isReadable(focused) { return .secureInputBlindWrite }
        return nil
    }

    /// Reads the flag from `system` when it can report it; a `SystemAccess` that cannot is assumed
    /// to be a test double with secure input off.
    public static func isActive(on system: AnyObject) -> Bool {
        (system as? SecureInputReading)?.isSecureEventInputEnabled ?? false
    }
}

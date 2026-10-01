import ApplicationServices
import Foundation
import Pipeline
import Shared

/// V5 E6 — the raw reads behind `ThreadParticipants`: the focused window's labelled recipient
/// fields, its title and its conversation heading. Additive: `SystemAccess` is unchanged.
public protocol ThreadParticipantsReading: AnyObject {
    func observe(pid: Int32, category: AppCategory) -> ThreadParticipants.Observation
}

/// Live AX walk over the focused window of `pid` (never our own process), bounded in nodes and
/// depth, every element with a short messaging timeout. Mail: text fields / combo boxes / token
/// fields whose label is To or Cc (their value, else their tokens' titles). Chat: the window
/// title, and the first short `AXHeading` as the conversation header.
///
/// Untested here: needs a running Mail / Slack / browser and the Accessibility grant (T1).
public final class LiveThreadParticipants: ThreadParticipantsReading, @unchecked Sendable {
    public var timeout: Float = 0.15
    public var maxNodes = 600
    public var maxDepth = 14

    public init() {}

    public func observe(pid: Int32, category: AppCategory) -> ThreadParticipants.Observation {
        guard pid != getpid(), category == .mail || category == .chat else { return .init() }
        guard let app = AXGuard.application(pid: pid) else { return .init() }
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let window = element(app, kAXFocusedWindowAttribute) else { return .init() }
        var observation = ThreadParticipants.Observation(title: string(window, kAXTitleAttribute))
        var budget = maxNodes
        walk(window, depth: 0, budget: &budget, category: category, into: &observation)
        return observation
    }

    private static let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXTokenField", "AXList", "AXGroup"]

    private func walk(_ node: AXUIElement, depth: Int, budget: inout Int,
                      category: AppCategory, into out: inout ThreadParticipants.Observation) {
        guard budget > 0, depth <= maxDepth else { return }
        budget -= 1
        AXUIElementSetMessagingTimeout(node, timeout)
        let role = string(node, kAXRoleAttribute) ?? ""
        if role == "AXSecureTextField" || string(node, kAXSubroleAttribute) == "AXSecureTextField" { return }
        if category == .mail, Self.fieldRoles.contains(role), let label = label(of: node),
           ThreadParticipants.isRecipientLabel(label) {
            let value = string(node, kAXValueAttribute) ?? tokens(of: node).joined(separator: ", ")
            if !value.isEmpty { out.fields.append(.init(label: label, value: String(value.prefix(1_000)))) }
            return
        }
        if category == .chat, out.heading == nil, role == "AXHeading",
           let text = string(node, kAXTitleAttribute) ?? string(node, kAXValueAttribute) ?? string(node, kAXDescriptionAttribute),
           text.count <= ThreadParticipants.maxNameLength {
            out.heading = text
        }
        for child in children(node) { walk(child, depth: depth + 1, budget: &budget, category: category, into: &out) }
    }

    private func label(of node: AXUIElement) -> String? {
        if let title = element(node, "AXTitleUIElement"),
           let text = string(title, kAXValueAttribute) ?? string(title, kAXTitleAttribute) { return text }
        return string(node, kAXDescriptionAttribute) ?? string(node, kAXTitleAttribute) ?? string(node, "AXPlaceholderValue")
    }

    /// Recipient tokens (Mail's address atoms, Gmail's chips): their titles / descriptions.
    private func tokens(of node: AXUIElement) -> [String] {
        children(node).prefix(ThreadParticipants.limit * 2).compactMap { child in
            AXUIElementSetMessagingTimeout(child, timeout)
            return string(child, kAXTitleAttribute) ?? string(child, kAXDescriptionAttribute) ?? string(child, kAXValueAttribute)
        }
    }

    // MARK: AX plumbing

    private func value(_ e: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &out) == .success else { return nil }
        return out
    }

    private func string(_ e: AXUIElement, _ attribute: String) -> String? {
        let text = (value(e, attribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    private func element(_ e: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = value(e, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement) // swiftlint:disable:this force_cast
    }

    private func children(_ e: AXUIElement) -> [AXUIElement] {
        guard let raw = value(e, kAXChildrenAttribute) as? [AnyObject] else { return [] }
        return raw.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil } // swiftlint:disable:this force_cast
    }
}

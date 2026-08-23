import Foundation

/// Bet 7 reversibility class lives in `Deterministic/ActionCatalog.swift`; danger ranking for escalation.
extension Reversibility {
    public var rank: Int { switch self { case .reversible: return 0; case .semi: return 1; case .irreversible: return 2 } }
    public static func mostDangerous(_ a: Reversibility, _ b: Reversibility) -> Reversibility { a.rank >= b.rank ? a : b }
}

/// Coarse action category, used when no id-level rule matches.
public enum ConsentCategory: String, Sendable, CaseIterable {
    case type, format, navigate, scroll, open, focus, click, fill          // reversible by default
    case sendMessage, createFile, commit, createItem                       // semi by default
    case delete, pay, sendExternalEmail, shell, modifyAccount              // irreversible by default
    case unknown
}

/// What the consent engine classifies. `id` is the catalogue action id (e.g. "slack.send_message");
/// `category` is the coarse class; `flags` carry per-invocation facts that can escalate (never
/// de-escalate) the verdict, e.g. `"external_recipient"`, `"destructive"`.
public struct ConsentRequest: Sendable, Equatable {
    public var id: String
    public var category: ConsentCategory
    public var title: String
    public var flags: Set<String>
    public init(id: String, category: ConsentCategory = .unknown, title: String? = nil, flags: Set<String> = []) {
        self.id = id; self.category = category; self.title = title ?? id; self.flags = flags
    }
    /// Bridge from the deterministic layer: catalogue id (or `ax.<kind>` when uncatalogued) + the
    /// catalogue's own reversibility as a floor via flags (`catalog_semi` / `catalog_irreversible`).
    public init(_ r: ActionRequest) {
        var f: Set<String> = []
        if r.reversibility == .semi { f.insert("catalog_semi") }
        if r.reversibility == .irreversible { f.insert("catalog_irreversible") }
        self.init(id: r.catalogID ?? "ax.\(r.kind.rawValue)", category: .unknown, title: r.params["target"] ?? r.kind.rawValue, flags: f)
    }
}

/// Rule table in code. No user configuration, by design (Bet 7: never a blanket "allow all").
/// Resolution order: exact id rule → id prefix rule → category rule → conservative default
/// (`.irreversible`). Escalating flags are applied last and can only raise the class.
public struct ActionClassifier: Sendable {
    public static let conservativeDefault: Reversibility = .irreversible

    /// Exact action ids. Keep sorted; every entry is unit-tested via the policy-table test.
    public static let idRules: [String: Reversibility] = [
        "ax.click": .reversible, "ax.focus_app": .reversible, "ax.focus_window": .reversible,
        "ax.focus_tab": .reversible, "ax.scroll": .reversible, "ax.keystroke": .reversible,
        "ax.fill_field": .reversible, "ax.open_url": .reversible, "ax.open_file": .reversible,
        "text.type": .reversible, "text.format": .reversible, "text.transform": .reversible,
        "slack.send_message": .semi, "slack.draft": .reversible,
        "gmail.draft": .reversible, "gmail.send_internal": .semi, "gmail.send": .irreversible,
        "calendar.create_event": .semi, "calendar.delete_event": .irreversible,
        "linear.create_issue": .semi, "linear.comment": .semi,
        "notion.create_page": .semi, "github.comment": .semi,
        "github.create_pr": .semi, "github.merge_pr": .irreversible,
        "git.commit": .semi, "git.push": .irreversible, "git.force_push": .irreversible,
        "fs.create_file": .semi, "fs.trash": .semi, "fs.delete": .irreversible,
        "shell.run": .irreversible, "payment.pay": .irreversible, "account.modify": .irreversible,
    ]

    /// Prefix rules (id starts with key). Checked when no exact rule matches.
    public static let prefixRules: [(prefix: String, class: Reversibility)] = [
        ("ax.", .reversible), ("text.", .reversible), ("nav.", .reversible),
        ("payment.", .irreversible), ("shell.", .irreversible), ("account.", .irreversible),
    ]

    public static let categoryRules: [ConsentCategory: Reversibility] = [
        .type: .reversible, .format: .reversible, .navigate: .reversible, .scroll: .reversible,
        .open: .reversible, .focus: .reversible, .click: .reversible, .fill: .reversible,
        .sendMessage: .semi, .createFile: .semi, .commit: .semi,
        .createItem: .semi,
        .delete: .irreversible, .pay: .irreversible, .sendExternalEmail: .irreversible,
        .shell: .irreversible, .modifyAccount: .irreversible,
    ]

    /// Flags that escalate. `external_recipient` makes any send irreversible (external email rule);
    /// `destructive` makes anything irreversible; `bulk` lifts reversible to semi.
    public static let escalations: [String: Reversibility] = [
        "external_recipient": .irreversible, "destructive": .irreversible, "bulk": .semi,
        "catalog_semi": .semi, "catalog_irreversible": .irreversible,
    ]

    public init() {}

    public func classify(_ r: ConsentRequest) -> Reversibility {
        var base: Reversibility
        if let exact = Self.idRules[r.id] { base = exact }
        else if let p = Self.prefixRules.first(where: { r.id.hasPrefix($0.prefix) }) { base = p.class }
        else if let c = Self.categoryRules[r.category] { base = c }
        else { base = Self.conservativeDefault }
        for f in r.flags { if let e = Self.escalations[f] { base = Reversibility.mostDangerous(base, e) } }
        return base
    }
}

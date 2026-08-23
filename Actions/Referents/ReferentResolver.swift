import Foundation

public enum PronounGender: String, Sendable, Codable { case feminine, masculine, neutral, unknown }

public struct Participant: Equatable, Hashable, Sendable, Codable {
    public var name: String
    public var handle: String?
    public var gender: PronounGender
    public var isSelf: Bool
    /// Higher = more recent/salient (e.g. last message author).
    public var salience: Double

    public init(name: String, handle: String? = nil, gender: PronounGender = .unknown, isSelf: Bool = false, salience: Double = 0) {
        self.name = name; self.handle = handle; self.gender = gender; self.isSelf = isSelf; self.salience = salience
    }
}

/// Who is in the current thread/window. Built from the AX context by a `ParticipantProviding`.
public struct ContextParticipants: Equatable, Sendable {
    public var participants: [Participant]
    public init(_ participants: [Participant] = []) { self.participants = participants }
}

public enum ArtifactKind: String, Sendable, Codable, CaseIterable {
    case deck, file, document, spreadsheet, link, image, email, message, folder, tab, window
}

/// Something visible on screen that a noun phrase can point to ("the deck", "the file").
public struct VisibleArtifact: Equatable, Hashable, Sendable {
    public var title: String
    public var kind: ArtifactKind
    public var path: String?
    public var element: ElementReference?
    public var salience: Double

    public init(title: String, kind: ArtifactKind, path: String? = nil, element: ElementReference? = nil, salience: Double = 0) {
        self.title = title; self.kind = kind; self.path = path; self.element = element; self.salience = salience
    }
}

public protocol ParticipantProviding: AnyObject { func participants() -> ContextParticipants }
public protocol ArtifactProviding: AnyObject { func visibleArtifacts() -> [VisibleArtifact] }

public final class StaticReferentContext: ParticipantProviding, ArtifactProviding {
    public var people: ContextParticipants
    public var artifacts: [VisibleArtifact]
    public init(people: ContextParticipants = .init(), artifacts: [VisibleArtifact] = []) { self.people = people; self.artifacts = artifacts }
    public func participants() -> ContextParticipants { people }
    public func visibleArtifacts() -> [VisibleArtifact] { artifacts }
}

public enum Referent: Equatable, Sendable {
    case person(Participant)
    case artifact(VisibleArtifact)
    public var label: String {
        switch self { case .person(let p): return p.name; case .artifact(let a): return a.title }
    }
}

public struct ReferentBinding: Equatable, Sendable {
    public var phrase: String
    public var range: Range<String.Index>
    public var candidates: [Referent]   // best first
    public var resolved: Referent?
    public var isAmbiguous: Bool
}

/// Resolves "her/him/them" against thread participants and "the deck/the file/…" against visible artifacts.
public struct ReferentResolver {
    public var salienceMargin: Double = 0.25
    static let pronouns: [String: [PronounGender]] = [
        "her": [.feminine], "she": [.feminine], "hers": [.feminine],
        "him": [.masculine], "he": [.masculine], "his": [.masculine],
        "them": [.neutral, .unknown, .feminine, .masculine], "they": [.neutral, .unknown, .feminine, .masculine],
    ]
    static let nouns: [String: ArtifactKind] = [
        "deck": .deck, "slides": .deck, "presentation": .deck, "file": .file, "doc": .document, "document": .document,
        "spreadsheet": .spreadsheet, "sheet": .spreadsheet, "link": .link, "url": .link, "image": .image, "picture": .image,
        "screenshot": .image, "email": .email, "mail": .email, "message": .message, "folder": .folder, "tab": .tab, "window": .window,
    ]

    public init() {}

    public func resolve(_ text: String, participants: ContextParticipants, artifacts: [VisibleArtifact]) -> [ReferentBinding] {
        var out: [ReferentBinding] = []
        let lower = text.lowercased()
        for m in Self.tokens(in: lower) {
            let word = String(lower[m])
            if let genders = Self.pronouns[word] {
                let cands = participants.participants.filter { !$0.isSelf && genders.contains($0.gender) }.sorted { $0.salience > $1.salience }
                out.append(binding(word, m, cands.map(Referent.person), salience: cands.map(\.salience)))
            } else if let kind = Self.nouns[word], Self.precededByDeterminer(lower, m) {
                let cands = artifacts.filter { $0.kind == kind }.sorted { $0.salience > $1.salience }
                out.append(binding("the \(word)", m, cands.map(Referent.artifact), salience: cands.map(\.salience)))
            }
        }
        return out
    }

    public func resolve(_ text: String, people: ParticipantProviding, artifacts: ArtifactProviding) -> [ReferentBinding] {
        resolve(text, participants: people.participants(), artifacts: artifacts.visibleArtifacts())
    }

    private func binding(_ phrase: String, _ r: Range<String.Index>, _ cands: [Referent], salience: [Double]) -> ReferentBinding {
        let ambiguous = cands.count > 1 && (salience[0] - salience[1]) < salienceMargin
        return ReferentBinding(phrase: phrase, range: r, candidates: cands, resolved: ambiguous ? nil : cands.first, isAmbiguous: ambiguous)
    }

    static func tokens(in s: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var i = s.startIndex
        while i < s.endIndex {
            if s[i].isLetter {
                var j = i
                while j < s.endIndex, s[j].isLetter || s[j] == "'" { j = s.index(after: j) }
                out.append(i..<j); i = j
            } else { i = s.index(after: i) }
        }
        return out
    }

    static func precededByDeterminer(_ s: String, _ r: Range<String.Index>) -> Bool {
        let before = s[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
        return ["the", "that", "this", "my", "our", "your"].contains { before.hasSuffix($0) }
    }
}

public extension Array where Element == ReferentBinding {
    /// Lines for the pipeline's context block, e.g. `her = Jane Park`.
    var contextLines: [String] {
        map { b in
            if let r = b.resolved { return "\(b.phrase) = \(r.label)" }
            return b.candidates.isEmpty ? "\(b.phrase) = unknown" : "\(b.phrase) = ? (\(b.candidates.map(\.label).joined(separator: " | ")))"
        }
    }
}

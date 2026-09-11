import Foundation

// R8.3 — `AmbientTimeline`: the query surface the Timeline is driven by (search text + source
// filters), and every sentence its states are allowed to say.
//
// **Naming (V3 §4.7).** `AmbientTimeline` is the *ambient transcript history* shown in the window.
// `InputTimeline` — the input-event recorder behind deixis — keeps its name in code and is never
// shown to anyone as "Timeline". Nothing in this file touches it.
//
// Everything here is a value. The states the Timeline can render are the only part of the section a
// toolchain with no XCTest and no UI testing can see, so none of them are decided inside a `body`.

/// Where one Timeline row came from.
///
/// A value, not an enum: the store writes the id, and a build that has never heard of a future
/// source must still show it and filter on it rather than dropping the row on the floor.
public struct TimelineSource: Hashable, Sendable, Identifiable, Comparable {
    public let id: String
    public let label: String

    public init(id: String, label: String? = nil) {
        self.id = id
        self.label = label ?? (id.isEmpty ? "Unknown" : id.prefix(1).uppercased() + id.dropFirst())
    }

    /// Speech captured while ambient capture was on. Transcript only, enrolled voice only (V3 §8).
    public static let ambient = TimelineSource(id: "ambient", label: "Ambient")
    /// Something the user dictated on purpose — hold or latch.
    public static let dictation = TimelineSource(id: "dictation", label: "Dictation")
    /// A meeting transcript (R4 / `MeetingStore`), surfaced here because it is the same question:
    /// "what was said recently".
    public static let meeting = TimelineSource(id: "meeting", label: "Meeting")

    /// The sources this build knows how to name, in the order the filter row shows them.
    public static let known: [TimelineSource] = [.ambient, .dictation, .meeting]

    /// The known source with this id, or an honestly-labelled unknown one.
    public static func named(_ id: String) -> TimelineSource {
        known.first { $0.id == id } ?? TimelineSource(id: id)
    }

    /// Known sources first, in `known` order; anything else alphabetically after them, so the filter
    /// row never reshuffles between reads.
    public static func < (lhs: TimelineSource, rhs: TimelineSource) -> Bool {
        let l = known.firstIndex(of: lhs), r = known.firstIndex(of: rhs)
        switch (l, r) {
        case let (l?, r?): return l < r
        case (_?, nil): return true
        case (nil, _?): return false
        default: return lhs.id < rhs.id
        }
    }
}

/// What the Timeline is asking the store for: matching text, restricted to some sources.
public struct TimelineQuery: Equatable, Sendable {
    public var text: String
    /// Source ids to include. **Empty means every source** — a filter row with nothing ticked shows
    /// everything rather than nothing, because an empty list the user cannot explain is the state
    /// `DESIGN.md` §9 forbids.
    public var sources: Set<String>

    public init(text: String = "", sources: Set<String> = []) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sources = sources
    }

    public var isEverySource: Bool { sources.isEmpty }
    public var isSearching: Bool { !text.isEmpty }
    /// Is this query narrower than "show me everything"? Decides which empty the section shows.
    public var isNarrowed: Bool { isSearching || !isEverySource }

    /// Case-insensitive text match plus the source restriction. The store is expected to do this
    /// against its indexes; this is the same rule, for the fallback path and for the tests.
    public func matches(_ row: TimelineRow) -> Bool {
        if !isEverySource, !sources.contains(row.source) { return false }
        guard isSearching else { return true }
        return row.text.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// One day's worth of rows, newest day first, newest row first within the day (`DESIGN.md` §9.1).
public struct TimelineDay: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var rows: [TimelineRow]
}

public extension AmbientTimelineReading {
    /// Search + source filters in one call. A store that can do this against its indexes should
    /// override it; the default asks for the text match it already supports and applies the source
    /// restriction here, which is correct but reads more rows than it needs to.
    func rows(matching query: TimelineQuery) async throws -> [TimelineRow] {
        let rows = try await rows(matching: query.text)
        return query.isEverySource ? rows : rows.filter { query.sources.contains($0.source) }
    }

    /// Which sources the store holds *regardless of the current query*, so filtering to one source
    /// cannot make the other filters disappear. An empty answer means "I don't keep that index" —
    /// the section then derives the filter row from the rows it has seen, and says so to no one
    /// because a filter row is not a claim about the store.
    func sources() async throws -> [TimelineSource] { [] }
}

public extension SectionCopy {
    // MARK: Timeline — search (R8.3)
    static let timelineSearching = "Searching…"
    static let timelineNoMatches = "No matches"
    static func timelineNoMatchesDetail(_ query: String) -> String {
        "Nothing in the Timeline matches “\(query)”."
    }
    static let clearSearch = "Clear search"
    static let timelineSearchFailed = "That search didn't finish"

    // MARK: Timeline — source filters
    static let timelineNoMatchingSource = "Nothing from these sources"
    static let timelineNoMatchingSourceDetail = "The Timeline has nothing from the sources you picked."
    static let showEverySource = "Show everything"

    // MARK: Timeline — delete and delete-all
    static let timelineDeleting = "Deleting…"
    static let timelineRowNotDeleted = "That row wasn't deleted"
    static let timelineRowStillThere = "That row is still in the Timeline"
    static let deleteAllTimeline = "Delete all"
    static let confirmDeleteAllTimeline = "Delete everything in the Timeline?"
    static func confirmDeleteAllTimelineDetail(_ count: Int) -> String {
        count == 1 ? "One entry will be deleted from this Mac. This can't be undone."
                   : "\(count) entries will be deleted from this Mac. This can't be undone."
    }
    static let confirmDelete = "Delete"
    static let cancel = "Cancel"
    static let confirmDeleteRow = "Delete this entry?"
    static func confirmDeleteRowDetail(_ excerpt: String) -> String {
        "“\(excerpt)” will be deleted from this Mac. This can't be undone."
    }

    // MARK: Timeline — the store is absent
    static let timelineStoreMissing = "Timeline isn't running"
    static let timelineStoreMissingDetail = "Ambient capture is on, but its store hasn't started on this Mac."

    // MARK: Timeline — privacy (V3 §9.6)
    /// What is captured, what is saved, what is transmitted — and no claim of literal zero network
    /// bytes, which is why the last clause points at the Privacy log instead of promising silence.
    static let timelinePrivacy = """
        Ambient capture keeps transcript only, recognised on this Mac, and only what your enrolled \
        voice said. Nothing here is typed anywhere and none of it is synced. VoicePlus still uses \
        the network for model downloads and update checks — Privacy lists every request it made.
        """
    static func timelineRetention(days: Int) -> String {
        days == 1 ? "Entries are deleted after a day." : "Entries are deleted after \(days) days."
    }
}

/// A destructive Timeline action waiting for an explicit yes (`DESIGN.md` §5.2 — "with confirmation
/// for destructive scope", §5.3 — a sheet only for a genuine either/or).
///
/// A value rather than a `Bool` + a scope variable somewhere else: the sentence, the scope and both
/// ways out travel together, so a confirmation can never be shown without saying what it will delete
/// or without an out. `isWellFormed` is the same kind of predicate `SectionState` has, for the same
/// reason — it is the only part of a sheet this toolchain can see.
public struct TimelineConfirmation: Equatable, Sendable, Identifiable {
    public enum Scope: Equatable, Sendable {
        /// One row, named by the first words the user can recognise it by.
        case row(id: String, excerpt: String)
        /// Everything the current read can see. The count is what makes this a scope and not a shrug.
        case everything(count: Int)
    }

    public let scope: Scope
    public let headline: String
    public let detail: String
    public let confirmTitle: String
    public let cancelTitle: String

    public init(scope: Scope, headline: String, detail: String,
                confirmTitle: String = SectionCopy.confirmDelete,
                cancelTitle: String = SectionCopy.cancel) {
        self.scope = scope
        self.headline = headline
        self.detail = detail
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
    }

    public var id: String {
        switch scope {
        case .row(let id, _): return "row:\(id)"
        case .everything: return "everything"
        }
    }

    public var deletesEverything: Bool {
        if case .everything = scope { return true }
        return false
    }

    /// The row this confirmation is about, or nil for delete-all.
    public var rowID: String? {
        if case .row(let id, _) = scope { return id }
        return nil
    }

    public static func everything(count: Int) -> TimelineConfirmation {
        TimelineConfirmation(scope: .everything(count: count),
                             headline: SectionCopy.confirmDeleteAllTimeline,
                             detail: SectionCopy.confirmDeleteAllTimelineDetail(count))
    }

    public static func row(id: String, text: String) -> TimelineConfirmation {
        let excerpt = TimelineConfirmation.excerpt(of: text)
        return TimelineConfirmation(scope: .row(id: id, excerpt: excerpt),
                                    headline: SectionCopy.confirmDeleteRow,
                                    detail: SectionCopy.confirmDeleteRowDetail(excerpt))
    }

    /// Enough words to recognise the row by, never the whole transcript in a dialog.
    public static func excerpt(of text: String, limit: Int = 60) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return trimmed.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Says what will be deleted, and names both ways out.
    public var isWellFormed: Bool {
        !headline.isEmpty && !detail.isEmpty && !confirmTitle.isEmpty && !cancelTitle.isEmpty
    }
}

public extension TimelineDay {
    /// Newest day first, newest row first within the day (`DESIGN.md` §9.1).
    static func group(_ rows: [TimelineRow], calendar: Calendar = .current, now: Date = Date()) -> [TimelineDay] {
        var days: [TimelineDay] = []
        for row in rows.sorted(by: { $0.time > $1.time }) {
            let start = calendar.startOfDay(for: row.time)
            let id = String(Int(start.timeIntervalSince1970))
            if days.last?.id == id {
                days[days.count - 1].rows.append(row)
            } else {
                days.append(TimelineDay(id: id, title: title(for: start, calendar: calendar, now: now), rows: [row]))
            }
        }
        return days
    }

    /// "Today", "Yesterday", then the date. Relative words only for the two days a person actually
    /// thinks of that way — "3 days ago" is harder to read than the date.
    static func title(for day: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        if let yesterday, calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}

import AppKit
import Lab
import Shared
import SwiftUI

// I2 — the zero-edit counter, surfaced. `DatabaseZeroEditSink` and `ZeroEditTracker` mark a
// dictation row `edited` when the user (or a voice repair) changed the landed text; this file reads
// those rows back as one honest number — the share of the last 7 days' dictations that landed with
// no edits — and shows it in the status menu (above Lab's `ZeroEditMenuView` sparkline) and on Today.
//
// Nothing is shown until there is something to count: no dictations in the window means no row and
// no card, never "0%". Reading is a database read; it never touches capture or focus.

/// The 7-day rollup behind both surfaces. Pure, so it is tested without a window or a menu.
public struct ZeroEditWeek: Equatable, Sendable {
    public static let days = 7

    public var dictations: Int
    public var editedDictations: Int
    public var words: Int

    public init(dictations: Int, editedDictations: Int, words: Int) {
        self.dictations = dictations
        self.editedDictations = editedDictations
        self.words = words
    }

    public var zeroEditDictations: Int { max(0, dictations - editedDictations) }
    /// Nil with nothing to count, so no surface ever claims a rate it does not have.
    public var rate: Double? { dictations == 0 ? nil : Double(zeroEditDictations) / Double(dictations) }
    public var percent: Int? { rate.map { Int(($0 * 100).rounded()) } }
    public var isEmpty: Bool { dictations == 0 }

    /// The last `days` days of a daily trend (oldest first, as `ZeroEditStats` builds it).
    public static func from(_ stat: ZeroEditStat, days: Int = ZeroEditWeek.days) -> ZeroEditWeek {
        stat.trend.suffix(days).reduce(into: ZeroEditWeek(dictations: 0, editedDictations: 0, words: 0)) { week, day in
            week.dictations += day.dictations
            week.editedDictations += day.editedDictations
            week.words += day.words
        }
    }

    /// Straight from history. Nil when there is no database or it cannot be read.
    public static func load(from database: AppDatabase?, now: Date = Date(),
                            calendar: Calendar = .current) -> ZeroEditWeek? {
        guard let database,
              let stat = try? ZeroEditStats.trend(db: database, days: days, now: now, calendar: calendar)
        else { return nil }
        return from(stat)
    }
}

/// The words on both surfaces.
public enum ZeroEditCopy {
    public static let menuID = "menu.zeroEdit"
    public static let cardID = "today.zeroEdit"
    public static let heading = "Landed without edits"

    /// "92% landed without edits this week"
    public static func headline(_ week: ZeroEditWeek) -> String? {
        week.percent.map { "\($0)% landed without edits this week" }
    }

    /// "46 of 50 dictations · 1,234 words · last 7 days"
    public static func detail(_ week: ZeroEditWeek) -> String? {
        guard !week.isEmpty else { return nil }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        let words = f.string(from: NSNumber(value: week.words)) ?? "\(week.words)"
        let noun = week.dictations == 1 ? "dictation" : "dictations"
        let wordNoun = week.words == 1 ? "word" : "words"
        return "\(week.zeroEditDictations) of \(week.dictations) \(noun) · \(words) \(wordNoun) · last \(ZeroEditWeek.days) days"
    }

    /// One plain sentence for VoiceOver.
    public static func accessibilityLabel(_ week: ZeroEditWeek) -> String {
        guard let percent = week.percent else { return "No dictations in the last \(ZeroEditWeek.days) days" }
        return "\(percent) percent of dictations landed without edits in the last \(ZeroEditWeek.days) days, "
            + "\(week.zeroEditDictations) of \(week.dictations)"
    }
}

/// The one model both surfaces read: Lab's `ZeroEditViewModel` (14-day trend, today's line) plus the
/// 7-day rollup derived from the same rows.
@MainActor
public final class ZeroEditSurfaceModel: ObservableObject {
    public let trend: ZeroEditViewModel
    @Published public private(set) var week: ZeroEditWeek

    public init(database: AppDatabase?) {
        trend = ZeroEditViewModel(database: database)
        week = ZeroEditWeek(dictations: 0, editedDictations: 0, words: 0)
    }

    public func reload(now: Date = Date()) {
        trend.reload(now: now)
        week = ZeroEditWeek.from(trend.stat)
    }
}

/// Status-menu row: the 7-day line over `ZeroEditMenuView` (today's words and the 14-day sparkline).
struct ZeroEditStatusMenuView: View {
    @ObservedObject var model: ZeroEditSurfaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let headline = ZeroEditCopy.headline(model.week) {
                Text(headline).font(.subheadline.weight(.semibold))
            }
            if let detail = ZeroEditCopy.detail(model.week) {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            ZeroEditMenuView(model: model.trend)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: 280, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ZeroEditCopy.accessibilityLabel(model.week))
    }
}

/// Today card. Draws nothing until there is a week to report.
struct ZeroEditTodayCard: View {
    @StateObject private var model: ZeroEditSurfaceModel

    init(database: AppDatabase?) {
        _model = StateObject(wrappedValue: ZeroEditSurfaceModel(database: database))
    }

    var body: some View {
        Group {
            if let headline = ZeroEditCopy.headline(model.week) {
                GroupBox(ZeroEditCopy.heading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(headline).font(.body.weight(.semibold))
                        if let detail = ZeroEditCopy.detail(model.week) {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(ZeroEditCopy.accessibilityLabel(model.week))
                }
                .accessibilityIdentifier(ZeroEditCopy.cardID)
            }
        }
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: TodayTurnStoreReader.didChange)) { _ in model.reload() }
    }
}

/// Builds the status menu's zero-edit row. Nil when the week is empty: the menu shows nothing rather
/// than a rate it does not have.
@MainActor
enum ZeroEditMenuItem {
    static func make(model: ZeroEditSurfaceModel, now: Date = Date()) -> NSMenuItem? {
        model.reload(now: now)
        guard !model.week.isEmpty else { return nil }
        let item = NSMenuItem(title: ZeroEditCopy.headline(model.week) ?? "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.identifier = NSUserInterfaceItemIdentifier(ZeroEditCopy.menuID)
        item.toolTip = ZeroEditCopy.detail(model.week)
        let host = NSHostingView(rootView: ZeroEditStatusMenuView(model: model))
        host.frame.size = host.fittingSize
        item.view = host
        return item
    }
}

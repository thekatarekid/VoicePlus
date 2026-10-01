import Engine
import Foundation
import Shared

/// V5 O2 — the ambient timeline as a recorder. Lives in `App/Recorders`, not `App/Services`: the
/// V3 §8 audit (`AmbientInjectionAudit`) keeps ambient-capture types out of every injection path, and
/// this file only labels stored spans — it never delivers text. When a capability claims an utterance the ambient
/// timeline also kept (the user dictated while ambient listening was on), the stored day record's
/// matching span is labelled with its owner (`MeetingUtterance.tag`), so the timeline shows it once,
/// as "dictated" / "command" / "note", instead of as stray conversation.
///
/// Works on the ambient day records (`ambient-YYYY-MM-DD`, `MeetingRecord` shape) through their
/// `MeetingStore` and never touches the search index (which holds words, not tags). Writes are
/// serialised here; the store's own append path has its own lock, so a tag and an append racing on
/// the same day re-read and retry (`attempts`) rather than overwrite a fresh entry.
public final class AmbientTimelineTagger: UtteranceTagRecording, @unchecked Sendable {
    public let meetings: MeetingStore
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "VoicePlus.AmbientTimelineTagger", qos: .utility)
    static let attempts = 3

    public init(meetings: MeetingStore = MeetingStore(root: AmbientTranscriptStore.defaultRoot())) {
        self.meetings = meetings
    }

    public func record(_ tag: UtteranceTag) {
        guard tag.owner != .ignore else { return }
        queue.async { [weak self] in _ = self?.apply(tag) }
    }

    /// Labels the claimed spans in the tag's day record now. Returns how many were tagged.
    @discardableResult
    public func apply(_ tag: UtteranceTag) -> Int {
        lock.withLock {
            let id = AmbientTranscriptStore.recordID(for: tag.range.lowerBound)
            for _ in 0..<Self.attempts {
                guard var record = try? meetings.load(id: id) else { return 0 }
                let tagged = record.transcript.apply(tag, origin: record.startedAt)
                guard tagged > 0 else { return 0 }
                // An entry appended since the read would be lost by this save: re-read and retry.
                guard let fresh = try? meetings.load(id: id),
                      fresh.transcript.utterances.count == record.transcript.utterances.count else { continue }
                guard (try? meetings.save(record)) != nil else { return 0 }
                return tagged
            }
            return 0
        }
    }
}

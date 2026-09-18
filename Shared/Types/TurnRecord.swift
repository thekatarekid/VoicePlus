import Foundation

/// G0.1 — the one observable record of a turn (design_v1 §12, Build doc V4 §2 and S11).
///
/// Keeps capture, text and delivery state apart: what was heard (`rawText`), the immutable final
/// payload (`finalText` + `uncertainSpans`), whether a write was *attempted* (`writeAttempted`) and
/// what the write turned out to be (`outcome`) are separate fields, because "write dispatched" and
/// "readback confirmed" are different facts. Written at the key-down snapshot and updated at each
/// transition; the presentation (Spool pose, animation) never feeds back into it.
public struct TurnRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Where the turn was aimed, snapshotted at key down (design §5 step 1). Revalidated before the
    /// single insert; a mismatch holds the text instead of following a moved cursor.
    public struct Destination: Codable, Equatable, Hashable, Sendable {
        /// Frontmost app at key down.
        public var bundleID: String?
        /// Human name for copy ("Inserted in Mail"). Never a bundle ID in a headline.
        public var appName: String?
        /// AX role of the focused element (`AXTextArea`, `AXTextField`, …).
        public var role: String?
        /// Identity of the focused element (AX hash). Process-local: compare within a session only.
        public var elementHash: Int?
        /// The screen the destination was on (`CGDirectDisplayID`).
        public var displayID: UInt32?
        /// Selection at key down, in UTF-16 units of the field value, when one was readable.
        public var selection: Range<Int>?
        /// Hash of the field value at key down — the "text version" revalidated before insert.
        public var textVersion: Int?
        /// Secure (password) field at key down. Secure fields are never written.
        public var isSecure: Bool

        public init(bundleID: String? = nil, appName: String? = nil, role: String? = nil,
                    elementHash: Int? = nil, displayID: UInt32? = nil, selection: Range<Int>? = nil,
                    textVersion: Int? = nil, isSecure: Bool = false) {
            self.bundleID = bundleID
            self.appName = appName
            self.role = role
            self.elementHash = elementHash
            self.displayID = displayID
            self.selection = selection
            self.textVersion = textVersion
            self.isSecure = isSecure
        }

        private enum CodingKeys: String, CodingKey {
            case bundleID, appName, role, elementHash, displayID, selection, textVersion, isSecure
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                bundleID: try c.decodeIfPresent(String.self, forKey: .bundleID),
                appName: try c.decodeIfPresent(String.self, forKey: .appName),
                role: try c.decodeIfPresent(String.self, forKey: .role),
                elementHash: try c.decodeIfPresent(Int.self, forKey: .elementHash),
                displayID: try c.decodeIfPresent(UInt32.self, forKey: .displayID),
                selection: try c.decodeIfPresent(Range<Int>.self, forKey: .selection),
                textVersion: try c.decodeIfPresent(Int.self, forKey: .textVersion),
                isSecure: try c.decodeIfPresent(Bool.self, forKey: .isSecure) ?? false
            )
        }
    }

    /// Capture and payload clock marks. Key down is `TurnRecord.startedAt`.
    public struct CaptureTimestamps: Codable, Equatable, Hashable, Sendable {
        /// Capture actually open — the moment "Listening" may be shown (target ≤ 80 ms after key down).
        public var captureOpened: Date?
        /// Key up / endpoint: microphone closed.
        public var captureClosed: Date?
        /// The immutable final payload was published.
        public var finalPublished: Date?
        /// First rendered final frame — dwell is measured from here, not from backend completion.
        public var finalRendered: Date?
        /// The single insert was dispatched.
        public var writeDispatched: Date?

        public init(captureOpened: Date? = nil, captureClosed: Date? = nil, finalPublished: Date? = nil,
                    finalRendered: Date? = nil, writeDispatched: Date? = nil) {
            self.captureOpened = captureOpened
            self.captureClosed = captureClosed
            self.finalPublished = finalPublished
            self.finalRendered = finalRendered
            self.writeDispatched = writeDispatched
        }
    }

    public var turnID: TurnID
    /// Key down.
    public var startedAt: Date
    public var destination: Destination
    /// What the engine heard, before formatting.
    public var rawText: String
    /// The immutable final payload that is previewed and inserted once; never revised.
    public var finalText: String
    /// Low-confidence ranges of `finalText`, in UTF-16 units (the unit AX and TextKit ranges use).
    public var uncertainSpans: [Range<Int>]
    public var capture: CaptureTimestamps
    /// A write was dispatched to the destination. Recorded separately from verification: an
    /// attempted write is never followed by another method (readback rule, V3 §6).
    public var writeAttempted: Bool
    /// What the write turned out to be. `nil` until it is known — before the write, or for a turn
    /// that ended without one (cancelled, empty).
    public var outcome: DeliveryOutcome?
    /// Where retained audio for this turn lives, when retention kept any.
    public var retainedAudioPath: String?

    public var id: TurnID { turnID }

    public init(turnID: TurnID = TurnID(), startedAt: Date = Date(), destination: Destination = Destination(),
                rawText: String = "", finalText: String = "", uncertainSpans: [Range<Int>] = [],
                capture: CaptureTimestamps = CaptureTimestamps(), writeAttempted: Bool = false,
                outcome: DeliveryOutcome? = nil, retainedAudioPath: String? = nil) {
        self.turnID = turnID
        self.startedAt = startedAt
        self.destination = destination
        self.rawText = rawText
        self.finalText = finalText
        self.uncertainSpans = uncertainSpans
        self.capture = capture
        self.writeAttempted = writeAttempted
        self.outcome = outcome
        self.retainedAudioPath = retainedAudioPath
    }

    /// Key down → capture open. `nil` until capture opened.
    public var captureOpenLatency: TimeInterval? {
        capture.captureOpened.map { $0.timeIntervalSince(startedAt) }
    }

    /// True when the final payload carries anything to review.
    public var hasUncertainty: Bool { !uncertainSpans.isEmpty }

    /// Nothing further will happen to this turn on its own: its outcome is terminal. A held turn
    /// is still waiting for Insert here / Copy / Discard.
    public var isSettled: Bool { outcome?.isTerminal ?? false }

    private enum CodingKeys: String, CodingKey {
        case turnID, startedAt, destination, rawText, finalText, uncertainSpans, capture,
             writeAttempted, outcome, retainedAudioPath
    }

    /// Tolerant of rows written by an older build: every field but `turnID` and `startedAt` has a
    /// default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            turnID: try c.decode(TurnID.self, forKey: .turnID),
            startedAt: try c.decode(Date.self, forKey: .startedAt),
            destination: try c.decodeIfPresent(Destination.self, forKey: .destination) ?? Destination(),
            rawText: try c.decodeIfPresent(String.self, forKey: .rawText) ?? "",
            finalText: try c.decodeIfPresent(String.self, forKey: .finalText) ?? "",
            uncertainSpans: try c.decodeIfPresent([Range<Int>].self, forKey: .uncertainSpans) ?? [],
            capture: try c.decodeIfPresent(CaptureTimestamps.self, forKey: .capture) ?? CaptureTimestamps(),
            writeAttempted: try c.decodeIfPresent(Bool.self, forKey: .writeAttempted) ?? false,
            outcome: try c.decodeIfPresent(DeliveryOutcome.self, forKey: .outcome),
            retainedAudioPath: try c.decodeIfPresent(String.self, forKey: .retainedAudioPath)
        )
    }
}

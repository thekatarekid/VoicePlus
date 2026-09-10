import Foundation
import Testing
@testable import Shared

/// R2.1 — stability on `TranscriptSpan`, `SegmentID`, `DeliveryOutcome`.
@Suite struct R21TypesTests {

    private func roundTrip<T: Codable & Equatable>(
        _ value: T, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: data)
        #expect(decoded == value, sourceLocation: sourceLocation)
    }

    // MARK: - Stability on TranscriptSpan

    @Test(arguments: Stability.allCases)
    func transcriptSpanRoundTripsEveryStability(_ stability: Stability) throws {
        let span = TranscriptSpan(
            text: "Kothari", confidence: 0.42, audioRange: 0.75...1.3,
            alternates: [Alternate(text: "Kotari", score: 0.3, source: .beam)],
            provenance: [.asr, .biasing], needsRepair: true, stability: stability
        )
        #expect(span.stability == stability)
        try roundTrip(span)
        try roundTrip([span])
    }

    @Test func stabilityDefaultsToFinalWhenOmitted() {
        let span = TranscriptSpan(text: "hi", confidence: 0.9, audioRange: 0...1)
        #expect(span.stability == .final)
        // Existing full-label call site still compiles unchanged.
        let full = TranscriptSpan(
            text: "hi", confidence: 0.9, audioRange: 0...1,
            alternates: [], provenance: [.asr], needsRepair: false
        )
        #expect(full.stability == .final)
    }

    /// JSON written *before* R2.1 has no `stability` key and must still decode.
    @Test func preR21JSONDecodesAsFinal() throws {
        let legacy = #"""
        {"text":"hello there","confidence":0.91,"audioStart":0.0,"audioEnd":1.4,
         "alternates":[],"provenance":["asr"],"needsRepair":false}
        """#
        let span = try JSONDecoder().decode(TranscriptSpan.self, from: Data(legacy.utf8))
        #expect(span.stability == .final)
        #expect(span.text == "hello there")
        #expect(span.audioRange == 0.0...1.4)
        #expect(span.provenance == [.asr])

        // And the truly minimal payload too.
        let minimal = #"{"text":"hi","confidence":0.5,"audioStart":0,"audioEnd":0.2}"#
        #expect(try JSONDecoder().decode(TranscriptSpan.self, from: Data(minimal.utf8)).stability == .final)
    }

    @Test func stabilityEncodesAsPlainString() throws {
        let data = try JSONEncoder().encode([Stability.provisional, .committed, .final])
        #expect(String(decoding: data, as: UTF8.self) == #"["provisional","committed","final"]"#)
    }

    @Test func stabilityOnlyMovesForward() {
        #expect(Stability.provisional < .committed)
        #expect(Stability.committed < .final)
        let preview = TranscriptSpan(text: "hi", confidence: 0.9, audioRange: 0...1, stability: .provisional)
        #expect(preview.isProvisional)
        #expect(preview.stabilized(.committed).stability == .committed)
        // Asking for a lower stability is a no-op.
        #expect(preview.stabilized(.final).stabilized(.provisional).stability == .final)
        // Stabilizing does not disturb the confidence contract fields.
        let committed = preview.stabilized(.committed)
        #expect(committed.confidence == preview.confidence)
        #expect(committed.audioRange == preview.audioRange)
        #expect(committed.provenance == preview.provenance)
    }

    /// The contract stage must still pass with the new field present.
    @Test func confidenceContractIgnoresStabilityChanges() {
        let input = [
            TranscriptSpan(text: "hello", confidence: 0.95, audioRange: 0...0.5,
                           provenance: [.asr], stability: .provisional),
            TranscriptSpan(text: "kothari", confidence: 0.3, audioRange: 0.5...1.2,
                           provenance: [.asr], stability: .provisional),
        ]
        let output = input.map { $0.touched(by: .style).stabilized(.committed) }
        #expect(ConfidenceContract.verify(input: input, output: output) == [])
    }

    // MARK: - SegmentID

    @Test func segmentIDRoundTrip() throws {
        let id = SegmentID(sessionID: UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")!, index: 3)
        try roundTrip(id)
        try roundTrip([id, id.next])
    }

    @Test func segmentIDOrdersWithinASession() {
        let session = UUID()
        let s0 = SegmentID.first(in: session)
        let s1 = s0.next
        let s2 = s1.next
        #expect(s0.index == 0 && s1.index == 1 && s2.index == 2)
        #expect(s0.isSameSession(as: s2))
        #expect(s0 < s1 && s1 < s2)
        #expect(s0.precedes(s1) == true)
        #expect(s2.precedes(s1) == false)
        #expect([s2, s0, s1].sorted() == [s0, s1, s2])
        #expect(s0 != s1)
        #expect(SegmentID(sessionID: session, index: 1) == s1)
        #expect(Set([s1, SegmentID(sessionID: session, index: 1)]).count == 1)
    }

    @Test func segmentIDCrossSessionComparisonIsNotMeaningful() {
        let a = SegmentID(sessionID: UUID(), index: 7)
        let b = SegmentID(sessionID: UUID(), index: 0)
        #expect(!a.isSameSession(as: b))
        #expect(a.precedes(b) == nil)
        // `<` is still a total order (so sorting is well-defined), just not meaningful.
        #expect((a < b) != (b < a))
    }

    @Test func segmentIDDescriptionIsShort() {
        let id = SegmentID(sessionID: UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")!, index: 12)
        #expect(id.description == "0F1E2D3C#12")
    }

    // MARK: - DeliveryOutcome

    @Test func deliveryOutcomeRoundTripsEveryCase() throws {
        for outcome: DeliveryOutcome in [
            .delivered(verified: true, method: "keystroke"),
            .delivered(verified: false, method: "paste"),
            .held(reason: "destination changed"),
            .failed(reason: "secure field"),
        ] {
            try roundTrip(outcome)
            try roundTrip([outcome])
        }
    }

    @Test func deliveryOutcomeEncodesWithKindDiscriminator() throws {
        let data = try JSONEncoder().encode(DeliveryOutcome.held(reason: "no destination"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["kind"] as? String == "held")
        #expect(json?["reason"] as? String == "no destination")
        #expect(json?["method"] == nil)
    }

    @Test func deliveryOutcomeConvenienceSurface() {
        let verified = DeliveryOutcome.delivered(verified: true, method: "paste")
        let unverified = DeliveryOutcome.delivered(verified: false, method: "keystroke")
        let held = DeliveryOutcome.held(reason: "destination changed")
        let failed = DeliveryOutcome.failed(reason: "secure field")

        #expect(verified.isDelivered && verified.isVerified && verified.isTerminal)
        #expect(unverified.isDelivered && !unverified.isVerified && unverified.isTerminal)
        // Held waits on the user, so it is not terminal.
        #expect(held.isHeld && !held.isTerminal && !held.isDelivered)
        #expect(failed.isFailed && failed.isTerminal && !failed.isVerified)

        #expect(unverified.method == "keystroke")
        #expect(held.method == nil)
        #expect(held.reason == "destination changed")
        #expect(failed.reason == "secure field")
        #expect(verified.reason == nil)

        #expect(verified.kind == .delivered && held.kind == .held && failed.kind == .failed)
        #expect(unverified.description == "delivered(unverified, keystroke)")
        #expect(held.description == "held(destination changed)")
    }

    @Test func deliveryOutcomeEqualityDistinguishesPayloads() {
        #expect(DeliveryOutcome.delivered(verified: true, method: "paste")
                != .delivered(verified: false, method: "paste"))
        #expect(DeliveryOutcome.held(reason: "x") != .failed(reason: "x"))
        #expect(DeliveryOutcome.failed(reason: "x") == .failed(reason: "x"))
    }
}

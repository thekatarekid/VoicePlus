import Foundation
import Testing
import Shared
@testable import KeyboardCore

private func spans(_ words: [(String, Float)], alts: [Int: [String]] = [:]) -> [TranscriptSpan] {
    words.enumerated().map { i, w in
        TranscriptSpan(text: w.0, confidence: w.1, audioRange: Double(i)...Double(i + 1),
                       alternates: (alts[i] ?? []).enumerated().map { Alternate(text: $1, score: 1 - Float($0) * 0.1, source: .beam) },
                       provenance: [.asr])
    }
}

@Suite struct KeyboardSessionTests {
    @Test func pressDownStartsASRWithHaptic() {
        var s = KeyboardSession(useProxy: false)
        #expect(s.handle(.pressDown) == [.haptic(.start), .startASR])
        #expect(s.isListening)
    }

    @Test func partialsUpdateStateOnly() {
        var s = KeyboardSession(useProxy: false); s.handle(.pressDown)
        #expect(s.handle(.partial("hel")) == [])
        #expect(s.state == .listening(partial: "hel"))
    }

    @Test func pressUpStopsASRAndFinalLandsWithReturn() {
        var s = KeyboardSession(useProxy: false); s.handle(.pressDown)
        #expect(s.handle(.pressUp) == [.stopASR])
        let fx = s.handle(.final(spans([("hello", 0.9), ("there", 0.9)])))
        #expect(fx == [.insertText("hello there "), .haptic(.land), .returnToPreviousKeyboard])
        #expect(s.committedText == "hello there ")
    }

    @Test func lowConfidenceWordOpensFanoutAndSuppressesReturn() {
        var s = KeyboardSession(useProxy: false); s.handle(.pressDown)
        let fx = s.handle(.final(spans([("hi", 0.9), ("kothari", 0.3)], alts: [1: ["Kothari", "Kotari"]])))
        #expect(!fx.contains(.returnToPreviousKeyboard))
        guard case .landed(_, let fan?) = s.state else { Issue.record("no fanout"); return }
        #expect(fan.spanIndex == 1 && fan.items.count == 2)
    }

    @Test func pickAlternateReplacesInPlace() {
        var s = KeyboardSession(useProxy: false); s.handle(.pressDown)
        s.handle(.final(spans([("hi", 0.9), ("kothari", 0.3)], alts: [1: ["Kothari"]])))
        let fx = s.handle(.pickAlternate(number: 1))
        #expect(fx == [.deleteBackward(8), .insertText("Kothari "), .haptic(.land)])
        #expect(s.committedText == "hi Kothari ")
        if case .landed(let sp, let fan) = s.state { #expect(sp[1].text == "Kothari" && sp[1].provenance.last == .repair && fan == nil) } else { Issue.record("state") }
    }

    @Test func outOfRangePickIsIgnored() {
        var s = KeyboardSession(useProxy: false); s.handle(.pressDown)
        s.handle(.final(spans([("kothari", 0.3)], alts: [0: ["Kothari"]])))
        #expect(s.handle(.pickAlternate(number: 4)) == [])
    }

    @Test func proxyRoundTripLandsProxyText() {
        var s = KeyboardSession(useProxy: true, persona: "casual")
        s.handle(.pressDown)
        let raw = spans([("hello", 0.9)])
        let fx = s.handle(.final(raw))
        #expect(fx == [.sendToProxy(KeyboardProxyRequest(requestID: 1, spans: raw, persona: "casual", sentAt: fx.sentAt!))])
        let polished = spans([("Hello.", 0.95)])
        #expect(s.handle(.proxyResponse(KeyboardProxyResponse(requestID: 1, spans: polished))).first == .insertText("Hello. "))
    }

    @Test func staleProxyResponseIgnoredAndTimeoutLandsRaw() {
        var s = KeyboardSession(useProxy: true); s.handle(.pressDown)
        s.handle(.final(spans([("raw", 0.9)])))
        #expect(s.handle(.proxyResponse(KeyboardProxyResponse(requestID: 99, spans: []))) == [])
        #expect(s.handle(.proxyTimeout).first == .insertText("raw "))
    }

    @Test func errorAndCancelStopASR() {
        var s = KeyboardSession(useProxy: false); s.handle(.pressDown)
        #expect(s.handle(.error("mic")) == [.stopASR, .haptic(.error)])
        #expect(s.handle(.pressDown).contains(.startASR))
        #expect(s.handle(.cancel) == [.stopASR] && s.state == .idle)
    }

    @Test func textReplacerMinimalEdit() {
        #expect(TextReplacer.ops(from: "hi kothari", to: "hi Kothari") == [.deleteBackward(7), .insertText("Kothari")])
        #expect(TextReplacer.ops(from: "abc", to: "abc") == [])
        #expect(TextReplacer.ops(from: "", to: "x") == [.insertText("x")])
        #expect(TextReplacer.ops(from: "ab", to: "a") == [.deleteBackward(1)])
    }
}

private extension Array where Element == KeyboardEffect {
    var sentAt: Date? { for f in self { if case .sendToProxy(let r) = f { return r.sentAt } }; return nil }
}

@Suite struct FanoutAndPillTests {
    @Test func fanoutDedupesAndCapsAtFive() {
        let sp = TranscriptSpan(text: "a", confidence: 0.2, audioRange: 0...1,
                                alternates: ["A", "b", "B", "c", "d", "e", "f"].enumerated().map { Alternate(text: $1, score: Float(10 - $0), source: .beam) })
        let fan = KeyboardRepairFanout(span: sp, index: 0)!
        #expect(fan.items.map(\.text) == ["A", "b", "c", "d", "e"])
        #expect(fan.alternateIndex(forNumber: 5) == 4 && fan.alternateIndex(forNumber: 6) == nil)
    }

    @Test func fanoutNilWithoutAlternatesOrWhenConfident() {
        #expect(KeyboardRepairFanout(span: TranscriptSpan(text: "x", confidence: 0.1, audioRange: 0...1), index: 0) == nil)
        #expect(KeyboardRepairFanout.lowestConfidence(in: spans([("ok", 0.9)], alts: [0: ["OK"]])) == nil)
        let flagged = spans([("ok", 0.9)], alts: [0: ["OK"]]).map { var s = $0; s.needsRepair = true; return s }
        #expect(KeyboardRepairFanout.lowestConfidence(in: flagged)?.spanIndex == 0)
    }

    @Test func pillModelFollowsState() {
        #expect(KeyboardPillModel(state: .idle).label == "Hold to talk")
        #expect(KeyboardPillModel(state: .listening(partial: "")).tint == .listening)
        #expect(KeyboardPillModel(state: .listening(partial: "yo")).label == "yo")
        #expect(KeyboardPillModel(state: .proxying(spans: [])).label == "Polishing…")
        let fan = KeyboardRepairFanout.lowestConfidence(in: spans([("k", 0.2)], alts: [0: ["K"]]))
        #expect(KeyboardPillModel(state: .landed(spans: [], fanout: fan)).showsFanout)
        #expect(KeyboardPillModel(state: .error("x"), level: 3).level == 1)
        #expect(KeyboardPillModel.bars(level: 0, count: 4).allSatisfy { $0 == 0.08 })
    }
}

@Suite struct PersonaPickerTests {
    @Test func defaultsToPlainAndCycles() {
        var p = PersonaPicker(entries: [.init(id: "a", title: "A", text: "casual")])
        #expect(p.selected == PersonaPicker.none && p.personaText == nil)
        p.cycle(); #expect(p.personaText == "casual")
        p.cycle(); #expect(p.selectedID == "none")
    }

    @Test func selectRejectsUnknownAndRoundTripsCodable() throws {
        var p = PersonaPicker(entries: [.init(id: "a", title: "A", text: "t")], selectedID: "zzz")
        #expect(p.selectedID == "none")
        p.select("nope"); #expect(p.selectedID == "none")
        p.select("a")
        let back = try JSONDecoder().decode(PersonaPicker.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }
}

@Suite struct ProxyTests {
    @Test func codecRoundTripPreservesSpans() throws {
        let req = KeyboardProxyRequest(requestID: 7, spans: spans([("a", 0.4)], alts: [0: ["A"]]), persona: "p")
        let back = try KeyboardProxyCodec.decode(KeyboardProxyRequest.self, from: KeyboardProxyCodec.encode(req))
        #expect(back.spans == req.spans && back.persona == "p" && back.requestID == 7)
    }

    @Test func codecRejectsUnknownVersion() {
        let data = Data(#"{"version":99,"requestID":1,"spans":[]}"#.utf8)
        #expect(throws: KeyboardProxyCodecError.versionMismatch(99)) { try KeyboardProxyCodec.decode(KeyboardProxyResponse.self, from: data) }
    }

    @Test func fileMailboxIsTakeOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kbmail-\(UUID().uuidString)")
        let box = try FileKeyboardMailbox(directory: dir)
        #expect(try box.takeRequest() == nil)
        try box.post(KeyboardProxyRequest(requestID: 1, spans: []))
        #expect(try box.takeRequest()?.requestID == 1)
        #expect(try box.takeRequest() == nil)
    }

    @Test func clientServerRoundTripOverLoopback() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kbmail-\(UUID().uuidString)")
        let box = try FileKeyboardMailbox(directory: dir)
        let bell = LoopbackDoorbell()
        let server = KeyboardProxyServer(mailbox: box, doorbell: bell) { req in req.spans.map { $0.rewritten($0.text.uppercased(), by: .style) } }
        server.start()
        let client = KeyboardProxyClient(mailbox: box, doorbell: bell)
        let resp = await client.send(KeyboardProxyRequest(requestID: 3, spans: spans([("hi", 0.9)])))
        #expect(resp?.spans.first?.text == "HI" && resp?.requestID == 3)
    }

    @Test func clientTimesOutWithoutServer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kbmail-\(UUID().uuidString)")
        let client = KeyboardProxyClient(mailbox: try FileKeyboardMailbox(directory: dir), doorbell: LoopbackDoorbell())
        let resp = await client.send(KeyboardProxyRequest(requestID: 1, spans: []), timeout: 0.1)
        #expect(resp == nil)
    }
}

@Suite struct ASRTests {
    @Test func mockASRScriptsPartialsThenFinal() throws {
        let asr = MockKeyboardASR(partials: ["h", "hi"], final: .success(spans([("hi", 0.9)])))
        var got: [String] = []; var final: [TranscriptSpan]?
        let lock = NSLock()
        try asr.start(onPartial: { p in lock.lock(); got.append(p); lock.unlock() },
                      onFinal: { r in lock.lock(); final = try? r.get(); lock.unlock() })
        asr.stop()
        #expect(got == ["h", "hi"] && final?.first?.text == "hi")
        asr.isAvailable = false
        #expect(throws: KeyboardASRError.unavailable) { try asr.start(onPartial: { _ in }, onFinal: { _ in }) }
    }

    @Test func spanBuilderSplitsWordsWithRanges() {
        let s = KeyboardSpanBuilder.spans(from: "one  two", confidence: 0.7, duration: 2)
        #expect(s.map(\.text) == ["one", "two"] && s[1].audioRange == 1.0...2.0 && s[0].provenance == [.asr])
        #expect(KeyboardSpanBuilder.spans(from: "  ").isEmpty)
    }
}

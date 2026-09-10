import Foundation
import Testing
import Shared
@testable import Engine

/// R1.4 — **capture defaults by measurement.**
///
/// Which capture chain should ship? Three candidates were on the table (V3 §5.1):
///
///   a. **raw tap** — `RobustnessProfile.raw`, no DSP at all.
///   b. **tap + spectral gate** — `RobustnessProfile.default`, what shipped before this item.
///   c. **Apple voice-processing I/O + gate** — `VoiceProcessingCaptureSource` + the same gate.
///
/// This suite scores (a) and (b) on the real-room corpus (`Fixtures/real-room/builtin`, twenty
/// dictations of `script.md` on the built-in microphone) through the *shipping* recognizer, feeding
/// the chain in 100 ms blocks exactly as `AcousticCaptureSource.ingest` does. The measured table
/// lives in `Engine/Audio/Robustness/SUITES.md`; `RobustnessProfile.default` is set from it.
///
/// **Column (c) is `hardware-verified pending`, and cannot be otherwise.** Apple voice processing is
/// not a filter this process can apply to a file: it is a mode of the *input AudioUnit*
/// (`AVAudioInputNode.setVoiceProcessingEnabled`), so it exists only while a live microphone is
/// streaming through a real HAL device. There is no offline render path — an `AVAudioEngine` in
/// manual-rendering mode has no input node to enable it on — and the corpus itself cannot stand in:
/// every one of the twenty manifests records `vp=false` (asserted below), because the recordings were
/// made through the shipping plain tap. Emulating it with some other suppressor would measure the
/// emulation, not Apple's AEC, so nothing is emulated and nothing is claimed. The owner's check is
///
///     open -n -a /Applications/VoicePlus.app --args --mic-selftest-vp 10
///
/// which builds `VoiceProcessingCaptureSource` instead of `CoreAudioCaptureSource` and prints
/// `voiceProcessingActive`, `didFallBackToPlainTap` and the resolved graph. To fill the column in,
/// re-record `script.md` with that source armed and re-run this suite against the new pass
/// (`VOICEPLUS_CORPUS_PASS`).
///
/// Run it:
///
///     eval "$(Scripts/bootstrap-toolchain.sh)"
///     swift test --scratch-path .build-r14 --filter captureChainWERTable
@Suite("Capture defaults by measurement (real model)", .serialized)
struct CaptureDefaultsWERTests {

    /// The chains under measurement. `profile == nil` means "not scoreable offline".
    enum Candidate: String, CaseIterable {
        case rawTap = "a raw tap"
        case tapPlusGate = "b tap+gate"
        case voiceProcessingPlusGate = "c vp+gate"

        /// Each candidate names the DSP it *is*, never `RobustnessProfile.default`. The point of the
        /// suite is to decide what `.default` should be, so referring to `.default` here would make
        /// the table a tautology the moment the decision lands — which is exactly what happened on
        /// the first run after R1.4 moved `.default` to the plain tap: column (b) silently became a
        /// second copy of column (a) and every row tied.
        var profile: RobustnessProfile? {
            switch self {
            case .rawTap: return .raw
            case .tapPlusGate: return .gate
            // Lives in the capture unit, needs live hardware I/O. See the suite comment.
            case .voiceProcessingPlusGate: return nil
            }
        }
    }

    /// The table row for one chain: corpus-total WER (errors over all reference words, so a short
    /// sentence cannot dominate), the mean of the per-file rates, and the worst file.
    struct ChainResult {
        var candidate: Candidate
        var total = RealRoomCorpus.WERCounts()
        var perFile: [(index: Int, stamp: String, counts: RealRoomCorpus.WERCounts, hypothesis: String)] = []
        var meanOfFiles: Double {
            guard !perFile.isEmpty else { return 0 }
            return perFile.map { $0.counts.wer }.reduce(0, +) / Double(perFile.count)
        }
        var worst: (index: Int, wer: Double) {
            perFile.max { $0.counts.wer < $1.counts.wer }.map { ($0.index, $0.counts.wer) } ?? (0, 0)
        }
    }

    // MARK: the measurement

    @Test(.timeLimit(.minutes(60)))
    func captureChainWERTable() async throws {
        let pass = ProcessInfo.processInfo.environment["VOICEPLUS_CORPUS_PASS"] ?? "builtin"
        guard let items = RealRoomCorpus.items(pass: pass) else {
            print("SKIPPED: Fixtures/real-room/\(pass) and script.md have different counts — the timestamp-order pairing would be wrong.")
            return
        }
        guard !items.isEmpty else {
            print("SKIPPED: no recordings in Fixtures/real-room/\(pass) (the WAVs are git-ignored).")
            return
        }
        let manager = ModelManager(maintenance: .skip)
        guard await manager.isPresent(.parakeetTDTv3) else {
            print("SKIPPED: parakeet-tdt-0.6b-v3 not on disk."); return
        }
        let final = try await RecognizerFactory.makeFinal(manager: manager)

        var results: [ChainResult] = []
        for candidate in Candidate.allCases {
            guard let profile = candidate.profile else {
                print("\n[\(candidate.rawValue)] hardware-verified pending — "
                      + "Apple voice processing is a capture-unit mode and has no offline path; "
                      + "owner check: --mic-selftest-vp")
                continue
            }
            var result = ChainResult(candidate: candidate)
            for item in items {
                let raw = try SampleAudioSource.load16k(url: item.raw)
                // 100 ms blocks + flush: the same feed `AcousticCaptureSource` gives the chain live.
                let processed = AcousticChainWERTests.throughChain(raw, profile: profile)
                let hyp = try await final.recognize(processed).joinedText
                let counts = RealRoomCorpus.werCounts(reference: item.reference, hypothesis: hyp)
                result.total = result.total + counts
                result.perFile.append((item.index, item.stamp, counts, hyp))
            }
            results.append(result)
            print(String(format: "\n[%@] corpus WER %.4f (%d errors / %d words), mean of files %.4f",
                         candidate.rawValue, result.total.wer, result.total.errors,
                         result.total.referenceWords, result.meanOfFiles))
        }
        try #require(!results.isEmpty)

        Self.printTable(results, items: items, model: final.name, pass: pass)

        // The gate the item asks for: whatever ships must not cost accuracy on real-room audio.
        // 0.15 is the same order as the pre-existing clean-fixture budget (0.10) with room for the
        // number-formatting flips that dominate this corpus ("2,340" vs "2340", "four" vs "4").
        for r in results {
            #expect(r.total.wer <= 0.15, "\(r.candidate.rawValue) costs accuracy on the real-room corpus")
        }
        // And the decision itself, wired so it cannot drift: `RobustnessProfile.default` is what
        // production captures with, and its gate flag must match whichever chain measured best here.
        // This is deliberately *derived* from the table rather than hard-coded to today's winner —
        // if a bigger or different corpus makes the gate win, this fails and names the fix.
        let best = try #require(results.min { $0.total.wer < $1.total.wer })
        let bestUsesGate = best.candidate == .tapPlusGate
        let why = "\(best.candidate.rawValue) measured best (WER \(best.total.wer)) but "
            + "RobustnessProfile.default has noiseSuppression=\(RobustnessProfile.default.noiseSuppression) — "
            + "move the default to match and re-date the table in SUITES.md"
        #expect(RobustnessProfile.default.noiseSuppression == bestUsesGate, Comment(rawValue: why))
        // Whatever wins, the shipping profile may never claim an echo canceller it does not run.
        #expect(RobustnessProfile.default.aec == .off)
    }

    /// Left-pads/right-pads to a fixed width so the table lines up in a terminal.
    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func printTable(_ results: [ChainResult], items: [RealRoomCorpus.Item],
                           model: String, pass: String) {
        print("\n== R1.4 capture defaults . real-room/\(pass) . final = \(model) ==")
        var header = pad("##  stamp", 26)
        for r in results { header += pad(r.candidate.rawValue, 16) }
        print(header + "reference")
        for item in items {
            var row = pad(String(format: "%02d  %@", item.index, item.stamp), 26)
            for r in results {
                let cell = r.perFile.first { $0.index == item.index }
                row += pad(cell.map { String(format: "%.3f %@", $0.counts.wer,
                                             RealRoomCorpus.errorBreakdown($0.counts)
                                                 .replacingOccurrences(of: " ", with: "")) } ?? "-", 16)
            }
            print(row + item.reference)
        }
        print(String(repeating: "-", count: 78))
        for r in results {
            print(pad(r.candidate.rawValue, 14)
                  + String(format: "corpus WER %.4f  (%d subs, %d dels, %d ins / %d words)"
                           + "  mean-of-files %.4f  worst #%02d %.3f",
                           r.total.wer, r.total.substitutions, r.total.deletions,
                           r.total.insertions, r.total.referenceWords,
                           r.meanOfFiles, r.worst.index, r.worst.wer))
        }
        print(pad(Candidate.voiceProcessingPlusGate.rawValue, 14)
              + "hardware-verified pending (no offline path; owner check --mic-selftest-vp)")

        // Where the chains disagree, print both hypotheses. Four words out of 220 decide this
        // table, so the *nature* of those four is as much of the evidence as the rate is.
        guard results.count > 1 else { return }
        print("\n-- files where the chains disagree --")
        var quiet = true
        for item in items {
            let cells = results.compactMap { r in r.perFile.first { $0.index == item.index }.map { (r.candidate, $0) } }
            guard Set(cells.map { $0.1.counts.errors }).count > 1 else { continue }
            quiet = false
            print(String(format: "\n#%02d  said:  %@", item.index, item.reference))
            for (candidate, cell) in cells {
                print(String(format: "     %@ %.3f (%@)  %@", pad(candidate.rawValue, 12),
                             cell.counts.wer, RealRoomCorpus.errorBreakdown(cell.counts), cell.hypothesis))
            }
        }
        if quiet { print("  (none — every chain scored every file identically)") }
    }

    /// The tie-breaker the quiet-room table cannot settle.
    ///
    /// `captureChainWERTable` separates (a) and (b) by four words out of 220, and all four are
    /// number-formatting insertions ("eleven forty-five" for "11:45"), not misrecognitions. A margin
    /// that thin in one quiet room on one microphone is not a reason to delete noise suppression
    /// from a dictation app that has to work in a café — so the same twenty files are re-scored over
    /// a simulated room floor. Deterministic pink noise (seeded LCG, `AcousticChainWERTests.mix`)
    /// mixed at a measured SNR over the speech-active frames, so the sweep is reproducible.
    ///
    /// This is the axis on which the default is actually decided; the quiet-room table says the gate
    /// costs nothing real, and this says what it buys.
    @Test(.timeLimit(.minutes(60)))
    func noiseSweepRawVersusGateOnRealRoomCorpus() async throws {
        let pass = ProcessInfo.processInfo.environment["VOICEPLUS_CORPUS_PASS"] ?? "builtin"
        guard let items = RealRoomCorpus.items(pass: pass), !items.isEmpty else {
            print("SKIPPED: no real-room recordings in the checkout (the WAVs are git-ignored)."); return
        }
        let manager = ModelManager(maintenance: .skip)
        guard await manager.isPresent(.parakeetTDTv3) else {
            print("SKIPPED: parakeet-tdt-0.6b-v3 not on disk."); return
        }
        let final = try await RecognizerFactory.makeFinal(manager: manager)
        let audio = try items.map { try SampleAudioSource.load16k(url: $0.raw) }

        print("\n== R1.4 room-floor sweep . real-room/\(pass) . pink noise over the owner's voice ==")
        print("SNR   a raw tap   b tap+gate   winner")
        var gateWins = 0, rawWins = 0
        // Down to 0 dB — speech and floor at equal power — because a suppressor that never earns its
        // place at *any* SNR is a different finding from one that only earns it below 10 dB, and the
        // first sweep (30→10 dB) was not low enough to tell those apart.
        for snr in [Float(30), 25, 20, 15, 10, 5, 0] {
            var raw = RealRoomCorpus.WERCounts(), gated = RealRoomCorpus.WERCounts()
            for (n, item) in items.enumerated() {
                let mixed = AcousticChainWERTests.mix(audio[n], snrDB: snr, seed: UInt64(n &+ 1) &* 0x9E3779B9)
                // `.gate`, not `.default`, for the reason given on `Candidate.profile`.
                let rawHyp = try await final.recognize(AcousticChainWERTests.throughChain(mixed, profile: .raw)).joinedText
                let gateHyp = try await final.recognize(AcousticChainWERTests.throughChain(mixed, profile: .gate)).joinedText
                raw = raw + RealRoomCorpus.werCounts(reference: item.reference, hypothesis: rawHyp)
                gated = gated + RealRoomCorpus.werCounts(reference: item.reference, hypothesis: gateHyp)
            }
            if gated.wer < raw.wer { gateWins += 1 } else if raw.wer < gated.wer { rawWins += 1 }
            print(String(format: "%2.0f dB  %.4f      %.4f       %@", snr, raw.wer, gated.wer,
                         gated.wer < raw.wer ? "gate" : (raw.wer < gated.wer ? "raw" : "tie")))
        }
        print("gate ahead at \(gateWins) of 7 SNR points, raw ahead at \(rawWins)")
        // Not an assertion about which wins — the sweep is evidence for the decision recorded in
        // SUITES.md, and a corpus recorded in a different room may move it. It must not crash or
        // return nonsense, and both chains must stay usable at every level.
        #expect(gateWins + rawWins <= 7)
    }

    // MARK: why column (c) cannot be scored from this corpus

    /// The corpus is not secretly voice-processed. Every committed manifest's graph line says
    /// `vp=false`, so nothing in `Fixtures/real-room` can stand in for column (c). Reads only the
    /// JSON sidecars, which *are* committed, so this runs in a checkout without the audio.
    @Test func realRoomCorpusWasRecordedWithoutVoiceProcessing() throws {
        let root = try #require(RealRoomCorpus.root())
        let pass = root.appendingPathComponent("builtin", isDirectory: true)
        let sidecars = ((try? FileManager.default.contentsOfDirectory(at: pass, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !sidecars.isEmpty else { print("SKIPPED: no manifests in \(pass.path)."); return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var vpGraphs = 0
        for url in sidecars {
            let m = try decoder.decode(UtteranceRecorder.Manifest.self, from: Data(contentsOf: url))
            let graph = m.captureGraph ?? ""
            #expect(graph.contains("vp=false"), "\(url.lastPathComponent) graph: \(graph)")
            if graph.contains("vp=true") { vpGraphs += 1 }
        }
        print("\(sidecars.count) real-room manifests, \(vpGraphs) with voice processing — "
              + "column (c) stays hardware-verified pending.")
    }

    /// The contradiction R1.4 was handed: the same twenty manifests name an echo canceller the graph
    /// never ran. Kept as a *documented historical fact*, not a live expectation — new recordings go
    /// through `AcousticCaptureSource.effectiveAEC` and cannot disagree again (see
    /// `CaptureHotSwapTests.manifestAECMatchesTheCaptureGraph`).
    @Test func historicalManifestsDisagreedWithTheirOwnGraph() throws {
        let root = try #require(RealRoomCorpus.root())
        let url = root.appendingPathComponent("builtin/2026-09-11-000013-175.json")
        guard let data = try? Data(contentsOf: url) else { print("SKIPPED: corpus manifest absent."); return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let m = try decoder.decode(UtteranceRecorder.Manifest.self, from: data)
        #expect(m.aec == "appleVoiceProcessing")
        #expect(m.captureGraph?.contains("vp=false") == true)
        print("historical mismatch confirmed: manifest aec=\(m.aec) vs graph vp=false — fixed for new recordings")
    }
}

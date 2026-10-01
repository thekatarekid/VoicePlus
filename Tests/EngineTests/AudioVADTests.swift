import Foundation
import Testing
@testable import Engine
@testable import Shared

/// Offline VAD accuracy on Fixtures/audio/vad with labels.json. Runs the energy fallback always;
/// runs Silero too — always resolvable since V5 C6/K17 (never downloads).
@Suite struct VADAccuracyTests {
    struct Row { let file: String; let score: VADScore; let predicted: Int; let truth: Int }

    private func evaluate(_ vad: any VADProtocol) async throws -> [Row] {
        let labels = try VADLabels.load(url: try #require(AudioFixtures.url("vad", "labels.json")))
        var rows: [Row] = []
        for url in AudioFixtures.list("vad") {
            let wav = try WAVFile.read(url: url)
            let predicted = try await vad.segments(in: wav.samples)
            let truth = labels.ranges(for: url.lastPathComponent)
            rows.append(Row(file: url.lastPathComponent, score: VADScore.score(predicted: predicted, truth: truth, duration: wav.duration), predicted: predicted.count, truth: truth.count))
        }
        return rows
    }

    private func report(_ name: String, _ rows: [Row]) -> Double {
        let mean = rows.map(\.score.f1).reduce(0, +) / Double(rows.count)
        print("VAD[\(name)] mean F1 = \(String(format: "%.3f", mean))")
        for r in rows {
            print(String(format: "  %@  P=%.3f R=%.3f F1=%.3f  segs %d/%d", r.file, r.score.precision, r.score.recall, r.score.f1, r.predicted, r.truth))
        }
        return mean
    }

    @Test func energyVADMeetsTargets() async throws {
        let rows = try await evaluate(EnergyVAD())
        #expect(rows.count == 6)
        let mean = report("energy", rows)
        for r in rows {
            let target = r.file.contains("floor") ? 0.85 : 0.95
            #expect(r.score.f1 >= target, "\(r.file) F1 \(r.score.f1)")
            #expect(r.predicted == r.truth, "\(r.file) segment count")
        }
        #expect(mean >= 0.95)
    }

    @Test func energyVADIsSilentOnSilenceFixtures() async throws {
        for url in AudioFixtures.list("silence") {
            let wav = try WAVFile.read(url: url)
            let spans = try await EnergyVAD().segments(in: wav.samples)
            #expect(spans.isEmpty, Comment(rawValue: url.lastPathComponent))
        }
    }

    /// V5 K17: no longer skipped — the checked-in copy (`Packaging/vad/`) resolves in the test process.
    @Test func sileroVADWhenModelIsOnDisk() async throws {
        let silero = try #require(await SileroVAD.loadIfAvailable(), "Silero must resolve in tests (K17)")
        let rows = try await evaluate(silero)
        let mean = report("silero", rows)
        #expect(mean >= 0.85)
    }

    @Test func factoryNeverDownloads() async {
        let vad = await VADFactory.make(preferSilero: false)
        #expect(vad.name == "energy")
        let auto = await VADFactory.make()
        #expect(auto.name == "silero", "V5 C6/K17: the shipped model resolves")
    }

    @Test func scoringMath() {
        let s = VADScore.score(predicted: [0...1], truth: [0.5...1.5], duration: 2)
        #expect(abs(s.precision - 0.5) < 0.02 && abs(s.recall - 0.5) < 0.02 && abs(s.f1 - 0.5) < 0.02)
        #expect(VADScore.score(predicted: [], truth: [], duration: 1).f1 == 1)
    }
}

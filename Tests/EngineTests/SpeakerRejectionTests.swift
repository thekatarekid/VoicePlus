import Foundation
import Shared
import Testing
@testable import Engine

/// TV/podcast rejection suite: enroll one TTS voice from the fixture manifests, then play every
/// other voice's utterance through the gate and count how many are (correctly) rejected.
@Suite("Speaker rejection suite (P5.3)")
struct SpeakerRejectionTests {
    struct Entry: Decodable { let file: String; let speaker: String; let suite: String }

    static func corpus() throws -> [(speaker: String, samples: [Float])] {
        let root = try #require(AppPaths.fixturesDirectory()).appendingPathComponent("audio")
        var out: [(String, [Float])] = []
        for suite in ["clean", "entity", "technical", "commands"] {
            let dir = root.appendingPathComponent(suite)
            let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
            for e in entries where ["Samantha", "Daniel", "Rishi"].contains(e.speaker) {
                out.append((e.speaker, try WAVFile.read(url: dir.appendingPathComponent(e.file)).mono))
            }
        }
        return out
    }

    @Test func fallbackEmbedderRejectsNonEnrolledVoices() throws {
        let corpus = try Self.corpus()
        let emb = MFCCEmbedder()
        let embs = try corpus.map { ($0.speaker, try emb.embed($0.samples)) }
        var rejected = 0, impostors = 0, accepted = 0, own = 0
        for voice in ["Samantha", "Daniel", "Rishi"] {
            let mine = embs.filter { $0.0 == voice }
            #expect(mine.count >= 6)
            var enr = SpeakerEnrollment()
            for e in mine.prefix(3) { enr.record(e.1) }
            let gate = SpeakerGate(profile: try #require(enr.profile), threshold: SpeakerGate.defaultThreshold(for: emb))
            for (spk, e) in embs.dropFirst(0) {
                if spk == voice {
                    if mine.prefix(3).contains(where: { $0.1 == e }) { continue }
                    own += 1; if gate.verdict(for: e).isUser { accepted += 1 }
                } else {
                    impostors += 1; if !gate.verdict(for: e).isUser { rejected += 1 }
                }
            }
        }
        let rejection = Double(rejected) / Double(impostors)
        let acceptance = Double(accepted) / Double(own)
        print("speaker-rejection: \(rejected)/\(impostors) non-enrolled rejected = \(String(format: "%.2f", rejection * 100))%; " +
              "own-voice accepted \(accepted)/\(own) = \(String(format: "%.1f", acceptance * 100))%")
        #expect(rejection >= 0.99, "rejection \(rejection)")
        #expect(acceptance >= 0.8, "own-voice acceptance \(acceptance)")
    }
}

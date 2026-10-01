import FluidAudio
import Foundation
import Shared
import Testing
@testable import Engine

/// S9 — the engine layer's slice of the recovery catalogue (design_v1 §10): `RecoveryID`, the
/// classification of engine errors, and `EngineMessage.describe` returning catalogue headlines only.
@Suite("Engine errors map to recovery catalogue headlines")
struct RecoveryIDTests {
    private struct FixtureError: Decodable { let id: String; let headline: String }
    private struct Copy: Decodable { let errors: [FixtureError] }

    private static func fixture() throws -> [FixtureError] {
        let dir = try #require(AppPaths.fixturesDirectory())
        let data = try Data(contentsOf: dir.appendingPathComponent("design/design_copy.json"))
        return try JSONDecoder().decode(Copy.self, from: data).errors
    }

    private enum Bare: Error { case somethingSpecific }
    private struct Wordy: LocalizedError {
        var errorDescription: String? { "The file “weight.bin.partial” at /Models/x couldn’t be opened (OSStatus -43)." }
    }

    /// One of every engine-layer error shape `classify` knows, with the id it must map to.
    static let samples: [(Error, RecoveryID)] = [
        (EngineError.alreadyListening, .K04),
        (EngineError.modelUnavailable("tdt-v3"), .M01),
        (EngineError.notListening, .X08),
        (EngineError.fixtureNotFound("clip"), .X08),
        (EngineError.fixtureInvalid("clip"), .X08),
        (AudioCaptureError.noInputDevice, .A01),
        (AudioCaptureError.notPermitted(status: "turned off"), .P01),
        (AudioCaptureError.engineStartFailed("kAudioUnitErr_FormatNotSupported"), .A03),
        (AudioCaptureError.deviceSelectionFailed(-10851), .A03),
        (AudioCaptureError.formatMismatch(hardware: 48_000, client: 44_100), .A04),
        (AudioCaptureError.noAudio(seconds: 1.5), .A05),
        (AudioCaptureError.busy(owner: "meeting"), .A09),
        (ModelManagerError.unsupported(.parakeetTDTv3), .M06),
        (ModelManagerError.notPresent(.parakeetTDTv3), .M08),
        (ModelManagerError.verificationFailed(.parakeetTDTv3, ["Encoder.mlmodelc/weights/weight.bin"]), .M03),
        (ModelManagerError.incomplete(.parakeetTDTv3, ["Encoder.mlmodelc/weights/weight.bin.partial"]), .M02),
        (DownloadError.httpStatus(503, "https://huggingface.co/x"), .M04),
        (DownloadError.checksumMismatch(path: "/Models/a.bin", expected: "aa", actual: "bb"), .M03),
        (DownloadError.sizeMismatch(path: "/Models/a.bin", expected: 2, actual: 1), .M03),
        (DownloadError.cancelled, .M04),
        (DownloadError.noRemoteFiles(.parakeetTDTv3), .M04),
        (DownloadError.incompleteDownload(.parakeetTDTv3, ["a.bin"]), .M02),
        (ASRError.invalidAudioData, .A07),
        (ASRError.notInitialized, .M07),
        (ASRError.modelLoadFailed, .M07),
        (ASRError.modelCompilationFailed, .M07),
        (ASRError.encoderInstantiationFailed("ANE"), .M07),
        (ASRError.unsupportedPlatform("x86_64"), .M06),
        (ASRError.processingFailed("decoder"), .T01),
        (RefinementError.unavailableOnThisSystem("macOS 14"), .M06),
        (RefinementError.emptyAudio, .A07),
        (RefinementError.weightsMissing(searched: ["/Models/qwen3"]), .T03),
        (RefinementError.deadlineExceeded(.seconds(2)), .T03),
        (RefinementError.backendFailure("MLMultiArray"), .T03),
        (SpeakerError.tooShort(samples: 10), .X03),
        (SpeakerError.backendUnavailable, .X03),
        (BiasVocabulary.LoadError.unsupportedFormat("xml"), .X04),
        (UnavailableIndicBackend.NotInstalled(status: .noModelsDirectory), .M01),
        (URLError(.notConnectedToInternet), .M04),
        (NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [
            NSFilePathErrorKey: "/Models/parakeet/Decoder.mlmodelc/weights/weight.bin.partial",
            NSLocalizedDescriptionKey: "The file “weight.bin.partial” doesn’t exist.",
        ]), .M02),
        (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), .M05),
        (NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), .M05),
        (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
        ]), .M05),
        (NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [
            NSFilePathErrorKey: "/tmp/notes.txt", NSLocalizedDescriptionKey: "The file “notes.txt” doesn’t exist.",
        ]), .X08),
        (Bare.somethingSpecific, .X08),
        (Wordy(), .X08),
    ]

    @Test func recoveryIDsAreTheFixturesFiftyNineInOrder() throws {
        let ids = try Self.fixture().map(\.id)
        #expect(ids.count == 59)
        #expect(RecoveryID.allCases.map(\.rawValue) == ids)
    }

    @Test func everyEngineHeadlineIsTheFixturesVerbatim() throws {
        let fixture = Dictionary(uniqueKeysWithValues: try Self.fixture().map { ($0.id, $0.headline) })
        let slice = RecoveryID.allCases.compactMap { id in EngineMessage.engineHeadline(for: id).map { (id, $0) } }
        // 21 since `AudioCaptureError.notPermitted` made P01 reachable from the engine layer.
        #expect(slice.count == 21)
        for (id, headline) in slice {
            #expect(headline == fixture[id.rawValue], "\(id.rawValue)")
        }
    }

    @Test func eachEngineErrorMapsToItsEntry() {
        for (error, id) in Self.samples {
            #expect(EngineMessage.recoveryID(for: error) == id, "\(error)")
        }
    }

    /// Every id `classify` can produce has a headline in the slice, so `describe` never falls back.
    /// The Qwen3-ASR second pass exists only on macOS 15+, so its errors cannot sit in `samples`.
    @Test func qwenRefinementErrorsMapLikeRefinementErrors() {
        let cases: [(Qwen3AsrError, RecoveryID)] = [
            (.unsupportedHardware, .M06), (.modelNotFound("qwen3_asr_embeddings.bin"), .T03),
            (.invalidVocabulary, .T03), (.encoderFailed("x"), .T03), (.decoderFailed("x"), .T03),
            (.generationFailed("x"), .T03), (.downloadUnavailable("x"), .T03), (.audioTooLong("x"), .T03),
        ]
        for (error, id) in cases {
            #expect(EngineMessage.recoveryID(for: error) == id, "\(error)")
            #expect(EngineMessage.engineHeadline(for: id) != nil)
            #expect(!EngineMessage.describe(error, log: Log(category: "s9-test", buffer: LogBuffer(capacity: 1)))
                .contains("qwen3"))
        }
    }

    @Test func everyReachableIDHasAnEngineHeadline() {
        for (error, _) in Self.samples {
            let id = EngineMessage.recoveryID(for: error)
            #expect(EngineMessage.engineHeadline(for: id) != nil, "\(id.rawValue) has no engine headline")
        }
    }

    @Test func describeReturnsTheCatalogueHeadlineAndLogsTheRawText() {
        let buffer = LogBuffer(capacity: 10)
        let log = Log(category: "s9-test", buffer: buffer)
        let error = ModelManagerError.incomplete(.parakeetTDTCTC110m, ["Decoder.mlmodelc/weights/weight.bin.partial"])
        let headline = EngineMessage.describe(error, log: log)
        #expect(headline == "The speech model didn’t finish downloading")
        let logged = buffer.snapshot().map(\.message).joined(separator: "\n")
        #expect(logged.contains("M02"))
        #expect(logged.contains("Parakeet TDT-CTC 110M"), "the technical detail belongs in the log")
        #expect(!headline.contains("Parakeet"), "and only there")
    }

    /// Design §10: no raw enum token, camelCase identifier, `…Error` type name, scratch file or path.
    @Test func noDescribedHeadlineLeaksATechnicalToken() throws {
        let leak = try Regex(#"[A-Za-z]+Error|\b[a-z]+[A-Z][A-Za-z]*\b|\.bin\b|\.partial\b|\.part\b|/[A-Za-z0-9_.-]+|OSStatus|-?\d{3,}"#)
        for (error, _) in Self.samples {
            let headline = EngineMessage.describe(error, log: Log(category: "s9-test", buffer: LogBuffer(capacity: 1)))
            #expect(headline.firstMatch(of: leak) == nil, "\(headline) (from \(error))")
            #expect(!headline.isEmpty)
        }
    }

    @Test func engineErrorReadableIsItsCatalogueHeadline() {
        #expect(EngineError.modelUnavailable("final").readable == "Install a speech model")
        #expect(EngineError.alreadyListening.readable == "Finishing your previous dictation")
        #expect(EngineError.notListening.readable == "VoicePlus couldn’t finish this step")
        #expect(EngineError.modelUnavailable("tdt-v3").technicalDetail == "No speech model is ready yet (tdt-v3).")
    }

    @Test func technicalDetailKeepsWhatTheErrorSaysForDiagnostics() {
        #expect(EngineMessage.technicalDetail(ASRError.invalidAudioData)
                == "Invalid audio data provided. Must be at least 300ms of 16kHz audio.")
        #expect(EngineMessage.technicalDetail(Bare.somethingSpecific) == "somethingSpecific")
        let url = URLError(.notConnectedToInternet)
        #expect(EngineMessage.technicalDetail(url) == url.localizedDescription)
    }
}

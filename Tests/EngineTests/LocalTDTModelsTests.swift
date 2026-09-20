import Foundation
import Testing
@testable import Engine

struct LocalTDTModelsTests {
    @Test func readsBothPublishedVocabularyFormats() throws {
        #expect(try LocalTDTModels.parseVocabulary(Data(#"{"0":"<blank>","1":"▁hello"}"#.utf8))
            == [0: "<blank>", 1: "▁hello"])
        #expect(try LocalTDTModels.parseVocabulary(Data(#"["<blank>","▁hello"]"#.utf8))
            == [0: "<blank>", 1: "▁hello"])
    }

    @Test(arguments: ["{}", "[]", #"{"bad":"word"}"#, #"{"-1":"word"}"#,
                      #"{"01":"one","1":"duplicate"}"#, #"{"0":17}"#])
    func refusesMalformedVocabulary(json: String) {
        #expect(throws: (any Error).self) { try LocalTDTModels.parseVocabulary(Data(json.utf8)) }
    }

    @Test func productionV3LoaderFailsLocallyWithoutCreatingOrRepairingModelDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("read-only-models")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vocabulary = directory.appendingPathComponent("parakeet_vocab.json")
        let bytes = Data(#"{"0":"<blank>"}"#.utf8)
        try bytes.write(to: vocabulary)
        await #expect(throws: (any Error).self) {
            _ = try await ModelManager.coreMLLoader(.parakeetTDTv3,
                ModelCatalog.descriptor(.parakeetTDTv3), directory)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["read-only-models"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["parakeet_vocab.json"])
        #expect(try Data(contentsOf: vocabulary) == bytes)
    }
}

import CoreML
import FluidAudio
import Foundation

/// Load the verified directory exactly as located, including read-only app resources. The upstream
/// AsrModels.load re-resolves the directory through ModelHub and may download/recover its cache.
enum LocalTDTModels {
    static func loadV3(from directory: URL) async throws -> AsrModels {
        let vocabulary = try parseVocabulary(Data(contentsOf:
            directory.appendingPathComponent(ModelNames.ASR.vocabularyFile)))
        let configuration = AsrModels.defaultConfiguration()
        let preprocessing = MLModelConfiguration()
        preprocessing.computeUnits = .cpuOnly
        let preprocessor = try await MLModel.load(contentsOf:
            directory.appendingPathComponent(ModelNames.ASR.preprocessorFile), configuration: preprocessing)
        let encoder = try await MLModel.load(contentsOf:
            directory.appendingPathComponent(ModelNames.ASR.encoderFile), configuration: configuration)
        let decoder = try await MLModel.load(contentsOf:
            directory.appendingPathComponent(ModelNames.ASR.decoderFile), configuration: configuration)
        let joint = try await MLModel.load(contentsOf:
            directory.appendingPathComponent(ModelNames.ASR.jointV3File), configuration: configuration)
        return AsrModels(encoder: encoder, preprocessor: preprocessor, decoder: decoder, joint: joint,
                         configuration: configuration, vocabulary: vocabulary, version: .v3)
    }

    static func parseVocabulary(_ data: Data) throws -> [Int: String] {
        let json = try JSONSerialization.jsonObject(with: data)
        let vocabulary: [Int: String]
        if let tokens = json as? [String] {
            vocabulary = Dictionary(uniqueKeysWithValues: tokens.enumerated().map { ($0.offset, $0.element) })
        } else if let tokens = json as? [String: String] {
            var parsed: [Int: String] = [:]
            for (key, token) in tokens {
                guard let id = Int(key), id >= 0, parsed.updateValue(token, forKey: id) == nil else {
                    throw AsrModelsError.loadingFailed("Invalid local vocabulary token ID")
                }
            }
            vocabulary = parsed
        } else {
            throw AsrModelsError.loadingFailed("Invalid local vocabulary format")
        }
        guard !vocabulary.isEmpty else { throw AsrModelsError.loadingFailed("Empty local vocabulary") }
        return vocabulary
    }
}

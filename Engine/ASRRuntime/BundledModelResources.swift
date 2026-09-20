import Foundation

/// Read-only model resources for the full installer. These are candidates, never a maintenance root:
/// repair, migration and deletion continue to operate only on Application Support.
public enum BundledModelResources {
    public static func candidates(resources: URL? = Bundle.main.resourceURL) -> [ModelID: URL] {
        guard let resources else { return [:] }
        let root = resources.appendingPathComponent("Models", isDirectory: true)
        return Dictionary(uniqueKeysWithValues: ModelStack.models.map { ($0, ModelCatalog.folder(for: $0, in: root)) })
    }
}

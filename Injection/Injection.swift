import Shared

/// Module entry point. Build the stack with `InjectionModule.makeInjector(...)`.
public enum InjectionModule {
    public static let name = "Injection"
    public static let sharedVersion = SharedModule.version

    /// Live stack: AX + CGEvent + NSPasteboard, outcomes persisted to the app database.
    /// Without Accessibility trust only the paste layer can work; the others skip themselves.
    public static func makeInjector(database: AppDatabase?) -> TextInjector {
        let store: InjectionOutcomeStore = database.map { DatabaseOutcomeStore(database: $0) } ?? InMemoryOutcomeStore()
        return TextInjector(system: LiveSystemAccess(), registry: .standard(), store: store)
    }
}

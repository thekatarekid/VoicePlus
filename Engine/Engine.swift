import FluidAudio
import Shared

/// Placeholder so the `Engine` target compiles before P1.2/P1.3 land.
/// `import FluidAudio` is intentional: it proves the dependency resolves and links.
public enum EngineModule {
    public static let name = "Engine"
    public static let sharedVersion = SharedModule.version
}

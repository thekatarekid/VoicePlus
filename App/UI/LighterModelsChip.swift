import Foundation
import Shared

/// V5 HW3 — the pill chip hookup: `ModelResidency` raises `isRunningLighter` on critical memory
/// pressure (and clears it on `.normal`); the pill shows "Running lighter models — memory is low"
/// in its chip row for as long as that holds.
public enum LighterModelsChip {
    /// The chip's text for a lighter-mode value (nil = hidden).
    public static func note(runningLighter: Bool) -> String? {
        runningLighter ? ModelResidency.lighterModelsMessage : nil
    }

    /// Points `residency`'s lighter-mode observer at `pill` (main queue) and applies the current value.
    public static func wire(_ residency: ModelResidency = .shared, pill: PillViewModel) {
        Task { [weak pill] in
            await residency.setLighterModeObserver { [weak pill] on in
                Task { @MainActor in pill?.memoryNote = note(runningLighter: on) }
            }
            // Already lighter before wiring: show it (a later change arrives through the observer).
            if await residency.isRunningLighter {
                await MainActor.run { pill?.memoryNote = note(runningLighter: true) }
            }
        }
    }
}

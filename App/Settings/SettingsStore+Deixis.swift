import Foundation

/// G1 / G2 — the deixis settings, defaults included, in one place. Keys live here rather than in
/// `SettingsKeys` (owned by another wave-1 task) and are read through the `SettingsStore` protocol.
public enum DeixisSettings {
    /// "In Latch, draw without a key" (V4.28). Default off: in latch a bare drag does nothing;
    /// holding the dictation key while dragging draws the box. Never applies to hold mode.
    public static let drawWithoutKeyKey = "deixis.drawWithoutKey"
    /// Whether the Screen Recording request has been made once (G2: asked the first time a box is
    /// drawn, never again — later boxes without the grant carry AX text only).
    public static let screenRecordingRequestedKey = "deixis.screenRecordingRequested"

    public static func drawsWithoutKey(_ store: SettingsStore?) -> Bool {
        store?.bool(drawWithoutKeyKey) ?? false
    }

    public static func setDrawsWithoutKey(_ on: Bool, store: SettingsStore?) {
        store?.set(on, for: drawWithoutKeyKey)
    }

    public static func screenRecordingRequested(_ store: SettingsStore?) -> Bool {
        store?.bool(screenRecordingRequestedKey) ?? false
    }

    public static func noteScreenRecordingRequested(store: SettingsStore?) {
        store?.set(true, for: screenRecordingRequestedKey)
    }
}

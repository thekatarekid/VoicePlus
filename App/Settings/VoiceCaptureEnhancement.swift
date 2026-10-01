import Engine
import Foundation
import Shared
import SwiftUI

// V5 C1 / C1b — Settings › Voice "Noise and echo reduction": Off (the measured default), Apple's
// voice processing, or LocalVQE. Both enhancements stay selectable whichever wins the V1 gate.
// Choosing one stores `CaptureEnhancement` and the app rebuilds its capture graph
// (`AppContainer.rebuildEngineForCaptureChange`). LocalVQE needs ~50 MB of weights; choosing it
// fetches them (the user's explicit choice is the only trigger) and rebuilds once they land.

/// Whether the LocalVQE weights are on disk, and fetching them. Injectable for tests.
public protocol LocalVQEInstalling: Sendable {
    func isInstalled() async -> Bool
    func install() async throws
}

/// The live installer: the catalog's `.localVQE` entry through a `ModelManager` (maintenance `.skip`,
/// like Settings › Models' reader).
public struct LiveLocalVQEInstaller: LocalVQEInstalling {
    public init() {}
    public func isInstalled() async -> Bool { await LocalVQEStage.locate(manager: ModelManager(maintenance: .skip)) != nil }
    public func install() async throws { try await ModelManager(maintenance: .skip).ensureAvailable(.localVQE) }
}

enum CaptureEnhancementCopy {
    static let title = "Noise and echo reduction"
    static let detail = "Cleans up the microphone before recognition. Off is what measured best on a quiet desk; "
        + "try Apple's in a noisy room or with speakers playing. LocalVQE downloads about 50 MB the first time."
    static let downloading = "Downloading LocalVQE…"
    static let downloadFailed = "LocalVQE couldn’t be downloaded. Capture stays as it was."
    static let appliesNext = "Applies from your next dictation."
}

@MainActor
public final class CaptureEnhancementViewModel: ObservableObject {
    @Published public private(set) var selection: CaptureEnhancement
    @Published public private(set) var note: String?
    @Published public private(set) var installing = false
    private let defaults: UserDefaults
    private let installer: any LocalVQEInstalling

    public init(defaults: UserDefaults = .standard, installer: any LocalVQEInstalling = LiveLocalVQEInstaller()) {
        self.defaults = defaults
        self.installer = installer
        self.selection = CaptureEnhancement.current(defaults: defaults, environment: [:])
    }

    public var options: [CaptureEnhancement] { CaptureEnhancement.allCases }

    /// Stores the choice (which rebuilds the capture graph); LocalVQE without weights fetches them first
    /// and only then switches, so a failed download leaves capture exactly as it was.
    public func select(_ choice: CaptureEnhancement) async {
        guard choice != selection || note == CaptureEnhancementCopy.downloadFailed else { return }
        if choice == .localVQE, !(await installer.isInstalled()) {
            installing = true; note = CaptureEnhancementCopy.downloading
            defer { installing = false }
            do { try await installer.install() } catch {
                Log.app.error("settings: LocalVQE download failed: \(error)")
                note = CaptureEnhancementCopy.downloadFailed
                return
            }
        }
        selection = choice
        CaptureEnhancement.set(choice, defaults: defaults)
        note = CaptureEnhancementCopy.appliesNext
    }
}

struct CaptureEnhancementGroup: View {
    @StateObject private var model = CaptureEnhancementViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            GroupBox(layout: .rows) {
                RowView(CaptureEnhancementCopy.title, detail: CaptureEnhancementCopy.detail) {
                    Picker(CaptureEnhancementCopy.title, selection: Binding(
                        get: { model.selection },
                        set: { choice in Task { await model.select(choice) } }
                    )) {
                        ForEach(model.options, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 300)
                    .disabled(model.installing)
                    .accessibilityLabel(CaptureEnhancementCopy.title)
                    .accessibilityIdentifier("settings.voice.captureEnhancement")
                }
            }
            if let note = model.note {
                Text(note)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
            }
        }
    }
}

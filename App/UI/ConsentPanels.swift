import Actions
import AppKit
import SwiftUI

/// P4.4 UI — the two consent surfaces:
///  · semi-reversible → bottom-right undo toast with a 5 s draining ring;
///  · irreversible    → slide-out confirmation card (click, or spoken "confirm" via the gatekeeper).
///
/// One controller owns both panels. Deterministic-path cards resolve through the `ActRouter`
/// (so its pending token clears); agent-path cards resolve a continuation the
/// `NativeAgentBackend.confirmation` closure is awaiting.
///
/// S12 — every card is an outbound action preview (`ActionPreview`, design §8.8): it names the
/// destination and the proposed action, and it resolves only through `ActionPreviewGate` — an
/// explicit click or the spoken grammar, once. Outbound catalogue actions reach it before they run
/// (`ActionPreviewPolicy.previewingOutbound`), never after.
@MainActor
public final class ConsentPanelsController {
    public var consent: ConsentEngine?
    public var router: ActRouter?
    /// S12 — the destination a card names: the app the action runs in.
    public var destinationName: () -> String? = { NSWorkspace.shared.frontmostApplication?.localizedName }
    private var toastPanel: NSPanel?
    private var cardPanel: NSPanel?
    private var agentContinuation: CheckedContinuation<Bool, Never>?
    /// S12 — the preview on screen and its gate.
    public private(set) var visiblePreview: ActionPreviewGate?
    private var resolveVisible: ((Bool) -> Void)?
    /// Off in tests: a headless test process cannot host an `NSPanel`. The gate works either way.
    var panelsEnabled = true

    public init() {}

    // MARK: Undo toast (semi)

    public func showToast(_ token: UUID, _ toast: UndoToastModel) {
        dismissToast()
        let view = UndoToastView(toast: toast,
                                 onUndo: { [weak self] in
                                     guard let self, let consent = self.consent else { return }
                                     Task { _ = try? await consent.undo(token) }
                                     self.dismissToast()
                                 },
                                 onExpired: { [weak self] in self?.dismissToast() })
        let panel = Self.makePanel(hosting: view, size: NSSize(width: 280, height: 64))
        position(panel, corner: .bottomRight)
        panel.orderFrontRegardless()
        toastPanel = panel
    }

    public func dismissToast() {
        toastPanel?.orderOut(nil)
        toastPanel = nil
    }

    // MARK: Confirmation card (irreversible)

    /// Deterministic path: `ConsentEngine.onCard`. Buttons dispatch through the router so its
    /// pending token clears; spoken "confirm" arrives by the same route via the gatekeeper.
    public func showCard(_ card: ConfirmationCard) {
        presentCard(card) { [weak self] confirmed in
            guard let self else { return }
            if let router = self.router {
                Task { _ = try? await router.dispatch(confirmed ? .confirm : .cancel) }
            }
        }
    }

    /// Agent path: `NativeAgentBackend.confirmation` awaits the click (the backend confirms
    /// the consent token itself afterwards).
    public func requestAgentConfirmation(_ card: ConfirmationCard) async -> Bool {
        await withCheckedContinuation { continuation in
            agentContinuation = continuation
            presentCard(card) { [weak self] confirmed in
                self?.agentContinuation = nil
                continuation.resume(returning: confirmed)
            }
        }
    }

    /// Spoken answers resolve whatever card is showing — through the preview's gate when one is up.
    public func resolveVisibleCard(confirmed: Bool) {
        if visiblePreview != nil {
            handlePreviewEvent(.spoken(confirmed ? "confirm" : "cancel"))
            return
        }
        if let continuation = agentContinuation {
            agentContinuation = nil
            continuation.resume(returning: confirmed)
        }
        dismissCard()
    }

    /// S12 — one event for the preview on screen. It runs (or cancels) only on what the gate says:
    /// an explicit click or the spoken grammar. A dictation landing, time passing or focus moving
    /// leave it waiting — nothing is sent because text was inserted.
    @discardableResult
    public func handlePreviewEvent(_ event: ActionPreviewGate.Event) -> ActionPreviewGate.Decision {
        guard var gate = visiblePreview else { return .keepWaiting }
        let decision = gate.handle(event)
        visiblePreview = gate
        switch decision {
        case .run: resolveVisible?(true)
        case .cancel: resolveVisible?(false)
        case .keepWaiting: break
        }
        return decision
    }

    private func presentCard(_ card: ConfirmationCard, resolve: @escaping (Bool) -> Void) {
        dismissCard()
        let preview = ActionPreview(card: card, destination: destinationName())
        visiblePreview = ActionPreviewGate(preview: preview)
        resolveVisible = { [weak self] confirmed in
            self?.resolveVisible = nil
            resolve(confirmed)
            self?.dismissCard()
        }
        guard panelsEnabled else { return }
        let view = ActionPreviewView(preview: preview,
                                     onConfirm: { [weak self] in self?.handlePreviewEvent(.confirmClicked) },
                                     onCancel: { [weak self] in self?.handlePreviewEvent(.cancelClicked) })
        let panel = Self.makePanel(hosting: view, size: NSSize(width: 360, height: 128))
        position(panel, corner: .topRight)
        panel.orderFrontRegardless()
        cardPanel = panel
    }

    public func dismissCard() {
        cardPanel?.orderOut(nil)
        cardPanel = nil
        visiblePreview = nil
        resolveVisible = nil
    }

    // MARK: Panel plumbing

    private static func makePanel<V: View>(hosting view: V, size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        return panel
    }

    private enum Corner { case bottomRight, topRight }

    private func position(_ panel: NSPanel, corner: Corner) {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let s = panel.frame.size
        let origin: NSPoint
        switch corner {
        case .bottomRight: origin = NSPoint(x: f.maxX - s.width - 24, y: f.minY + 24)
        case .topRight: origin = NSPoint(x: f.maxX - s.width - 24, y: f.maxY - s.height - 24)
        }
        panel.setFrameOrigin(origin)
    }
}

/// 5 s draining ring + undo button, mirroring `UndoToastModel.ring(at:)`.
struct UndoToastView: View {
    let toast: UndoToastModel
    let onUndo: () -> Void
    let onExpired: () -> Void
    @State private var progress: Double = 1.0

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                Circle().trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: SwiftUI.StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 22, height: 22)
            Text(toast.title).font(.callout).lineLimit(2)
            Spacer(minLength: 4)
            Button("Undo", action: onUndo)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("consent.toast.undo")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            withAnimation(.linear(duration: UndoToastModel.duration)) { progress = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + UndoToastModel.duration) { onExpired() }
        }
        .accessibilityIdentifier("consent.toast")
    }
}

/// S12 — the irreversible card is `ActionPreviewView` (ActionPreviewView.swift): it names the
/// destination and the proposed action, and Return is never its default button.


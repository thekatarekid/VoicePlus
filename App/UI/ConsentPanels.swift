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
@MainActor
public final class ConsentPanelsController {
    public var consent: ConsentEngine?
    public var router: ActRouter?
    private var toastPanel: NSPanel?
    private var cardPanel: NSPanel?
    private var agentContinuation: CheckedContinuation<Bool, Never>?

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

    /// Spoken answers resolve whatever card is showing.
    public func resolveVisibleCard(confirmed: Bool) {
        if let continuation = agentContinuation {
            agentContinuation = nil
            continuation.resume(returning: confirmed)
        }
        dismissCard()
    }

    private func presentCard(_ card: ConfirmationCard, resolve: @escaping (Bool) -> Void) {
        dismissCard()
        let view = ConfirmationCardView(card: card) { [weak self] confirmed in
            resolve(confirmed)
            self?.dismissCard()
        }
        let panel = Self.makePanel(hosting: view, size: NSSize(width: 340, height: 120))
        position(panel, corner: .topRight)
        panel.orderFrontRegardless()
        cardPanel = panel
    }

    public func dismissCard() {
        cardPanel?.orderOut(nil)
        cardPanel = nil
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

/// Slide-out card for irreversible actions: title, detail, Confirm / Cancel.
struct ConfirmationCardView: View {
    let card: ConfirmationCard
    let resolve: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(card.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            if !card.detail.isEmpty {
                Text(card.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Text("Say “confirm” or click").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { resolve(false) }
                    .accessibilityIdentifier("consent.card.cancel")
                Button("Confirm") { resolve(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("consent.card.confirm")
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("consent.card")
    }
}

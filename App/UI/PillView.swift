import Combine
import Shared
import SwiftUI

/// Observable bridge between the reducer (pure) and SwiftUI.
public final class PillViewModel: ObservableObject {
    @Published public private(set) var state: PillState = .hidden
    @Published public private(set) var waveform = WaveformModel()
    /// Latched (V3 §4.7): the mic mark gains its badge while the double-tap mode is on.
    @Published public var latched = false
    /// P2.3 — transform ghost ("↩ / try again") + morph preview; nil outside a transform turn.
    @Published public var ghost: TransformGhost?
    @Published public var morph: MorphAnimationModel?
    /// P6.3 — script indicator ("EN" / "हि" / "EN·हि"); empty = hidden.
    @Published public var scriptBadge: String = ""

    public var onGhostAction: ((TransformGhost.Action) -> Void)?
    /// R2.4 — Insert here / Copy / Discard from the held row.
    public var onHeldAction: ((HeldPillInfo, HeldAction) -> Void)?
    /// P5 — the persistent presence indicator listens to the same engine feed the pill reduces,
    /// so the composition root does not have to fan the engine out twice.
    public var onEngineState: ((EngineState) -> Void)?
    private var reducer = PillStateReducer()
    /// S5b — the gate that stops a state being shown and taken away in the same run-loop pass.
    /// Every write to `state` in this class goes through `route(_:)`; nothing sets it directly.
    private var presenter = PillPresenter()
    private var holdTimer: Timer?
    /// R2.4 — retracts a landed/held/failed delivery row after its dwell.
    private var deliveryTimer: Timer?
    /// Injectable clock so `PillPresenterTests` can drive dwell without sleeping.
    public var now: () -> Date = Date.init
    private var cancellables: Set<AnyCancellable> = []
    /// When real captured levels are arriving, `.listening(level:)` must not push a second bar for
    /// the same audio (the waveform would advance at double rate).
    private var lastCapturedLevel: Date?
    private var capturedLevelsAreLive: Bool {
        guard let lastCapturedLevel else { return false }
        return Date().timeIntervalSince(lastCapturedLevel) < 0.5
    }

    public init() {}

    /// Drive from any engine-state publisher plus an optional raw audio-level publisher.
    public func bind(engineState: AnyPublisher<EngineState, Never>, audioLevel: AnyPublisher<Float, Never>? = nil) {
        cancellables.removeAll()
        engineState.receive(on: DispatchQueue.main).sink { [weak self] s in self?.apply(s) }.store(in: &cancellables)
        audioLevel?.receive(on: DispatchQueue.main).sink { [weak self] level in self?.push(capturedLevel: level) }
            .store(in: &cancellables)
    }

    /// A level measured from captured audio. Unlike `EngineState.listening(level:)` these keep
    /// coming while the pill shows a preview, so the waveform no longer freezes mid-utterance.
    public func push(capturedLevel level: Float) {
        lastCapturedLevel = Date()
        waveform.push(level: level)
    }

    public func apply(_ engineState: EngineState) {
        let new = reducer.reduce(engineState)
        if case .listening(let level) = engineState, !capturedLevelsAreLive { waveform.push(level: level) }
        if case .idle = engineState {
            waveform.reset()
            lastCapturedLevel = nil
        }
        route(new)
        onEngineState?(engineState)
    }

    public func hide() {
        reducer.hide()
        ghost = nil
        morph = nil
        route(.hidden)
    }

    /// Show a state the engine reducer does not produce (transform pill). Engine updates resume
    /// overriding it on the next engine event.
    public func present(_ state: PillState) { route(state) }

    /// R2.4 — one `DeliveryOutcome`, one row, then back to ready. The retraction is scheduled here
    /// rather than left to the engine because `.idle` normally arrives *before* the landing result
    /// (the pipeline is async), so nothing else would ever ask the pill to come down again.
    @discardableResult
    public func present(delivery: DeliveryOutcome, text: String, destination: String = "",
                        heldID: UUID = UUID()) -> PillState {
        let next = PillDeliveryRouter.state(for: delivery, text: text, destination: destination, heldID: heldID)
        route(next)
        scheduleDeliveryRetraction(after: PillDwell.minimum(for: next))
        return next
    }

    /// A notice row nothing else will take down, retracted after its own dwell — the same timer the
    /// delivery rows use. Needed because a row raised outside the engine's own state stream (R2.5's
    /// repair suggestions) has no `.idle` behind it to retract it.
    public func presentNotice(_ state: PillState) {
        route(state)
        scheduleDeliveryRetraction(after: PillDwell.minimum(for: state))
    }

    /// Test seam and timer callback: take the delivery row down. No-op for any other state, so a
    /// new utterance that started in the meantime is never yanked off screen.
    public func retractDelivery(immediately: Bool = false) {
        deliveryTimer?.invalidate()
        deliveryTimer = nil
        switch state {
        case .landed, .held, .error:
            reducer.hide()
            ghost = nil
            morph = nil
            if immediately { apply(decision: presenter.dismiss(now: now())) } else { route(.hidden) }
        default: break
        }
    }

    private func scheduleDeliveryRetraction(after dwell: TimeInterval) {
        deliveryTimer?.invalidate()
        let timer = Timer(timeInterval: max(0.05, dwell + 0.05), repeats: false) { [weak self] _ in
            guard let self else { return }
            if Thread.isMainThread { self.retractDelivery() } else { DispatchQueue.main.async { self.retractDelivery() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        deliveryTimer = timer
    }

    /// The single write path to `state`. A visible state lands immediately; a retraction waits out
    /// the current state's `PillDwell` minimum so an error or a "Landing…" can never flash past.
    private func route(_ next: PillState) {
        apply(decision: presenter.request(next, now: now()))
    }

    /// Test seam and timer callback: let a held retraction through once its deadline has passed.
    public func flushPillHold() { apply(decision: presenter.flush(now: now())) }

    private func apply(decision: PillPresenter.Decision) {
        switch decision {
        case .show(let shown):
            holdTimer?.invalidate()
            holdTimer = nil
            state = shown
        case .hold(let until):
            scheduleHold(until: until)
        case .unchanged:
            break
        }
    }

    private func scheduleHold(until: Date) {
        holdTimer?.invalidate()
        let delay = max(0.02, until.timeIntervalSince(now()))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            if Thread.isMainThread { self.flushPillHold() } else { DispatchQueue.main.async { self.flushPillHold() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }
}

/// The pill. Single feedback channel; never a modal.
public struct PillView: View {
    @ObservedObject var model: PillViewModel
    let cornerRadius: CGFloat

    public init(model: PillViewModel, cornerRadius: CGFloat = 18) {
        self.model = model
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        HStack(spacing: 10) {
            icon
            content
            Spacer(minLength: 0)
            if !model.scriptBadge.isEmpty {
                Text(model.scriptBadge)
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.18)))
                    .accessibilityIdentifier("pill.script")
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTransform ? AnyShapeStyle(Color.accentColor.opacity(0.92)) : AnyShapeStyle(.black.opacity(0.92)))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius))
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.12), value: model.state)
        .accessibilityIdentifier("pill.\(model.state.caseName)")
    }

    private var isTransform: Bool { if case .transform = model.state { return true }; return false }

    @ViewBuilder private var icon: some View {
        switch model.state {
        case .transform(let info):
            if case .editing = info.stage { ProgressView().controlSize(.small).tint(.white) }
            else { Image(systemName: "wand.and.stars").foregroundStyle(.white) }
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .unavailable: Image(systemName: "mic.slash.fill").foregroundStyle(.yellow)
        case .error: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .landing: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        // R2.4 — no new mark: verified landing keeps `landing`'s filled green check; an
        // unconfirmed one uses the *unfilled* check in the existing attention yellow, so the two
        // differ in shape as well as colour. Held reuses the warning triangle.
        case .landed(let info):
            if info.verified { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            else { Image(systemName: "checkmark.circle").foregroundStyle(.yellow) }
        case .held: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .idle: Image(systemName: "mic").foregroundStyle(.secondary)
        default: Image(systemName: model.latched ? "mic.badge.plus" : "mic.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .hidden: EmptyView()
        case .idle: Text("Warming up…").font(.callout).foregroundStyle(.secondary)
        case .listening: WaveformView(bars: model.waveform.bars)
        case .preview(let text):
            Text(text).font(.callout).lineLimit(2).truncationMode(.head)
        case .landing: Text("Landing…").font(.callout)
        // R2.4 — the committed text, in `preview`'s row: same font, same two lines, same head
        // truncation. This is what closes the gap between the streaming preview the owner watched
        // and the text that actually landed (V3 §14.1).
        case .landed(let info):
            if let subtitle = info.subtitle { Notice(headline: info.headline, subtitle: subtitle) }
            else { Text(info.text).font(.callout).lineLimit(2).truncationMode(.head) }
        case .held(let info): HeldPillContent(info: info, onAction: model.onHeldAction)
        case .transform(let info): TransformPillContent(info: info, ghost: model.ghost, morph: model.morph, onAction: model.onGhostAction)
        // The panel is widened to fit these exact strings (`NotchGeometry.size(for:on:measure:)`) up
        // to `NotchGeometry.absoluteMaximumSize`; past that the headline wraps to a second line and
        // then tail-truncates. Never `fixedSize(vertical:)` here: it makes the SwiftUI content
        // demand however tall a fully wrapped paragraph is, which is exactly how 1.7.9 turned a long
        // error message into a black slab (`NSHostingView` publishes that as the panel's min size).
        case .unavailable(let reason): Notice(headline: reason, subtitle: PillState.unavailableSubtitle)
        case .error(let message): Notice(headline: message, subtitle: PillState.errorSubtitle)
        case .warning(let q): Notice(headline: PillState.warningHeadline(q), subtitle: PillState.warningSubtitle)
        }
    }
}

/// A two-line notice (error / warning / "no speech model"). Bounded on purpose: at most two lines
/// of headline and one of subtitle, so no message length can grow the pill beyond the size
/// `NotchGeometry` reserved for it.
struct Notice: View {
    let headline: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(headline).font(.callout.weight(.semibold)).lineLimit(2).truncationMode(.tail)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
    }
}

/// R2.4 — the held row: the destination in the headline, the first words of the held text under it,
/// and the three recovery actions in the transform ghost row's existing style and position. No new
/// mark, colour or motion (DESIGN §8.4 (3)).
struct HeldPillContent: View {
    let info: HeldPillInfo
    let onAction: ((HeldPillInfo, HeldAction) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(info.headline).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.tail)
            Text(info.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            HStack(spacing: 10) {
                ForEach(HeldAction.allCases, id: \.rawValue) { action in
                    Button(action.label) { onAction?(info, action) }
                        .accessibilityIdentifier(action.identifier)
                }
            }
            .buttonStyle(.plain).font(.caption).foregroundStyle(.white)
        }
    }
}

/// Bars react to the actual input level; 60fps-friendly (pure shapes, no effects).
public struct WaveformView: View {
    let bars: [Float]
    public init(bars: [Float]) { self.bars = bars }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / CGFloat(max(1, bars.count))
            HStack(alignment: .center, spacing: w * 0.35) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(.white.opacity(0.9))
                        .frame(width: w * 0.65, height: max(3, CGFloat(level) * geo.size.height))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 24)
        .animation(.linear(duration: 0.05), value: bars)
    }
}

/// Transform pill body: headline ("editing N words" / "changed N words" / warm countdown), the
/// morph preview, and the 5 s ghost row with "↩ undo" / "try again".
struct TransformPillContent: View {
    let info: TransformPillInfo
    let ghost: TransformGhost?
    let morph: MorphAnimationModel?
    let onAction: ((TransformGhost.Action) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(info.headline).font(.callout.weight(.semibold)).lineLimit(1)
                if let m = morph, info.showsGhost { MorphPreview(model: m) }
            }
            if let g = ghost, info.showsGhost {
                HStack(spacing: 10) {
                    Button(g.undoLabel) { onAction?(.undo) }.accessibilityIdentifier("pill.ghost.undo")
                    Button(g.tryAgainLabel) { onAction?(.tryAgain) }.accessibilityIdentifier("pill.ghost.tryAgain")
                    Text("“\(g.instruction)”").lineLimit(1).foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.white)
                .transition(.opacity)
            }
        }
    }
}

/// One-beat collapse/expand of the changed words (kept words stay put).
struct MorphPreview: View {
    let model: MorphAnimationModel
    @State private var elapsed: TimeInterval = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(model.tokens.filter { $0.kind != .kept }.prefix(6)) { t in
                Text(t.text).font(.caption)
                    .strikethrough(t.kind == .removed)
                    .opacity(model.scale(of: t, at: elapsed) == 0 && t.kind == .removed ? 0 : 1)
                    .scaleEffect(x: max(0.01, model.scale(of: t, at: elapsed)), anchor: .leading)
            }
        }
        .lineLimit(1)
        .onAppear {
            elapsed = 0
            withAnimation(.easeInOut(duration: model.beat / 2)) { elapsed = model.beat / 2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + model.beat / 2) {
                withAnimation(.easeOut(duration: model.beat / 2)) { elapsed = model.beat }
            }
        }
    }
}

import Combine
import Shared
import SwiftUI

/// Observable bridge between the reducer (pure) and SwiftUI.
public final class PillViewModel: ObservableObject {
    @Published public private(set) var state: PillState = .hidden
    @Published public private(set) var waveform = WaveformModel()
    @Published public var handsFree = false
    /// P2.3 — transform ghost ("↩ / try again") + morph preview; nil outside a transform turn.
    @Published public var ghost: TransformGhost?
    @Published public var morph: MorphAnimationModel?
    public var onGhostAction: ((TransformGhost.Action) -> Void)?
    private var reducer = PillStateReducer()
    private var cancellables: Set<AnyCancellable> = []

    public init() {}

    /// Drive from any engine-state publisher plus an optional raw audio-level publisher.
    public func bind(engineState: AnyPublisher<EngineState, Never>, audioLevel: AnyPublisher<Float, Never>? = nil) {
        cancellables.removeAll()
        engineState.receive(on: DispatchQueue.main).sink { [weak self] s in self?.apply(s) }.store(in: &cancellables)
        audioLevel?.receive(on: DispatchQueue.main).sink { [weak self] level in self?.waveform.push(level: level) }
            .store(in: &cancellables)
    }

    public func apply(_ engineState: EngineState) {
        let new = reducer.reduce(engineState)
        if case .listening(let level) = engineState { waveform.push(level: level) }
        if case .idle = engineState { waveform.reset() }
        state = new
    }

    public func hide() {
        reducer.hide()
        state = .hidden
        ghost = nil
        morph = nil
    }

    /// Show a state the engine reducer does not produce (transform pill). Engine updates resume
    /// overriding it on the next engine event.
    public func present(_ state: PillState) { self.state = state }
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
        case .landing: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .idle: Image(systemName: "mic").foregroundStyle(.secondary)
        default: Image(systemName: model.handsFree ? "mic.badge.plus" : "mic.fill").foregroundStyle(.red)
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
        case .transform(let info): TransformPillContent(info: info, ghost: model.ghost, morph: model.morph, onAction: model.onGhostAction)
        case .warning(let q):
            VStack(alignment: .leading, spacing: 2) {
                Text(q.lowLevel ? "Mic level is very low" : (q.clipping > 0.05 ? "Mic is clipping" : "Noisy mic — \(Int(q.snr)) dB SNR"))
                    .font(.callout.weight(.semibold))
                Text("Check your input device before you speak").font(.caption).foregroundStyle(.secondary)
            }
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

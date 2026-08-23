import UIKit
import Shared
import KeyboardCore

/// The keyboard: one hold-to-talk pill, a persona strip, a numbered repair fan-out, and a
/// "back to previous keyboard" affordance. All decisions come from `KeyboardSession`; this
/// class only performs `KeyboardEffect`s against the text document proxy.
final class KeyboardViewController: UIInputViewController {
    private var session = KeyboardSession(useProxy: true, autoReturn: true)
    private var personas = AppGroupStore.loadPersonas()
    private let asr: any KeyboardASR = ASRSelector.make()
    private var proxy: KeyboardProxyClient?
    private var level: Float = 0

    private let pill = PillView()
    private let fanout = FanoutView()
    private let personaBar = PersonaBar()
    private let switchButton = UIButton(type: .system)
    private let haptics = UIImpactFeedbackGenerator(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        if AppGroupStore.hasAppGroup, let box = try? AppGroupStore.mailbox() {
            proxy = KeyboardProxyClient(mailbox: box, doorbell: DarwinDoorbell())
        } else {
            session.useProxy = false
        }
        session.persona = personas.personaText
        if let live = asr as? SpeechRecognizerASR { live.onLevel = { [weak self] l in DispatchQueue.main.async { self?.level = l; self?.render() } } }
        layout()
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        personas = AppGroupStore.loadPersonas(); session.persona = personas.personaText
        personaBar.set(personas)
        // Return-to-previous-keyboard semantics: the globe is hidden by the system when we are
        // the only extra keyboard, so we always show our own button too.
        switchButton.isHidden = false
    }

    // MARK: layout

    private func layout() {
        let stack = UIStackView(arrangedSubviews: [personaBar, fanout, pill, switchButton])
        stack.axis = .vertical; stack.spacing = 8; stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            pill.heightAnchor.constraint(equalToConstant: 64),
            view.heightAnchor.constraint(equalToConstant: 216),
        ])
        pill.onPress = { [weak self] down in self?.dispatch(down ? .pressDown : .pressUp) }
        fanout.onPick = { [weak self] n in self?.dispatch(.pickAlternate(number: n)) }
        personaBar.onSelect = { [weak self] id in
            guard let self else { return }
            personas.select(id); session.persona = personas.personaText; AppGroupStore.savePersonas(personas)
        }
        switchButton.setTitle("⌨︎ back", for: .normal)
        switchButton.addTarget(self, action: #selector(returnToPrevious), for: .touchUpInside)
        if !needsInputModeSwitchKey { switchButton.setTitle("done", for: .normal) }
    }

    // MARK: session → effects

    private func dispatch(_ event: KeyboardEvent) {
        let effects = session.handle(event)
        for e in effects { perform(e) }
        render()
    }

    private func perform(_ effect: KeyboardEffect) {
        switch effect {
        case .startASR:
            do {
                try asr.start(onPartial: { [weak self] t in DispatchQueue.main.async { self?.dispatch(.partial(t)) } },
                              onFinal: { [weak self] r in DispatchQueue.main.async {
                                  switch r { case .success(let s): self?.dispatch(.final(s)); case .failure(let e): self?.dispatch(.error(e.localizedDescription)) } } })
            } catch { dispatch(.error(Self.describe(error))) }
        case .stopASR: asr.stop()
        case .insertText(let t): textDocumentProxy.insertText(t)
        case .deleteBackward(let n): (0..<n).forEach { _ in textDocumentProxy.deleteBackward() }
        case .sendToProxy(let req):
            guard let proxy else { dispatch(.proxyTimeout); return }
            Task { [weak self] in
                let resp = await proxy.send(req)
                await MainActor.run { self?.dispatch(resp.map { .proxyResponse($0) } ?? .proxyTimeout) }
            }
        case .returnToPreviousKeyboard: returnToPrevious()
        case .haptic(let h): h == .error ? UINotificationFeedbackGenerator().notificationOccurred(.error) : haptics.impactOccurred()
        }
    }

    /// Instant return: `advanceToNextInputMode()` when another keyboard exists, else dismiss.
    /// No focus-dance — the host field keeps its selection and our inserted text.
    @objc private func returnToPrevious() {
        if needsInputModeSwitchKey { advanceToNextInputMode() } else { dismissKeyboard() }
    }

    private func render() {
        let model = KeyboardPillModel(state: session.state, level: level)
        pill.apply(model)
        if case .landed(_, let fan?) = session.state { fanout.set(fan) } else { fanout.set(nil) }
    }

    private static func describe(_ e: Error) -> String {
        switch e as? KeyboardASRError {
        case .notAuthorized: return "Allow Full Access + Speech in Settings"
        case .onDeviceUnsupported: return "On-device speech unsupported"
        case .unavailable: return "Speech unavailable"
        case nil: return e.localizedDescription
        }
    }
}

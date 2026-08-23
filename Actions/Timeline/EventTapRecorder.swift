import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

/// What the app drives: start when the hotkey goes down, stop when it comes up.
public protocol InputRecorder: AnyObject {
    var isRecording: Bool { get }
    func start() throws
    func stop()
}

public enum InputRecorderError: Error, Equatable {
    case inputMonitoringNotGranted
    case tapCreationFailed
}

/// Listen-only `CGEvent` tap feeding the timeline (pointer path, clicks) and the ink capture
/// (drags become strokes while `inkEnabled`). Active only between `start()`/`stop()`; it never
/// modifies or swallows events. Requires Input Monitoring (`CGPreflightListenEventAccess`).
public final class EventTapRecorder: InputRecorder, @unchecked Sendable {
    public let timeline: InputTimeline
    public let ink: InkStrokeCapture
    public var normalizer: DisplayNormalizer
    /// When true, left-button drags are captured as strokes (draw-to-point). Toggled by the app
    /// (e.g. hold ⌥ with the hotkey).
    public var inkEnabled = true
    public private(set) var isRecording = false
    private let clock: TimelineClock
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var leftDown = false
    /// Throttle for pointer moves — 120 Hz is plenty for deixis binding.
    private var lastMove: TimelineInstant = -1
    public var moveInterval: TimeInterval = 1.0 / 120

    public init(timeline: InputTimeline = InputTimeline(), normalizer: DisplayNormalizer,
                clock: TimelineClock = .shared) {
        self.timeline = timeline
        self.normalizer = normalizer
        self.clock = clock
        self.ink = InkStrokeCapture(timeline: timeline)
    }

    public static var hasListenAccess: Bool { CGPreflightListenEventAccess() }

    /// Prompts the system Input Monitoring dialog if needed; returns current state.
    @discardableResult
    public static func requestListenAccess() -> Bool { CGRequestListenEventAccess() }

    public func start() throws {
        guard !isRecording else { return }
        guard Self.hasListenAccess else { throw InputRecorderError.inputMonitoringNotGranted }
        let mask: CGEventMask = [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                 .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                 .otherMouseDown, .otherMouseUp, .otherMouseDragged]
            .reduce(0) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: { _, type, event, refcon in
                                              if let refcon {
                                                  Unmanaged<EventTapRecorder>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
                                              }
                                              return Unmanaged.passUnretained(event)
                                          }, userInfo: selfPtr) else {
            throw InputRecorderError.tapCreationFailed
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRecording = true
        #if canImport(AppKit)
        // Seed the timeline with the current pointer so "this" said before any movement still binds.
        handleMove(quartz: normalizer.quartzPoint(fromCocoa: NSEvent.mouseLocation), force: true)
        #endif
    }

    public func stop() {
        guard isRecording else { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if leftDown { ink.end(time: clock.now()); leftDown = false }
        tap = nil; source = nil
        isRecording = false
    }

    /// Entry point for synthetic events (tests, replay). Mirrors what the tap callback receives.
    public func handle(_ type: CGEventType, _ event: CGEvent) {
        let t = clock.now()
        let q = event.location
        switch type {
        case .mouseMoved:
            handleMove(quartz: q, force: false, at: t)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let p = normalizer.normalize(quartz: q)
            timeline.append(.init(timestamp: t, kind: .click(p, button: Self.button(type), down: true)))
            if type == .leftMouseDown, inkEnabled {
                leftDown = true
                ink.begin(at: p, time: t, pressure: Float(event.getDoubleValueField(.mouseEventPressure)))
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let p = normalizer.normalize(quartz: q)
            timeline.append(.init(timestamp: t, kind: .click(p, button: Self.button(type), down: false)))
            if type == .leftMouseUp, leftDown { leftDown = false; ink.end(time: t) }
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            handleMove(quartz: q, force: false, at: t)
            if type == .leftMouseDragged, leftDown {
                ink.extend(to: normalizer.normalize(quartz: q), time: t,
                           pressure: Float(event.getDoubleValueField(.mouseEventPressure)))
            }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default: break
        }
    }

    /// Selection changes arrive from the AX layer (Injection), not from the event tap.
    public func recordSelection(_ s: SelectionSnapshot) {
        timeline.record(.selectionChange(s), at: clock.now())
    }

    private func handleMove(quartz q: CGPoint, force: Bool, at t: TimelineInstant? = nil) {
        let t = t ?? clock.now()
        guard force || t - lastMove >= moveInterval else { return }
        lastMove = t
        timeline.append(.init(timestamp: t, kind: .pointerMove(normalizer.normalize(quartz: q))))
    }

    private static func button(_ t: CGEventType) -> MouseButton {
        switch t {
        case .leftMouseDown, .leftMouseUp: return .left
        case .rightMouseDown, .rightMouseUp: return .right
        default: return .other
        }
    }
}

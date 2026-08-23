import Foundation
import Shared

/// T4: snapshot the frontmost app at hotkey release; refuse to inject if focus moved; queue instead.
public final class FocusGuard {
    public struct Queued: Equatable, Sendable {
        public var request: InjectionRequest
        public var queuedAt: Date
    }

    private let system: SystemAccess
    public private(set) var queue: [Queued] = []
    /// Called whenever a request is queued instead of typed (App shows a "text is waiting" notice).
    public var onQueued: ((InjectionRequest, FocusSnapshot?) -> Void)?
    /// Compare element identity as well as app. Off by default: many apps re-create their focused
    /// AX element between key-release and readback, which would cause false aborts.
    public var strictElementIdentity = false

    public init(system: SystemAccess) { self.system = system }

    /// Call at hotkey release.
    public func snapshot() -> FocusSnapshot? { system.frontmostApp() }

    /// `true` when the current focus still matches the snapshot.
    public func matches(_ expected: FocusSnapshot?) -> Bool {
        guard let expected else { return true }   // caller opted out of focus safety
        guard let actual = system.frontmostApp() else { return false }
        guard actual.pid == expected.pid, actual.bundleID == expected.bundleID else { return false }
        if strictElementIdentity, let e = expected.elementToken, let a = actual.elementToken, e != a { return false }
        return true
    }

    public func enqueue(_ request: InjectionRequest) {
        queue.append(Queued(request: request, queuedAt: Date()))
        Log.injection.notice("focus changed; queued \(request.text.count) chars for \(request.expectedFocus?.bundleID ?? "?")")
        onQueued?(request, system.frontmostApp())
    }

    /// Requests whose original focus is frontmost again; they are removed from the queue.
    public func dequeueDeliverable() -> [InjectionRequest] {
        let ready = queue.filter { matches($0.request.expectedFocus) }
        queue.removeAll { q in ready.contains { $0 == q } }
        return ready.map(\.request)
    }

    public func discardAll() { queue.removeAll() }
}

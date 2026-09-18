import Foundation
import Testing
@testable import VoicePlusApp

/// A4 / V4.7 — the kept capture graph is fully released on a hard mute and prepared again on
/// unmute. `MuteController` notifies its observers on every model change (processing, directed
/// acknowledgements — several per turn) and replays the current state on `observe`, so the
/// container keys the release on the mute flag's edges only.
@Suite("Hard-mute edges for the kept capture graph (V4.7)")
struct CaptureMuteEdgeTests {

    @Test func onlyChangesOfTheMuteFlagAreEdges() {
        let edge = MuteEdge(muted: false)
        #expect(edge.change(to: false) == nil, "the replay on observe is not an unmute")
        #expect(edge.change(to: true) == true)
        #expect(edge.change(to: true) == nil, "a processing change while muted releases nothing twice")
        #expect(edge.change(to: false) == false)
        #expect(edge.change(to: false) == nil, "a turn's processing flips never re-prepare the graph")
    }

    @Test func aMutedLaunchNeitherReleasesNorPrepares() {
        let edge = MuteEdge(muted: true)
        #expect(edge.change(to: true) == nil)
        #expect(edge.change(to: false) == false, "unmuting prepares the graph again")
    }

    /// Driven through the real controller: one release per mute, one prepare per unmute, whatever
    /// else the model does in between.
    @Test func throughTheMuteController() {
        let mute = MuteController(store: InMemoryMuteStore())
        let edge = MuteEdge(muted: mute.isMuted)
        var calls: [String] = []
        mute.observe { model in
            guard let muted = edge.change(to: model.muted) else { return }
            calls.append(muted ? "release" : "prepare")
        }
        mute.setProcessing(true)
        mute.setProcessing(false)
        mute.mute()
        mute.acknowledgeDirected()
        mute.unmute()
        mute.setProcessing(true)
        #expect(calls == ["release", "prepare"])
    }
}

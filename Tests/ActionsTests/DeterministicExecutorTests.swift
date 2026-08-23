import Testing
import Foundation
@testable import Actions

@Suite struct DeterministicExecutorTests {
    let catalog = try! ActionCatalog.load()
    func layer(front: String = "com.apple.Safari") -> (DeterministicActionLayer, MockActionSystem) {
        let sys = DeterministicMockApps.desktop(catalog: catalog, front: front)
        return (DeterministicActionLayer(catalog: catalog, system: sys), sys)
    }

    @Test func clickByFuzzyName() {
        let (l, sys) = layer()
        #expect(l.perform("click merge")?.outcome == .success(verified: true))
        #expect(sys.log.last == "press Merge pull request")
        #expect(l.perform("click nonexistent control")?.outcome == .failed(.precondition, "no control named nonexistent control"))
    }
    @Test func focusAppWindowTabAndSpace() {
        let (l, sys) = layer()
        #expect(l.perform("switch to slack")?.outcome.isSuccess == true)
        #expect(sys.snapshot().frontmostApp?.name == "Slack")
        #expect(l.perform("focus window second")?.outcome.isSuccess == true)
        #expect(sys.snapshot().focusedWindow?.title == "Second")
        #expect(l.perform("next window")?.outcome.isSuccess == true)
        #expect(sys.snapshot().focusedWindow?.title == "Slack — Main")
        #expect(l.perform("open threads tab")?.outcome == .success(verified: true))
        #expect(l.perform("next tab")?.outcome == .success(verified: true))
        #expect(l.perform("desktop 3")?.outcome == .success(verified: true))
        #expect(sys.activeSpace == 3)
        #expect(l.perform("desktop right")?.outcome == .success(verified: true))
        #expect(l.perform("desktop right")?.outcome == .success(verified: false)) // at edge: delivered, unverifiable
    }
    @Test func fillScrollTypeShortcut() {
        let (l, sys) = layer(front: "com.apple.mail")
        #expect(l.perform("subject quarterly numbers")?.outcome == .success(verified: true))
        #expect(sys.log.last == "set Subject=quarterly numbers")
        #expect(l.perform("scroll to bottom")?.outcome == .success(verified: true))
        #expect(l.perform("scroll down")?.outcome == .success(verified: true)) // already at bound
        #expect(l.perform("type hello there")?.outcome == .success(verified: true))
        #expect(sys.snapshot().focusedElement?.value.hasSuffix("hello there") == true)
        #expect(l.perform("reply all")?.outcome == .success(verified: false))
        #expect(sys.log.last == "key cmd+shift+r")
    }
    @Test func windowOpsReadBack() {
        let (l, sys) = layer()
        #expect(l.perform("minimize window")?.outcome == .success(verified: true))
        #expect(l.perform("close window")?.outcome == .success(verified: true))
        #expect(sys.windows(of: sys.snapshot().frontmostApp!).count == 1)
    }
    @Test func failuresAreClassifiedByPhase() {
        let (l, sys) = layer()
        sys.failNext = .failed("ax timeout")
        #expect(l.perform("click cancel")?.outcome == .failed(.execute, "failed(\"ax timeout\")"))
        sys.isAvailable = false
        #expect(l.perform("copy")?.outcome == .failed(.precondition, "action system unavailable"))
        #expect(l.perform("gibberish nothing") == nil)
    }
    @Test func reversibilityFlowsToRequest() {
        let (l, _) = layer(front: "com.apple.finder")
        #expect(l.resolve("empty trash")?.1.reversibility == .irreversible)
        #expect(l.resolve("copy")?.1.reversibility == .reversible)
    }
}

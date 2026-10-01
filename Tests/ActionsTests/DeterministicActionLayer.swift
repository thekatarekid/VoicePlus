import Foundation
@testable import Actions

/// Test-only front door (V5 X19 removed the unreferenced production type): phrase → catalogue →
/// executor, so the executor/catalogue suites keep driving `ActionExecutor` the way they always did.
final class DeterministicActionLayer {
    let catalog: ActionCatalog
    let executor: ActionExecutor
    init(catalog: ActionCatalog, system: ActionSystem) { self.catalog = catalog; executor = ActionExecutor(system: system) }

    func resolve(_ phrase: String, appKind: ActionCategory? = nil) -> (CatalogMatch, ActionRequest)? {
        guard let m = catalog.match(phrase, appKind: appKind) else { return nil }
        return (m, ActionRequest(m.entry, argument: m.argument))
    }

    func perform(_ phrase: String, appKind: ActionCategory? = nil) -> ActionResult? {
        guard let (_, req) = resolve(phrase, appKind: appKind) else { return nil }
        return executor.run(req)
    }
}

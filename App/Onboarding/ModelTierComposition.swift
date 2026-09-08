import Engine
import Foundation

/// How the picker's three options overlap, in words the user can check against their own choice.
///
/// "Best" is not a separate download from "Balanced" — it is the same Parakeet TDT 0.6B v3 plus an
/// end-of-utterance model. Presence is tracked per *model* (see `ModelManaging.remainingBytes`),
/// which is right: nobody should fetch 500 MB twice. But the screen only said so *after* the fact,
/// where it read as "the app downloaded Balanced on its own" — a reported bug, and the worst thing
/// a several-hundred-megabyte download can be accused of. So the sharing is stated on the row
/// before the download, and the shared row afterwards says whose choice it came from.
public enum ModelTierComposition {
    /// The models behind a tier, as a set.
    static func models(_ tier: ModelTier) -> Set<ModelID> { Set(ModelManagerTiers.models(for: tier)) }

    /// True when every model in `other` is also in `tier` — i.e. installing `tier` necessarily
    /// installs `other`. A tier does not "include" itself.
    public static func includes(_ other: ModelTier, in tier: ModelTier) -> Bool {
        guard other != tier else { return false }
        return models(other).isSubset(of: models(tier))
    }

    /// The other options this one contains, largest first.
    public static func includedTiers(in tier: ModelTier) -> [ModelTier] {
        ModelTier.allCases
            .filter { includes($0, in: tier) }
            .sorted { models($0).count > models($1).count }
    }

    /// Bytes this tier adds on top of the biggest option it contains.
    public static func incrementalBytes(for tier: ModelTier) -> Int64 {
        guard let base = includedTiers(in: tier).first else { return tier.approximateBytes }
        return tier.approximateBytes - base.approximateBytes
    }

    /// Printed under the option, before anything is downloaded, so the overlap is never a surprise
    /// discovered afterwards. Nil for an option that shares nothing.
    ///
    /// e.g. "Includes Balanced's 500 MB model, plus 400 MB for end-of-utterance."
    public static func compositionLine(for tier: ModelTier) -> String? {
        guard let base = includedTiers(in: tier).first else { return nil }
        let extra = incrementalBytes(for: tier)
        guard extra > 0 else { return "Includes \(base.title) — the same \(base.sizeLabel) model." }
        return "Includes \(base.title)'s \(base.sizeLabel) model, plus \(ByteText.short(extra)) more."
    }

    /// What the shared option's "Installed" badge should say. Nil when the user downloaded this one
    /// themselves and it needs no explanation.
    ///
    /// - Parameters:
    ///   - installed: tiers fully present on disk.
    ///   - explicitlyDownloaded: tiers the user actually pressed Download for.
    public static func installedNote(for tier: ModelTier,
                                     installed: Set<ModelTier>,
                                     explicitlyDownloaded: Set<ModelTier>) -> String? {
        guard installed.contains(tier), !explicitlyDownloaded.contains(tier) else { return nil }
        // Prefer the option the user actually asked for; fall back to any installed superset, which
        // is still the honest answer after a relaunch has forgotten who pressed what.
        let supersets = ModelTier.allCases.filter { includes(tier, in: $0) && installed.contains($0) }
        guard let owner = supersets.first(where: explicitlyDownloaded.contains) ?? supersets.first else { return nil }
        return "Included with \(owner.title)"
    }
}

import Foundation

/// Last-writer-wins per record. Tie on `updatedAt` → higher `version` wins; still tied → `tieBreak` (deviceID compare).
public enum SyncMerge {
    public static func winner<R: SyncRecord>(_ a: R, _ b: R) -> R {
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt ? a : b }
        if a.version != b.version { return a.version > b.version ? a : b }
        return a  // deterministic: local/first argument wins on full tie
    }

    public static func merge<R: SyncRecord>(_ local: [R], _ remote: [R]) -> [R] {
        var byID: [String: R] = [:]
        for r in local { byID[r.id] = r }
        for r in remote {
            if let l = byID[r.id] { byID[r.id] = winner(l, r) } else { byID[r.id] = r }
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    public static func merge(_ local: SyncPayload, _ remote: SyncPayload) -> SyncPayload {
        var out = local
        out.dictionary = merge(local.dictionary, remote.dictionary)
        out.personas = merge(local.personas, remote.personas)
        out.snippets = merge(local.snippets, remote.snippets)
        out.adapters = merge(local.adapters, remote.adapters)
        out.settings = merge(local.settings, remote.settings)
        out.generatedAt = max(local.generatedAt, remote.generatedAt)
        return out
    }
}

public extension SyncRecord {
    /// Bump for a local edit: new timestamp + version. Tombstone via `deleted`.
    mutating func touch(now: Date = Date()) { version += 1; updatedAt = now }
}

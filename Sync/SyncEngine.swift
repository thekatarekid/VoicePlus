import Foundation

/// Push local payload (encrypted) and pull+merge everyone else's. Envelopes from a different key fail to open
/// (tampered/keyMismatch) and are skipped, reported in `SyncResult.rejected`.
public struct SyncResult: Equatable, Sendable {
    public var merged: SyncPayload
    public var peersApplied: [String]
    public var rejected: [String]
}

public struct SyncEngine: Sendable {
    public let deviceID: String
    public let key: SyncKey
    public let transport: SyncTransport

    public init(deviceID: String, key: SyncKey, transport: SyncTransport) {
        self.deviceID = deviceID; self.key = key; self.transport = transport
    }

    public func push(_ payload: SyncPayload) throws {
        precondition(SyncPayload.audit().isEmpty, "SyncPayload must never carry audio")
        var p = payload; p.deviceID = deviceID
        try transport.publish(envelope: try key.seal(p), for: deviceID)
    }

    public func pull(into local: SyncPayload) throws -> SyncResult {
        var merged = local; var applied: [String] = []; var rejected: [String] = []
        for (peer, blob) in try transport.fetchAll().sorted(by: { $0.key < $1.key }) where peer != deviceID {
            if let remote = try? key.openPayload(blob) { merged = SyncMerge.merge(merged, remote); applied.append(peer) }
            else { rejected.append(peer) }
        }
        return SyncResult(merged: merged, peersApplied: applied, rejected: rejected)
    }

    /// Full cycle: pull, merge, push the merged result.
    @discardableResult
    public func sync(_ local: SyncPayload) throws -> SyncResult {
        let r = try pull(into: local)
        try push(r.merged)
        return r
    }
}

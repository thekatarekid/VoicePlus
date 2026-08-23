import Foundation
import Testing
@testable import Sync

private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }
private func samplePayload(_ id: String = "mac") -> SyncPayload {
    SyncPayload(deviceID: id, generatedAt: t(100),
                dictionary: [DictionaryEntry(id: "d1", word: "Kothari", updatedAt: t(10))],
                personas: [Persona(id: "p1", name: "Terse", styleRules: ["no filler"], updatedAt: t(10))],
                snippets: [Snippet(id: "s1", trigger: "addr", expansion: "12 Main St", updatedAt: t(10))],
                adapters: [AdapterWeights(id: "parakeet-v3", blob: Data(repeating: 7, count: 64), updatedAt: t(10))],
                settings: [SettingRecord(id: "theme", value: "\"dark\"", updatedAt: t(10))])
}

@Suite struct CryptoTests {
    @Test func encryptDecryptRoundTrip() throws {
        let key = SyncKey.random()
        let p = samplePayload()
        let env = try key.seal(p)
        #expect(try key.openPayload(env) == p)
        #expect(env.prefix(4) == Data("VPS1".utf8))
    }

    @Test func tamperDetected() throws {
        let key = SyncKey.random()
        var env = try key.seal(samplePayload())
        env[env.count - 5] ^= 0x01
        #expect(throws: SyncCryptoError.tampered) { try key.openPayload(env) }
        let flippedBody = { () -> Data in var e = env; e[20] ^= 0xFF; return e }()
        #expect(throws: SyncCryptoError.tampered) { try key.openPayload(flippedBody) }
        #expect(throws: SyncCryptoError.badFormat) { try key.open(Data("junk".utf8)) }
    }

    @Test func wrongKeyAndWrongAADFail() throws {
        let env = try SyncKey.random().seal(Data("hi".utf8), aad: Data("a".utf8))
        #expect(throws: SyncCryptoError.tampered) { try SyncKey.random().open(env, aad: Data("a".utf8)) }
    }

    @Test func hkdfIsDeterministic() {
        let a = SyncKey.derive(fromPairingSecret: Data("secret".utf8), salt: Data("salt".utf8))
        let b = SyncKey.derive(fromPairingSecret: Data("secret".utf8), salt: Data("salt".utf8))
        let c = SyncKey.derive(fromPairingSecret: Data("secret".utf8), salt: Data("other".utf8))
        #expect(a == b); #expect(a != c); #expect(a.fingerprint.count == 8)
    }

    @Test func keyStoreRoundTripNeverPlaintextPayload() throws {
        let store = InMemorySyncKeyStore()
        #expect(try SyncKey.load(from: store) == nil)
        let k = SyncKey.random(); try k.save(to: store)
        #expect(try SyncKey.load(from: store) == k)
        #expect(try store.get(SyncKey.storeKey)?.count == 32)
        try store.delete(SyncKey.storeKey)
        #expect(try SyncKey.load(from: store) == nil)
    }
}

@Suite struct MergeTests {
    typealias S = Snippet
    let base = S(id: "x", trigger: "a", expansion: "A", version: 1, updatedAt: t(10))

    @Test func lwwMatrix() {
        var newer = base; newer.expansion = "N"; newer.updatedAt = t(20)
        var older = base; older.expansion = "O"; older.updatedAt = t(5); older.version = 9
        var sameTimeHigherVersion = base; sameTimeHigherVersion.expansion = "V"; sameTimeHigherVersion.version = 2
        var fullTie = base; fullTie.expansion = "T"
        // newer timestamp wins regardless of version
        #expect(SyncMerge.winner(base, newer).expansion == "N")
        #expect(SyncMerge.winner(newer, base).expansion == "N")
        #expect(SyncMerge.winner(base, older).expansion == "A")
        #expect(SyncMerge.winner(older, base).expansion == "A")
        // tie on time → version
        #expect(SyncMerge.winner(base, sameTimeHigherVersion).expansion == "V")
        #expect(SyncMerge.winner(sameTimeHigherVersion, base).expansion == "V")
        // full tie → local
        #expect(SyncMerge.winner(base, fullTie).expansion == "A")
        #expect(SyncMerge.winner(fullTie, base).expansion == "T")
    }

    @Test func mergeListsUnionAndTombstones() {
        var del = base; del.deleted = true; del.updatedAt = t(30)
        let only = S(id: "y", trigger: "b", expansion: "B")
        let m = SyncMerge.merge([base], [del, only])
        #expect(m.count == 2)
        #expect(m.first { $0.id == "x" }?.deleted == true)
        #expect(m.contains { $0.id == "y" })
    }

    @Test func mergePayloadPerCollection() {
        let local = samplePayload("mac")
        var remote = samplePayload("phone")
        remote.dictionary[0].word = "Kothari (fixed)"; remote.dictionary[0].touch(now: t(50))
        remote.settings[0].value = "\"light\""; remote.settings[0].updatedAt = t(1)
        let m = SyncMerge.merge(local, remote)
        #expect(m.dictionary[0].word == "Kothari (fixed)")
        #expect(m.settings[0].value == "\"dark\"")
        #expect(m.deviceID == "mac")
    }
}

@Suite struct PairingTests {
    @Test func payloadQRStringRoundTrip() throws {
        let s = PairingSession(deviceID: "mac-1", deviceName: "Aditya's Mac", shortCode: "123456")
        let parsed = try PairingPayload.parse(s.payload.qrString)
        #expect(parsed == s.payload)
        #expect(throws: PairingPayload.ParseError.badScheme) { try PairingPayload.parse("https://x") }
    }

    @Test func handshakeBetweenTwoDevicesDerivesSameKey() throws {
        let mac = PairingSession(deviceID: "mac", deviceName: "Mac")
        let phone = PairingSession(deviceID: "phone", deviceName: "iPhone")
        // Each scans the other's QR.
        let kMac = try mac.complete(with: try PairingPayload.parse(phone.payload.qrString), confirmedPeerCode: phone.shortCode)
        let kPhone = try phone.complete(with: try PairingPayload.parse(mac.payload.qrString), confirmedPeerCode: mac.shortCode)
        #expect(kMac == kPhone)
        // And the key actually works end to end.
        let env = try kMac.seal(samplePayload("mac"))
        #expect(try kPhone.openPayload(env).dictionary[0].word == "Kothari")
        // Third device with the wrong secret cannot read it.
        let evil = PairingSession(deviceID: "evil", deviceName: "E")
        let kEvil = try evil.complete(with: mac.payload)
        #expect(throws: SyncCryptoError.tampered) { try kEvil.openPayload(env) }
    }

    @Test func handshakeRejectsBadInputs() throws {
        let a = PairingSession(deviceID: "a", deviceName: "A")
        #expect(throws: PairingError.selfPairing) { try a.complete(with: a.payload) }
        #expect(throws: PairingError.codeMismatch) {
            try a.complete(with: PairingSession(deviceID: "b", deviceName: "B", shortCode: "000001").payload, confirmedPeerCode: "999999")
        }
        var bad = PairingSession(deviceID: "b", deviceName: "B").payload; bad.publicKey = Data(repeating: 0, count: 31)
        #expect(throws: PairingError.badPeerKey) { try a.complete(with: bad) }
    }

    #if canImport(CoreImage)
    @Test func qrRenders() {
        let p = PairingSession(deviceID: "mac", deviceName: "Mac").payload
        if let img = QRCode.image(for: p, scale: 4) { #expect(img.width > 100); #expect(img.width == img.height) }
        else { Issue.record("CIQRCodeGenerator unavailable on this host (headless) — QR rendering unverified") }
    }
    #endif
}

@Suite struct TransportAndEngineTests {
    @Test func twoDevicesSyncThroughSharedFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vpsync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = try DirectorySyncTransport(directory: dir)
        let key = SyncKey.random()
        let mac = SyncEngine(deviceID: "mac", key: key, transport: transport)
        let phone = SyncEngine(deviceID: "phone", key: key, transport: transport)

        var macLocal = samplePayload("mac")
        try mac.push(macLocal)
        var phoneLocal = SyncPayload(deviceID: "phone", snippets: [Snippet(id: "s2", trigger: "sig", expansion: "— A", updatedAt: t(40))])
        let r1 = try phone.sync(phoneLocal)
        #expect(r1.peersApplied == ["mac"]); #expect(r1.rejected.isEmpty)
        #expect(r1.merged.dictionary.count == 1); #expect(r1.merged.snippets.count == 2)
        phoneLocal = r1.merged

        macLocal.personas[0].name = "Blunt"; macLocal.personas[0].touch(now: t(60))
        let r2 = try mac.sync(macLocal)
        #expect(r2.merged.snippets.count == 2); #expect(r2.merged.personas[0].name == "Blunt")
        // Files on disk are ciphertext only.
        for (_, blob) in try transport.fetchAll() { #expect(!String(decoding: blob, as: UTF8.self).contains("Kothari")) }
    }

    @Test func foreignKeyEnvelopesAreRejectedNotCrashing() throws {
        let transport = InMemorySyncTransport()
        let stranger = SyncEngine(deviceID: "stranger", key: .random(), transport: transport)
        try stranger.push(samplePayload("stranger"))
        let me = SyncEngine(deviceID: "me", key: .random(), transport: transport)
        let r = try me.pull(into: SyncPayload(deviceID: "me"))
        #expect(r.rejected == ["stranger"]); #expect(r.merged.dictionary.isEmpty)
        try transport.remove(deviceID: "stranger")
        #expect(try transport.fetchAll().isEmpty)
    }
}

@Suite struct ExportAndAuditTests {
    @Test func exportImportRoundTrip() throws {
        let p = samplePayload()
        let file = try ExportBundle.export(p, passphrase: "correct horse")
        #expect(file.prefix(5) == Data("VPEX1".utf8))
        #expect(try ExportBundle.import(file, passphrase: "correct horse") == p)
        #expect(throws: SyncCryptoError.tampered) { try ExportBundle.import(file, passphrase: "wrong") }
        #expect(throws: SyncCryptoError.badFormat) { try ExportBundle.import(Data("nope".utf8), passphrase: "x") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ExportBundle.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try ExportBundle.export(p, passphrase: "pw", to: url)
        #expect(try ExportBundle.import(from: url, passphrase: "pw") == p)
    }

    @Test func payloadNeverIncludesAudio() {
        #expect(SyncPayload.audit() == [])
        // The audit itself catches audio-shaped fields.
        struct Leak: Codable { var audioSamples: [Float] }
        struct Wrapper { var leak = Leak(audioSamples: [0]) }
        var hits: [String] = []
        for child in Mirror(reflecting: Wrapper()).children {
            for c in Mirror(reflecting: child.value).children where SyncPayload.forbiddenFieldNames.contains(where: { c.label!.lowercased().contains($0) }) {
                hits.append(c.label!)
            }
        }
        #expect(hits == ["audioSamples"])
    }

    @Test func codableStable() throws {
        let p = samplePayload()
        let d = try p.encoded()
        #expect(try SyncPayload.decode(d) == p)
        #expect(String(decoding: d, as: UTF8.self).contains("\"schemaVersion\":1"))
    }
}

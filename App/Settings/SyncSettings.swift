import AppKit
import Foundation
import Shared
import Sync
import SwiftUI

// S7g — Settings › Sync (design §8.6): pairing comparison, connected devices, paused / offline, and
// conflict review, over the P6.4 `SyncService` (QR pairing with short-code confirmation, a folder
// transport, the passphrase-encrypted export). Every failure is a catalogue entry — X05 for pairing
// and invalid payloads ("Nothing from this transfer was applied."), X06 for an unreachable folder or
// edits that need review — never the error's own text. Offline never blocks local dictation.

/// A device this Mac has paired with, remembered so the page can list it.
public struct SyncDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var pairedAt: Date
    public var lastSynced: Date?

    public init(id: String, name: String, pairedAt: Date, lastSynced: Date? = nil) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
        self.lastSynced = lastSynced
    }
}

public enum SyncSettings {
    public static func devices(_ store: SettingsStore?) -> [SyncDevice] {
        guard let raw = store?.string(SettingsKeys.syncDevices), let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder.iso.decode([SyncDevice].self, from: data)) ?? []
    }

    public static func setDevices(_ devices: [SyncDevice], store: SettingsStore?) {
        guard let data = try? JSONEncoder.iso.encode(devices) else { return }
        store?.set(String(decoding: data, as: UTF8.self), for: SettingsKeys.syncDevices)
    }

    public static func isPaused(_ store: SettingsStore?) -> Bool { store?.bool(SettingsKeys.syncPaused) ?? false }
    public static func setPaused(_ on: Bool, store: SettingsStore?) { store?.set(on, for: SettingsKeys.syncPaused) }

    public static func lastRound(_ store: SettingsStore?) -> Date? {
        store?.string(SettingsKeys.syncLastRound).flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    public static func setLastRound(_ date: Date, store: SettingsStore?) {
        store?.set(ISO8601DateFormatter().string(from: date), for: SettingsKeys.syncLastRound)
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}

/// Where sync stands — the page's status row.
public enum SyncStatus: Equatable, Sendable {
    /// Not paired and no folder: the empty state, "Sync is off".
    case off
    /// Paired or configured, waiting for "Sync now".
    case idle(lastRound: Date?)
    case paused
    /// The folder is set but cannot be reached (unmounted, deleted, iCloud offline).
    case offline
    case syncing

    public var line: String {
        switch self {
        case .off: return SyncCopy.off
        case .idle(let date): return date.map(SyncCopy.lastSynced) ?? SyncCopy.notSyncedYet
        case .paused: return SyncCopy.paused
        case .offline: return SyncCopy.offline
        case .syncing: return SyncCopy.syncing
        }
    }
}

/// One edit another device's newer version replaced on this Mac (last writer wins), shown for
/// review with a way to put this Mac's version back.
public struct SyncConflict: Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var mine: String
    public var theirs: String

    /// Dictionary entries whose spelling or spoken form changed between this Mac's payload before the
    /// round and the merged result. Snippets are never overwritten by `SyncService.apply`.
    public static func between(before: SyncPayload, merged: SyncPayload) -> [SyncConflict] {
        let old = Dictionary(before.dictionary.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return merged.dictionary.compactMap { new in
            guard let prior = old[new.id], !new.deleted,
                  prior.word != new.word || prior.pronunciationHint != new.pronunciationHint else { return nil }
            return SyncConflict(id: new.id, kind: SyncCopy.dictionaryWord,
                                mine: describe(prior.word, prior.pronunciationHint),
                                theirs: describe(new.word, new.pronunciationHint))
        }
        .sorted { $0.mine < $1.mine }
    }

    static func describe(_ word: String, _ hint: String?) -> String {
        guard let hint, !hint.isEmpty else { return word }
        return "\(word) (“\(hint)”)"
    }
}

/// What the pairing comparison shows: both codes, and whether they match (design §8.6 "pairing
/// comparison"; the prototype's "Compare pairing codes before connecting").
public struct PairingComparison: Equatable, Sendable {
    public var thisCode: String
    public var peerName: String?
    public var peerCode: String?
    public var typedCode: String

    public enum Match: Equatable, Sendable { case waiting, matches, differs }

    public var match: Match {
        let typed = typedCode.filter(\.isNumber)
        guard let peerCode, !typed.isEmpty else { return .waiting }
        return typed == peerCode ? .matches : .differs
    }

    public static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}

@MainActor
public final class SyncSettingsViewModel: ObservableObject {
    private let service: SyncService?
    private let store: SettingsStore?
    private let folderReachable: (URL) -> Bool
    private let now: () -> Date

    @Published public private(set) var fingerprint: String?
    @Published public private(set) var qrImage: NSImage?
    @Published public private(set) var shortCode: String?
    @Published public var scannedPeer = "" { didSet { parsePeer() } }
    @Published public var peerCode = ""
    @Published public var passphrase = ""
    @Published public private(set) var folderPath: String?
    /// Plain status after an action ("Paired with …", "Exported …"). Never an error's own text.
    @Published public private(set) var status: String?
    @Published public private(set) var devices: [SyncDevice]
    @Published public private(set) var paused: Bool
    @Published public private(set) var isSyncing = false
    @Published public private(set) var isPairing = false
    @Published public private(set) var conflicts: [SyncConflict] = []
    @Published public private(set) var rejectedPeers: [String] = []
    /// The scoped failure (X05 / X06 / S02), with its one action.
    @Published public private(set) var failure: SectionBanner?
    @Published public private(set) var lastRound: Date?
    /// The peer's payload as parsed from what was pasted, for the comparison.
    @Published public private(set) var peer: PairingPayload?

    public init(service: SyncService?, store: SettingsStore? = nil,
                folderReachable: @escaping (URL) -> Bool = SyncSettingsViewModel.isReachable,
                now: @escaping () -> Date = Date.init) {
        self.service = service
        self.store = store ?? service?.settings
        self.folderReachable = folderReachable
        self.now = now
        fingerprint = service?.keyFingerprint
        folderPath = service?.folderURL?.path
        devices = SyncSettings.devices(store ?? service?.settings)
        paused = SyncSettings.isPaused(store ?? service?.settings)
        lastRound = SyncSettings.lastRound(store ?? service?.settings)
    }

    public var isAvailable: Bool { service != nil }

    public nonisolated static func isReachable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: url.path)
    }

    public var syncStatus: SyncStatus {
        if isSyncing { return .syncing }
        if devices.isEmpty && folderPath == nil { return .off }
        if paused { return .paused }
        if let folderPath, !folderReachable(URL(fileURLWithPath: folderPath)) { return .offline }
        return .idle(lastRound: lastRound)
    }

    public var canSyncNow: Bool {
        guard folderPath != nil, !paused, !isSyncing else { return false }
        return syncStatus != .offline
    }

    public var comparison: PairingComparison? {
        guard let shortCode else { return nil }
        return PairingComparison(thisCode: shortCode, peerName: peer?.deviceName, peerCode: peer?.shortCode, typedCode: peerCode)
    }

    /// The page's base rendering: "Sync is off" until something is paired or configured.
    public func state(showingSetup: Bool) -> SectionState {
        if !isAvailable { return .empty(SyncCopy.off, detail: SyncCopy.unavailable) }
        if syncStatus == .off && !showingSetup && shortCode == nil {
            return .empty(SyncCopy.off, detail: SyncCopy.offDetail, action: SyncCopy.pairDevice)
        }
        return .content
    }

    /// The banner over readable content: the failure, else offline or conflicts to review (X06).
    public var banner: SectionBanner? {
        if let failure { return failure }
        if syncStatus == .offline || !conflicts.isEmpty {
            return .partial(RecoveryCatalog.entry(.X06))
        }
        return nil
    }

    // MARK: Pairing

    public func startPairing() {
        guard let service else { return }
        failure = nil
        let payload = service.startPairing()
        shortCode = payload.shortCode
        if let png = service.qrPNG(), let image = NSImage(data: png) { qrImage = image }
        isPairing = true
        status = SyncCopy.scanPrompt
    }

    public func cancelPairing() {
        shortCode = nil
        qrImage = nil
        scannedPeer = ""
        peerCode = ""
        isPairing = false
        status = nil
    }

    private func parsePeer() {
        let text = scannedPeer.trimmingCharacters(in: .whitespacesAndNewlines)
        peer = text.isEmpty ? nil : try? PairingPayload.parse(text)
    }

    public func completePairing() {
        guard let service, !scannedPeer.isEmpty else { return }
        let parsed = peer
        do {
            let key = try service.completePairing(scanned: scannedPeer.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  confirmedPeerCode: peerCode.isEmpty ? nil : peerCode.filter(\.isNumber))
            fingerprint = key.fingerprint
            if let parsed { remember(SyncDevice(id: parsed.deviceID, name: parsed.deviceName, pairedAt: now())) }
            cancelPairing()
            failure = nil
            status = SyncCopy.paired(parsed?.deviceName, fingerprint: key.fingerprint)
        } catch {
            failure = .recovery(RecoveryCatalog.report(error))
        }
    }

    private func remember(_ device: SyncDevice) {
        devices.removeAll { $0.id == device.id }
        devices.append(device)
        SyncSettings.setDevices(devices, store: store)
    }

    // MARK: Transport

    public func chooseFolder() {
        guard let service else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = SyncCopy.useForSync
        guard panel.runModal() == .OK, let url = panel.url else { return }
        service.folderURL = url
        folderPath = url.path
    }

    public func setPaused(_ on: Bool) {
        paused = on
        SyncSettings.setPaused(on, store: store)
    }

    /// One round: push ours, pull and merge peers. Invalid payloads are rejected (X05) and listed;
    /// dictionary edits another device replaced are kept for review.
    public func syncNow() {
        guard let service, canSyncNow else { return }
        isSyncing = true
        failure = nil
        defer { isSyncing = false }
        let before = service.payload(now: now())
        do {
            let result = try service.syncNow()
            fingerprint = service.keyFingerprint
            let at = now()
            lastRound = at
            SyncSettings.setLastRound(at, store: store)
            conflicts = SyncConflict.between(before: before, merged: result.merged)
            rejectedPeers = result.rejected
            noteSeen(result.peersApplied, at: at)
            status = SyncCopy.synced(result.peersApplied.count)
            if !result.rejected.isEmpty { failure = .recovery(RecoveryCatalog.entry(.X05)) }
        } catch {
            failure = .recovery(RecoveryCatalog.report(error))
        }
    }

    private func noteSeen(_ peers: [String], at date: Date) {
        guard !peers.isEmpty else { return }
        for peerID in peers {
            if let i = devices.firstIndex(where: { $0.id == peerID }) {
                devices[i].lastSynced = date
            } else {
                // A device that shares the key but was paired elsewhere: list it rather than hide it.
                devices.append(SyncDevice(id: peerID, name: SyncCopy.otherDevice(peerID), pairedAt: date, lastSynced: date))
            }
        }
        SyncSettings.setDevices(devices, store: store)
    }

    /// Conflict review: put this Mac's version back. It becomes the newest edit, so the next round
    /// carries it to the other devices.
    public func keepMine(_ conflict: SyncConflict, database: AppDatabase?) {
        guard let database, let record = try? database.dictionaryTerms().first(where: { $0.id == conflict.id }) else { return }
        let (word, hint) = Self.split(conflict.mine)
        do {
            try database.save(DictionaryRecord(id: record.id, term: word, spokenForms: hint ?? "",
                                                weight: record.weight, createdAt: now()))
            conflicts.removeAll { $0.id == conflict.id }
        } catch {
            _ = RecoveryCatalog.report(error)
            failure = .recovery(RecoveryCatalog.entry(.S02))
        }
    }

    /// Keep the other device's version: nothing to change, the review item goes away.
    public func keepTheirs(_ conflict: SyncConflict) { conflicts.removeAll { $0.id == conflict.id } }

    static func split(_ described: String) -> (String, String?) {
        guard let open = described.range(of: " (“"), described.hasSuffix("”)") else { return (described, nil) }
        let word = String(described[..<open.lowerBound])
        let hint = String(described[open.upperBound..<described.index(described.endIndex, offsetBy: -2)])
        return (word, hint)
    }

    /// The banner's one action.
    public func bannerAction() {
        guard let id = banner?.recoveryID else { return }
        switch id {
        case .X05: startPairing()
        case .X06: if syncStatus == .offline { chooseFolder() } else { failure = nil }
        default: failure = nil
        }
    }

    // MARK: Everything file

    public func exportEverything() {
        guard let service, !passphrase.isEmpty else { status = SyncCopy.passphraseFirst; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "VoicePlus.voiceplus"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try service.exportEverything(to: url, passphrase: passphrase)
            status = SyncCopy.exported(url.lastPathComponent)
        } catch {
            failure = .recovery(RecoveryCatalog.report(error))
        }
    }

    public func importEverything() {
        guard let service, !passphrase.isEmpty else { status = SyncCopy.importPassphraseFirst; return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try service.importEverything(from: url, passphrase: passphrase)
            status = SyncCopy.imported(url.lastPathComponent)
        } catch {
            // A wrong passphrase or a tampered file: nothing was applied (X05).
            failure = .recovery(RecoveryCatalog.report(error))
        }
    }
}

// MARK: - The page

struct SyncSettingsTab: View {
    @ObservedObject var model: SyncSettingsViewModel
    var database: AppDatabase?

    var body: some View {
        VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
            GroupBox(SyncCopy.statusTitle, layout: .rows) {
                RowView(SyncCopy.thisDevice, detail: model.fingerprint.map(SyncCopy.key) ?? SyncCopy.noKey) {
                    StatusTag(model.syncStatus == .offline ? SyncCopy.offlineTag : SyncCopy.local,
                              kind: model.syncStatus == .offline ? .warn : .neutral)
                }
                RowView(SyncCopy.statusRow, detail: model.syncStatus.line) {
                    HStack(spacing: Tokens.Spacing.s) {
                        Toggle(SyncCopy.pause, isOn: Binding(get: { model.paused }, set: { model.setPaused($0) }))
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("settings.sync.pause")
                        Button(SyncCopy.syncNow) { model.syncNow() }
                            .disabled(!model.canSyncNow)
                            .accessibilityIdentifier("settings.sync.now")
                    }
                }
                RowView(SyncCopy.folderTitle, detail: model.folderPath ?? SyncCopy.folderNotSet) {
                    Button(SyncCopy.chooseFolder) { model.chooseFolder() }
                        .accessibilityIdentifier("settings.sync.folder")
                }
            }
            devices
            pairing
            if !model.conflicts.isEmpty { conflicts }
            GroupBox(SyncCopy.everythingTitle, layout: .rows) {
                RowView(SyncCopy.passphraseTitle, detail: SyncCopy.passphraseDetail) {
                    SecureField(SyncCopy.passphraseTitle, text: $model.passphrase)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .accessibilityIdentifier("settings.sync.passphrase")
                }
                RowView(SyncCopy.exportTitle) {
                    HStack(spacing: Tokens.Spacing.s) {
                        Button(SyncCopy.export) { model.exportEverything() }
                        Button(SyncCopy.importFile) { model.importEverything() }
                    }
                }
            }
            if let status = model.status {
                Text(status)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
                    .accessibilityIdentifier("settings.sync.status")
            }
            Text(SyncCopy.footnote)
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
        }
    }

    private var devices: some View {
        GroupBox(SyncCopy.devicesTitle, layout: .rows) {
            if model.devices.isEmpty {
                RowView(SyncCopy.noDevices, detail: SyncCopy.compareCodes)
            }
            ForEach(model.devices) { device in
                RowView(device.name, detail: device.lastSynced.map(SyncCopy.lastSynced) ?? SyncCopy.pairedNotSynced) {
                    StatusTag(model.syncStatus == .paused ? SyncCopy.pausedTag : SyncCopy.pairedTag,
                              kind: model.syncStatus == .paused ? .neutral : .good)
                }
            }
        }
        .accessibilityIdentifier("settings.sync.devices")
    }

    @ViewBuilder private var pairing: some View {
        GroupBox(SyncCopy.pairTitle, layout: .padded) {
            if let comparison = model.comparison {
                VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                    HStack(alignment: .top, spacing: Tokens.Spacing.l) {
                        if let qr = model.qrImage {
                            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 120, height: 120)
                                .accessibilityLabel(SyncCopy.qrLabel)
                        }
                        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                            codeLine(SyncCopy.thisMac, PairingComparison.grouped(comparison.thisCode))
                            codeLine(comparison.peerName ?? SyncCopy.otherDeviceTitle,
                                     comparison.peerCode.map(PairingComparison.grouped) ?? SyncCopy.waitingForPeer)
                            Text(SyncCopy.compareCodes)
                                .windowFont(Tokens.Typography.meta)
                                .foregroundStyle(WindowColor.secondaryInk)
                        }
                    }
                    TextField(SyncCopy.peerPayload, text: $model.scannedPeer)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("settings.sync.peerPayload")
                    HStack(spacing: Tokens.Spacing.s) {
                        TextField(SyncCopy.peerCode, text: $model.peerCode)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .accessibilityIdentifier("settings.sync.peerCode")
                        matchTag(comparison.match)
                        Spacer()
                        Button(SyncCopy.cancel) { model.cancelPairing() }
                        Button(SyncCopy.completePairing) { model.completePairing() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.scannedPeer.isEmpty || comparison.match == .differs)
                            .accessibilityIdentifier("settings.sync.completePairing")
                    }
                }
            } else {
                HStack {
                    Text(SyncCopy.compareCodes)
                        .windowFont(Tokens.Typography.body)
                        .foregroundStyle(WindowColor.secondaryInk)
                    Spacer()
                    Button(SyncCopy.pairDevice) { model.startPairing() }
                        .disabled(!model.isAvailable)
                        .accessibilityIdentifier("settings.sync.pair")
                }
            }
        }
    }

    private var conflicts: some View {
        GroupBox(SyncCopy.reviewTitle, layout: .rows) {
            ForEach(model.conflicts) { conflict in
                RowView(conflict.theirs, detail: SyncCopy.replaced(kind: conflict.kind, mine: conflict.mine)) {
                    HStack(spacing: Tokens.Spacing.s) {
                        Button(SyncCopy.keepTheirs) { model.keepTheirs(conflict) }
                        Button(SyncCopy.keepMine) { model.keepMine(conflict, database: database) }
                    }
                }
            }
        }
        .accessibilityIdentifier("settings.sync.conflicts")
    }

    private func codeLine(_ label: String, _ code: String) -> some View {
        HStack(spacing: Tokens.Spacing.s) {
            Text(label).windowFont(Tokens.Typography.body).foregroundStyle(WindowColor.secondaryInk)
            Text(code).windowFont(Tokens.Typography.section).monospaced().foregroundStyle(WindowColor.ink)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func matchTag(_ match: PairingComparison.Match) -> some View {
        switch match {
        case .waiting: EmptyView()
        case .matches: StatusTag(SyncCopy.codesMatch, kind: .good)
        case .differs: StatusTag(SyncCopy.codesDiffer, kind: .warn)
        }
    }
}

public enum SyncCopy {
    public static let off = "Sync is off"
    public static let offDetail = "Local transcription works without a connected service or paired device."
    public static let unavailable = "Sync isn’t available in this session. Local dictation is unaffected."
    public static let pairDevice = "Pair a device"
    public static let statusTitle = "Sync"
    public static let statusRow = "Status"
    public static let thisDevice = "This Mac"
    public static func key(_ fingerprint: String) -> String { "Sync key \(fingerprint)" }
    public static let noKey = "Key shown after syncing or pairing."
    public static let local = "Local first"
    public static let offlineTag = "Offline"
    public static let pause = "Pause"
    public static let syncNow = "Sync now"
    public static let folderTitle = "Sync folder"
    public static let folderNotSet = "Not set. Point both devices at the same synced folder."
    public static let chooseFolder = "Choose folder…"
    public static let useForSync = "Use for sync"
    public static let notSyncedYet = "Not synced yet."
    public static func lastSynced(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "Last synced \(f.string(from: date))."
    }
    public static let paused = "Paused. Nothing is sent or received until you resume."
    public static let offline = "Offline. The sync folder can’t be reached; local dictation continues."
    public static let syncing = "Syncing…"
    public static let devicesTitle = "Connected devices"
    public static let noDevices = "No devices paired"
    public static let compareCodes = "Compare pairing codes before connecting."
    public static let pairedNotSynced = "Paired · not synced yet."
    public static let pairedTag = "Paired"
    public static let pausedTag = "Paused"
    public static func otherDevice(_ id: String) -> String { "Another device (\(id.prefix(4)))" }
    public static let pairTitle = "Pair a device"
    public static let thisMac = "This Mac"
    public static let otherDeviceTitle = "Other device"
    public static let waitingForPeer = "Paste its pairing link below"
    public static let qrLabel = "Pairing code for this Mac"
    public static let peerPayload = "Other device’s pairing link (voiceplus-pair://…)"
    public static let peerCode = "Code shown on the other device"
    public static let codesMatch = "Codes match"
    public static let codesDiffer = "Codes differ"
    public static let cancel = "Cancel"
    public static let completePairing = "Pair"
    public static let scanPrompt = "Scan this code on the other device, then compare the codes."
    public static func paired(_ name: String?, fingerprint: String) -> String {
        "Paired\(name.map { " with \($0)" } ?? ""). Both devices now share key \(fingerprint)."
    }
    public static func synced(_ peers: Int) -> String { "Synced: \(peers) device\(peers == 1 ? "" : "s") merged." }
    public static let reviewTitle = "Review sync"
    public static let dictionaryWord = "Dictionary word"
    public static func replaced(kind: String, mine: String) -> String { "\(kind) · a newer edit from another device replaced “\(mine)” here." }
    public static let keepTheirs = "Keep this"
    public static let keepMine = "Keep this Mac’s"
    public static let everythingTitle = "Everything file"
    public static let passphraseTitle = "Passphrase"
    public static let passphraseDetail = "Encrypts the file. It is never stored."
    public static let exportTitle = "Export or import everything"
    public static let export = "Export everything…"
    public static let importFile = "Import…"
    public static let passphraseFirst = "Set a passphrase first."
    public static let importPassphraseFirst = "Enter the file’s passphrase first."
    public static func exported(_ name: String) -> String { "Exported everything to \(name)." }
    public static func imported(_ name: String) -> String { "Imported and merged \(name)." }
    public static let footnote = "Dictionary, personas, snippets, adapter weights and settings sync end-to-end encrypted. Audio never syncs. Transfers with invalid keys are rejected. Sync is optional. Its encryption key stays in Keychain; unavailable secure storage never blocks local dictation."
}

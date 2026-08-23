import AppKit
import SwiftUI

/// P6.4 — Settings "Sync" tab: QR pairing, folder transport, export/import-everything.
/// The master key never leaves the Keychain; the export file is passphrase-encrypted.
@MainActor
public final class SyncSettingsViewModel: ObservableObject {
    private let service: SyncService?
    @Published public private(set) var fingerprint: String?
    @Published public private(set) var qrImage: NSImage?
    @Published public private(set) var shortCode: String?
    @Published public var scannedPeer = ""
    @Published public var peerCode = ""
    @Published public var passphrase = ""
    @Published public private(set) var folderPath: String?
    @Published public private(set) var status: String?

    public init(service: SyncService?) {
        self.service = service
        fingerprint = service?.keyFingerprint
        folderPath = service?.folderURL?.path
    }

    public var isAvailable: Bool { service != nil }

    public func startPairing() {
        guard let service else { return }
        let payload = service.startPairing()
        shortCode = payload.shortCode
        if let png = service.qrPNG(), let image = NSImage(data: png) { qrImage = image }
        status = "Scan this code on the other device, then confirm its short code here."
    }

    public func completePairing() {
        guard let service, !scannedPeer.isEmpty else { return }
        do {
            let key = try service.completePairing(scanned: scannedPeer,
                                                  confirmedPeerCode: peerCode.isEmpty ? nil : peerCode)
            fingerprint = key.fingerprint
            qrImage = nil
            shortCode = nil
            scannedPeer = ""
            peerCode = ""
            status = "Paired. Both devices now share key \(key.fingerprint)."
        } catch { status = "Pairing failed: \(error)" }
    }

    public func chooseFolder() {
        guard let service else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use for sync"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        service.folderURL = url
        folderPath = url.path
    }

    public func syncNow() {
        guard let service else { return }
        do {
            let result = try service.syncNow()
            status = "Synced: \(result.peersApplied.count) peer(s) merged."
        } catch { status = "Sync failed: \(error)" }
    }

    public func exportEverything() {
        guard let service, !passphrase.isEmpty else { status = "Set a passphrase first."; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "VoicePlus.voiceplus"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try service.exportEverything(to: url, passphrase: passphrase)
            status = "Exported everything to \(url.lastPathComponent)."
        } catch { status = "Export failed: \(error)" }
    }

    public func importEverything() {
        guard let service, !passphrase.isEmpty else { status = "Enter the file's passphrase first."; return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try service.importEverything(from: url, passphrase: passphrase)
            status = "Imported and merged \(url.lastPathComponent)."
        } catch { status = "Import failed: \(error)" }
    }
}

struct SyncSettingsTab: View {
    @ObservedObject var model: SyncSettingsViewModel

    var body: some View {
        Form {
            if !model.isAvailable {
                Text("Sync is unavailable in this session.").foregroundStyle(.secondary)
            } else {
                Section("This device") {
                    LabeledContent("Sync key", value: model.fingerprint ?? "—")
                    Text("Dictionary, personas, snippets, adapter weights and settings sync end-to-end encrypted. Audio never syncs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Pair a device") {
                    if let qr = model.qrImage {
                        HStack {
                            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 120, height: 120)
                            VStack(alignment: .leading) {
                                if let code = model.shortCode { Text("Short code: \(code)").font(.title3.monospaced()) }
                                Text("Scan on the other device; type its short code below to confirm.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        TextField("Peer QR payload (voiceplus-pair://…)", text: $model.scannedPeer)
                        TextField("Peer short code", text: $model.peerCode)
                        Button("Complete pairing") { model.completePairing() }.disabled(model.scannedPeer.isEmpty)
                    } else {
                        Button("Show pairing QR…") { model.startPairing() }
                    }
                }
                Section("Transport") {
                    LabeledContent("Folder", value: model.folderPath ?? "not set")
                    HStack {
                        Button("Choose folder…") { model.chooseFolder() }
                        Button("Sync now") { model.syncNow() }.disabled(model.folderPath == nil)
                    }
                    Text("Point both devices at the same synced folder (iCloud Drive, Dropbox…). Files are sealed with the shared key.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Everything file") {
                    SecureField("Passphrase", text: $model.passphrase)
                    HStack {
                        Button("Export everything…") { model.exportEverything() }
                        Button("Import…") { model.importEverything() }
                    }
                }
                if let status = model.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

import AppKit
import Engine
import Foundation
import Providers
import Shared
import SwiftUI

// V5 M23 — meetings exposed to agents over MCP (`Providers/MCPServer`). Off by default: Settings ›
// Providers "Expose meetings to agents (MCP)". While it is off the HTTP listener is never started
// and `VoicePlusApp --mcp-stdio` refuses to serve. On:
// - stdio: Claude Code / Codex launch the app binary with `--mcp-stdio`; it reads the meeting
//   store on disk (a meeting being recorded is saved after every utterance, so it is "live" there);
// - HTTP: while the app runs, `http://127.0.0.1:47613/mcp` with a bearer token from the Keychain,
//   live transcript straight from the capture in progress.
// Tools are read-only. Speaker names (M13/M18) replace "You" / "Others 2" where known.

public enum MeetingsMCPSettings {
    public static let enabledKey = "mcp.meetings.enabled"
    public static let tokenKey = "mcp.meetings.token"

    public static func isEnabled(_ settings: SettingsStore?) -> Bool { settings?.bool(enabledKey) ?? false }
}

/// `MCPMeetingSource` over the meeting store.
public struct StoreMeetingSource: MCPMeetingSource {
    public let store: MeetingStore
    let names: any MeetingSpeakerNameSource
    let live: @Sendable () async -> MeetingRecord?
    let rank: @Sendable (String, [MeetingRecord], Int) async -> [MeetingLibraryExcerpt]

    public init(store: MeetingStore = MeetingStore(), names: (any MeetingSpeakerNameSource)? = nil,
                live: @escaping @Sendable () async -> MeetingRecord?,
                rank: @escaping @Sendable (String, [MeetingRecord], Int) async -> [MeetingLibraryExcerpt] = { q, records, k in
                    await MeetingIntelligence.shared.search(q, over: records, k: k)
                }) {
        self.store = store
        self.names = names ?? FileMeetingSpeakerNames(store: store)
        self.live = live
        self.rank = rank
    }

    /// For the stdio process: the newest unfinished meeting whose file changed in the last
    /// `freshness` seconds (an abandoned recording is not "live").
    public static func diskLive(_ store: MeetingStore, freshness: TimeInterval = 600,
                                now: @escaping @Sendable () -> Date = Date.init) -> @Sendable () async -> MeetingRecord? {
        {
            store.list().first { record in
                guard record.endedAt == nil else { return false }
                let file = store.directory(for: record.id).appendingPathComponent("meeting.json")
                let modified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? .distantPast
                return now().timeIntervalSince(modified) <= freshness
            }
        }
    }

    func records() async -> (all: [MeetingRecord], liveID: String?) {
        let current = await live()
        return (MeetingsLibrary.merge(store.list(), live: current), current?.id)
    }

    func summary(_ r: MeetingRecord, liveID: String?) -> MCPMeetingSummary {
        let n = names.names(for: r.id)
        var speakers: [String] = []
        for u in r.transcript.utterances where !speakers.contains(n.name(for: u.speaker)) { speakers.append(n.name(for: u.speaker)) }
        return MCPMeetingSummary(id: r.id, title: r.title, startedAt: r.startedAt, endedAt: r.endedAt, isLive: r.id == liveID,
                                 speakers: speakers, utteranceCount: r.transcript.utterances.count, hasNotes: r.notes != nil)
    }

    func transcript(_ r: MeetingRecord, liveID: String?) -> MCPMeetingTranscript {
        let n = names.names(for: r.id)
        return MCPMeetingTranscript(meeting: summary(r, liveID: liveID),
                                    lines: r.transcript.utterances.map { MCPTranscriptLine(start: $0.range.lowerBound, speaker: n.name(for: $0.speaker), text: $0.text) },
                                    notes: r.notes?.markdown)
    }

    public func listMeetings(limit: Int) async -> [MCPMeetingSummary] {
        let (all, liveID) = await records()
        return all.prefix(limit).map { summary($0, liveID: liveID) }
    }

    public func transcript(id: String) async -> MCPMeetingTranscript? {
        let current = await live()
        if let current, current.id == id { return transcript(current, liveID: id) }
        guard let r = try? store.load(id: id) else { return nil }
        return transcript(r, liveID: nil)
    }

    public func liveTranscript() async -> MCPMeetingTranscript? {
        guard let current = await live() else { return nil }
        return transcript(current, liveID: current.id)
    }

    public func search(_ query: String, limit: Int) async -> [MCPSearchHit] {
        let (all, _) = await records()
        return await rank(query, all, limit).map {
            MCPSearchHit(meetingID: $0.meetingID, title: $0.title, startedAt: $0.startedAt,
                         start: $0.window.start, end: $0.window.end, text: $0.window.text)
        }
    }
}

/// Starts and stops the loopback HTTP server with the setting. Never starts while it is off.
public final class MeetingsMCPController: @unchecked Sendable {
    public static let shared = MeetingsMCPController()

    private let lock = NSLock()
    private var transport: MCPHTTPTransport?
    private var settings: SettingsStore?
    private var secrets: any SecretStore
    private var makeSource: () -> any MCPMeetingSource
    private let port: UInt16

    public init(settings: SettingsStore? = nil, secrets: any SecretStore = KeychainSecretStore(),
                port: UInt16 = MCPHTTPTransport.defaultPort,
                makeSource: @escaping () -> any MCPMeetingSource = {
                    StoreMeetingSource(live: { await MainActor.run { MeetingCaptureController.shared.state.liveRecord } })
                }) {
        self.settings = settings; self.secrets = secrets; self.port = port; self.makeSource = makeSource
    }

    public func configure(settings: SettingsStore) { lock.withLock { self.settings = settings } }

    public var isEnabled: Bool { MeetingsMCPSettings.isEnabled(lock.withLock { settings }) }
    public var isRunning: Bool { lock.withLock { transport }?.isRunning ?? false }
    public var url: URL? { lock.withLock { transport }?.url }

    /// The bearer token for HTTP, created on first use and kept in the Keychain.
    public func token() -> String {
        if let t = try? secrets.get(MeetingsMCPSettings.tokenKey), !t.isEmpty { return t }
        let t = MCPHTTPTransport.makeToken()
        try? secrets.set(t, for: MeetingsMCPSettings.tokenKey)
        return t
    }

    /// Brings the server in line with the setting: on → listening, off → stopped.
    public func apply() async {
        guard isEnabled else { stop(); return }
        guard lock.withLock({ transport }) == nil else { return }
        let t = MCPHTTPTransport(server: MCPServer(source: makeSource(), version: AppVersion.current), token: token(), port: port)
        lock.withLock { transport = t }
        do { try await t.start() } catch {
            Log.providers.warning("mcp: HTTP server could not start: \(error)")
            t.stop()
            lock.withLock { if transport === t { transport = nil } }
        }
    }

    public func stop() {
        let t = lock.withLock { () -> MCPHTTPTransport? in defer { transport = nil }; return transport }
        t?.stop()
    }

    public func setEnabled(_ on: Bool) async {
        lock.withLock { settings }?.set(on, for: MeetingsMCPSettings.enabledKey)
        await apply()
    }
}

/// `VoicePlusApp --mcp-stdio`: serve MCP on stdin/stdout, only when the setting is on.
public enum MeetingsMCPStdio {
    public static func requested(_ arguments: [String]) -> Bool { arguments.contains(MCPConfigSnippet.stdioFlag) }

    public static let refusal = "VoicePlus: meetings are not exposed to agents. Turn on Settings › Providers › “Expose meetings to agents (MCP)”.\n"

    /// Exit code: 2 when the setting is off (nothing served), 0 when stdin closed.
    public static func run(settings: SettingsStore = UserDefaultsSettingsStore(), store: MeetingStore = MeetingStore(),
                           serve: (MCPServer) async -> Void = { await MCPStdioTransport(server: $0).run() }) async -> Int32 {
        guard MeetingsMCPSettings.isEnabled(settings) else {
            FileHandle.standardError.write(Data(refusal.utf8))
            return 2
        }
        await serve(MCPServer(source: StoreMeetingSource(store: store, live: StoreMeetingSource.diskLive(store)),
                              version: AppVersion.current))
        return 0
    }
}

enum AppVersion {
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
}

// MARK: - Settings › Providers row

enum MeetingsMCPCopy {
    static let groupTitle = "Agents"
    static let title = "Expose meetings to agents (MCP)"
    static let detail = "Lets Claude Code, Codex and other MCP clients on this Mac read your meeting transcripts: list, read, search and follow the live transcript. Read-only. Off by default."
    static let claudeCode = "Claude Code"
    static let codex = "Codex (~/.codex/config.toml)"
    static let http = "While VoicePlus is open (HTTP)"
    static let copy = "Copy"
    static let notRunning = "The HTTP server is not running (another app may be using port 47613). The command-line setup above still works."
}

@MainActor
final class MeetingsMCPModel: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var running = false
    let controller: MeetingsMCPController

    init(controller: MeetingsMCPController = .shared) {
        self.controller = controller
        self.enabled = controller.isEnabled
        self.running = controller.isRunning
    }

    func set(_ on: Bool) async {
        enabled = on
        await controller.setEnabled(on)
        running = controller.isRunning
    }

    var executable: String { Bundle.main.executablePath ?? "/Applications/VoicePlus.app/Contents/MacOS/VoicePlusApp" }
    var claudeCode: String { MCPConfigSnippet.claudeCode(executable: executable) }
    var codex: String { MCPConfigSnippet.codex(executable: executable) }
    var http: String? { controller.url.map { MCPConfigSnippet.claudeCodeHTTP(url: $0, token: controller.token()) } }
}

struct MeetingsMCPSection: View {
    @StateObject private var model = MeetingsMCPModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Toggle(MeetingsMCPCopy.title, isOn: Binding(get: { model.enabled }, set: { on in Task { await model.set(on) } }))
                .accessibilityIdentifier("providers.mcp.toggle")
            Text(MeetingsMCPCopy.detail)
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            if model.enabled {
                snippet(MeetingsMCPCopy.claudeCode, model.claudeCode)
                snippet(MeetingsMCPCopy.codex, model.codex)
                if let http = model.http { snippet(MeetingsMCPCopy.http, http) } else {
                    Text(MeetingsMCPCopy.notRunning).windowFont(Tokens.Typography.meta).foregroundStyle(WindowColor.secondaryInk)
                }
            }
        }
        .accessibilityIdentifier("providers.mcp")
    }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack {
                Text(title).windowFont(Tokens.Typography.meta).foregroundStyle(WindowColor.ink)
                Spacer()
                Button(MeetingsMCPCopy.copy) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.link)
            }
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Tokens.Spacing.s)
                .background(RoundedRectangle(cornerRadius: 6).fill(WindowColor.secondaryInk.opacity(0.08)))
        }
    }
}

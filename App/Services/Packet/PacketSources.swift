import Foundation
import GRDB
import Pipeline
import Shared

/// Context Writer §2 — the packet's non-screen sources, as closures the builder is handed
/// (`ContextPacketBuilder.recentDictations` / `.persona` / `.language`). Tests pass their own.
public enum PacketSources {
    /// The last `limit` landed texts in an app from `dictation_history`, newest first. Held or
    /// empty rows are skipped; a browser sub-app key (`bundle|host`) reads by its bundle.
    public static func recentDictations(_ database: AppDatabase?, limit: Int = 3) -> (String) -> [String] {
        { key in
            guard let database, limit > 0 else { return [] }
            let bundle = BrowserSubApp.split(key: key).bundleID
            guard !bundle.isEmpty else { return [] }
            do {
                return try database.reader.read { db in
                    try String.fetchAll(db, sql: """
                        SELECT finalText FROM dictation_history
                        WHERE appBundleID = ? AND finalText <> '' ORDER BY startedAt DESC LIMIT ?
                        """, arguments: [bundle, limit])
                }
            } catch {
                Log.db.error("context packet: recent dictations read failed: \(error)")
                return []
            }
        }
    }

    /// The persona the user wrote for an app (Settings › Personas). An auto-draft is not "set":
    /// it is the style learner's guess and stays out of the packet. A `bundle|host` key falls
    /// back to the bundle's persona.
    public static func persona(_ manager: PersonaManager?) -> (String) -> String? {
        { key in
            guard let manager else { return nil }
            for candidate in [key, BrowserSubApp.split(key: key).bundleID] {
                guard let p = try? manager.store.persona(for: candidate), !p.isAutoDrafted else { continue }
                let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
            return nil
        }
    }

    /// The first language the user chose in onboarding (LANG1), nil when never answered.
    public static func language(_ settings: SettingsStore?) -> () -> String? {
        { LanguagePreferences.load(settings)?.languages.first }
    }
}

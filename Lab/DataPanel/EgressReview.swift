import Foundation

/// V5 I4 — the reviewed egress list. Every host a product source file names (a literal
/// `http(s)://host`) must be here with the reason it may be contacted, or the source audit
/// (`Tests/AppTests/NoTelemetryAuditI4Tests`) fails. No analytics, crash-reporting or telemetry host
/// is, or may be, on it. Hosts the user types (BYO endpoints, Ollama, custom providers) are not
/// listed: they are the user's choice and still pass `EgressGate` (kill switch) and the Data Panel log.
///
/// Reviewed 2026-10-02 (V5 W8). Nothing here is contacted without a user action or a user-enabled
/// feature: model / dictionary / dataset downloads, a connected provider or connector, an update check.
public enum EgressReview {
    public static let hosts: [String: String] = [
        // Model, dictionary and dataset downloads (user-started; Lab sets are developer-only).
        "huggingface.co": "speech / LLM model downloads (ModelCatalog, LocalLLMCatalog), public dictionaries",
        "github.com": "source links in comments; release DMG downloads named by the appcast",
        "raw.githubusercontent.com": "public dictionary word lists (PublicDictionaries)",
        "wordlist.aspell.net": "SCOWL word list (PublicDictionaries)",
        "app.aspell.net": "SCOWL word list generator (PublicDictionaries)",
        "www.openslr.org": "Lab evaluation datasets (LibriSpeech etc., developer-only)",
        "commonvoice.mozilla.org": "Lab evaluation dataset (developer-only)",
        "iqtlabs.github.io": "Lab evaluation dataset (developer-only)",
        "groups.inf.ed.ac.uk": "Lab evaluation dataset (AMI, developer-only)",
        // Generative providers the user connects (RoutingTable; keys in the Keychain).
        "api.openai.com": "OpenAI provider (user-connected)",
        "auth.openai.com": "OpenAI OAuth sign-in (user-started)",
        "chatgpt.com": "ChatGPT-account provider endpoint (user-connected)",
        "api.anthropic.com": "Anthropic provider (user-connected)",
        "openrouter.ai": "OpenRouter provider (user-connected)",
        "api.groq.com": "Groq provider (user-connected)",
        "api.cerebras.ai": "Cerebras provider (user-connected)",
        // Action connectors the user authorises.
        "www.googleapis.com": "Google Calendar / Gmail connectors (user-authorised)",
        "gmail.googleapis.com": "Gmail connector (user-authorised)",
        "oauth2.googleapis.com": "Google OAuth token exchange (user-started)",
        "accounts.google.com": "Google OAuth consent (user-started)",
        "api.notion.com": "Notion connector (user-authorised)",
        "slack.com": "Slack connector (user-authorised)",
        "linear.app": "Linear connector OAuth (user-authorised)",
        "api.linear.app": "Linear connector (user-authorised)",
        "api.github.com": "GitHub connector (user-authorised)",
        "www.google.com": "deterministic 'search for …' action opens the user's browser (not an app request)",
        // Updates (V5 J5): feed check (automatic checks are a Settings toggle) + DMG on request.
        "updates.adityakatare.in": "appcast feed (Settings › Updates)",
        // Not network: XML namespaces and loopback.
        "www.w3.org": "SVG/XML namespace identifier (never fetched)",
        "localhost": "loopback (Ollama / local servers / OAuth redirect)",
        "127.0.0.1": "loopback (Ollama / local servers / OAuth redirect)",
    ]

    /// Analytics, crash-reporting and telemetry vendors. None may appear in product sources,
    /// dependencies or `hosts` (I4 "no telemetry").
    public static let forbiddenHostFragments: [String] = [
        "posthog", "sentry.io", "ingest.sentry", "mixpanel.com", "amplitude.com", "segment.io",
        "segment.com", "firebaseio.com", "firebase.google", "app-measurement.com", "google-analytics.com",
        "googletagmanager.com", "crashlytics", "appcenter.ms", "bugsnag.com", "datadoghq", "telemetrydeck",
        "count.ly", "plausible.io", "heapanalytics.com", "newrelic.com", "nr-data.net", "rollbar.com",
        "instabug.com", "aptabase.com", "fullstory.com", "hotjar.com", "logrocket",
    ]

    public static func isReviewed(host: String) -> Bool { hosts[host.lowercased()] != nil }

    public static func isForbidden(host: String) -> Bool {
        let h = host.lowercased()
        return forbiddenHostFragments.contains { h.contains($0) }
    }
}

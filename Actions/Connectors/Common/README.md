# Actions/Connectors/Common (P4.6)

Shared plumbing for native connectors (Slack, Gmail, Google Calendar, Linear, Notion, GitHub).

- `Connector` protocol: `capabilities`, `scopes`, `matches(target)`, `perform(action) -> .performed | .fallbackToUI`.
  Use `routingFallback(for:)` first in every `perform` — wrong target / missing capability / not signed in → UI automation.
- `ConnectorOAuth`: OAuth 2.0 + PKCE (copied from Providers/OAuthPKCE.swift; Actions cannot import Providers).
  `signIn(openURL:codeReceiver:)` — the app supplies the loopback listener; `accessToken()` refreshes near expiry.
- `ConnectorClient`: bearer JSON client over `HTTPTransport`; 401 → one refresh + retry; every call → `NetworkLogRecord`
  (stage `act.connector`) via the injected `NetworkLogSink` closure (Data Panel).
- `MockHTTPTransport` for tests: scripted responses, captured requests, `jsonBody(i)`.
- Secrets: `ConnectorSecretStore` (wrap `KeychainSecretStore` in the app; `InMemoryConnectorSecretStore` in tests).

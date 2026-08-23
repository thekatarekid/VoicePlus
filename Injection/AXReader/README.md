# Injection/AXReader — deep AX reading (P3.4)

- `AXReading` — facade: `windows(pid:)`, `readWindow(_:options:)`, `readFocusedWindow(pid:options:)`, `readDocument(_:)` (full scrollback, keep-tail).
- `AXNodeAccess` — minimal per-node surface; `LiveAXNodeAccess` (AXUIElement + AXObserver) and `MockAXTree` (tests, mock engine).
- `AXWindowReader` — DFS over the window tree; text nodes read by stitching `AXStringForRange` chunks over `0..<AXNumberOfCharacters` (scrollback) or over `AXVisibleCharacterRange` (visible only); falls back to `AXValue`. Hard cap 200k chars (`AXReadLimits.maxCharacters`), `keepHead`/`keepTail` truncation.
- `WindowContentCache` / `CachedAXReader` — per `(window, scrollback)` entry; invalidated by `AXValueChanged` / focus / destroy notifications via `AXObserver`, TTL fallback (2 s) when observers are unavailable.
- `AXReaderProviding` — additive protocol; `LiveSystemAccess` and `MockSystemAccess` conform in this directory, `SystemAccess` is untouched.

Untested on hardware: `LiveAXNodeAccess`, `LiveObservation` (needs AX trust). Window numbers use the AXUIElement hash (no public CGWindowID mapping).

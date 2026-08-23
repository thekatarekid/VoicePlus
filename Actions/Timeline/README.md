# Actions/Timeline (P3.1)

Input timeline recorder. Everything here is in-memory only — nothing is persisted.

- `TimelineClock` — single monotonic clock (`CLOCK_UPTIME_RAW`). `TimelineClock.shared.now()` stamps
  timeline events; `CaptureAlignment(captureStart:)` maps instants ↔ `TranscriptSpan.audioRange`
  seconds so a word's audio span can be looked up in the pointer/stroke history.
- `TimelineEvent` / `GlobalPoint` — pointerMove, click, strokePoint, selectionChange; points are Cocoa
  global coordinates tagged with display id + unit position inside that display.
- `InputTimeline` — ring buffer, 30 s horizon (relative to newest event), capacity-bounded; queries:
  `pointer(at:)`, `strokes(in:)`, `selection(at:)`, `events(in:)`.
- `DisplayNormalizer` — Quartz (`CGEvent.location`) ↔ Cocoa global ↔ per-display local; injectable
  `DisplayFrame`s for tests, `DisplayNormalizer.current()` for live `NSScreen`s.
- `EventTapRecorder` — listen-only `CGEvent` tap, `start()`/`stop()` around the hotkey hold; guarded
  by `CGPreflightListenEventAccess`. Feeds the timeline and `InkStrokeCapture`.
- `InkStrokeCapture` — drag → `InkStroke`, mirrored to an `InkStrokeSink` (the overlay in `App/Overlay`).

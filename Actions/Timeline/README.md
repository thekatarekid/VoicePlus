# Actions/Timeline (P3.1, G1)

Input timeline recorder. Everything here is in-memory only — nothing is persisted.

- `TimelineClock` — single monotonic clock (`CLOCK_UPTIME_RAW`). `TimelineClock.shared.now()` stamps
  timeline events; `CaptureAlignment(captureStart:)` maps instants ↔ `TranscriptSpan.audioRange`
  seconds so a word's audio span can be looked up in the pointer/region history.
- `TimelineEvent` / `GlobalPoint` — pointerMove, click, region (a drawn box), selectionChange, and the
  legacy strokePoint (replay fixtures only); points are Cocoa global coordinates tagged with display id +
  unit position inside that display.
- `InputTimeline` — ring buffer, 30 s horizon (relative to newest event), capacity-bounded; queries:
  `pointer(at:)`, `regions(in:)`, `strokes(in:)`, `selection(at:)`, `events(in:)`.
- `DisplayNormalizer` — Quartz (`CGEvent.location`) ↔ Cocoa global ↔ per-display local; injectable
  `DisplayFrame`s for tests, `DisplayNormalizer.current()` for live `NSScreen`s.
- `EventTapRecorder` — listen-only `CGEvent` tap, `start()`/`stop()` around the key press; guarded
  by `CGPreflightListenEventAccess`. Feeds the timeline and `RegionCapture`; a left drag draws a box
  only while its `RegionGate` is open (`RegionGesturePolicy`: key down, or latch + "draw without a key").
- `RegionCapture` — drag → `DrawnRegion` (box clamped to the display it started on, global and
  display-local rects), mirrored to a `RegionSink` (the overlay in `App/Overlay`); finished boxes go to
  `onRegion` (the deixis service). Drags smaller than `minimumSide` on either axis are clicks, not boxes.

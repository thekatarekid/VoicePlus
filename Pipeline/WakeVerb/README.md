# Pipeline/WakeVerb (P5.2)

`WakeVerbGrammar` parses leading verbs while latched (V3 §4.7): `type <payload>`, `send` (+ it/that),
`<app> <payload>` / `in|to|tell <app> <payload>`. `WakeVerbPreRoute` is a `GatekeeperPreRouting` hook
(put it in `PreRoutingClassifier.hooks`); it fires only when `context.extra["input.mode"] == WakeVerbPreRoute.latchedValue`,
forces `.dictate` with confidence 1, and records the parse. `WakeVerbStage` then blanks the wake phrase
(audioRange/confidence preserved). `WakeVerbHintModel` counts uses: full hint for 10 uses, fades over 5, hidden.
Wiring into the App (hint in pill, mode flag in StageContext) is left to the AppWave agent.

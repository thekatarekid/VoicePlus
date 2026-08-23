# Actions/Agent — P4.5 agentic fallback (+ P4.0 license check)

## P4.0 — Cua license check (2026-08-24)
- `trycua/cua` `LICENSE.md`: **MIT** (root). Sub-components: Kasm MIT, OmniParser CC-BY-4.0, optional `cua-agent[omni]` extra pulls **ultralytics (AGPL-3.0)**.
- Verdict: the license *clears* (MIT), but Cua is not imported: it is a Python-first SDK whose agent loop is **screenshot + VM/sandbox** based, which contradicts ground rule "screen context via Accessibility API only — no screenshots" and the no-new-runtime constraint. The `omni` extra is AGPL and must never be pulled.
- Therefore `NativeAgentBackend` is the shipped backend. `AgentActionBackend` is the seam where a Cua-backed backend could be added later if a screenshot-free Swift primitive set ever appears; nothing else would change.

## Design
- `AgentActionBackend` — `run(goal:)` / `stop()` / `isRunning`.
- `NativeAgentBackend` — observe (`AXSummary` from `ActionSystem`, ≤80 elements, no pixels) → `PlannerLLM.plan` → `StepPlan` → each step `ConsentEngine.submit` → `ActionExecutor.run` (precondition/execute/postcondition) → re-observe, ≤`maxRounds`.
- Tools = `AgentTool.vocabulary` = exactly the 12 deterministic `ActionKind`s. The planner can never express a coordinate click.
- `PlannerLLM` — provider-backed planners are injected at integration (`PlannerPrompt` gives the shared prompt). `ScriptedPlanner` for tests/Lab.
- Consent: reversible steps run; semi get the undo toast; irreversible raise a `ConfirmationCard` and the loop *waits* on `confirmation(card)` (App wires click / spoken "confirm"). Default declines. An agent never self-confirms.
- "stop": `stop()` sets the flag, cancels the in-flight planner call, queued steps are cancelled, executed steps carrying a `compensating` request are reversed LIFO (through the executor — they undo already-consented work). Wall-clock watchdog calls `stop()` at `config.timeout`; status `.timedOut`.
- `StepChipsModel` — chips UI model (done shrink 0.8, current glows, upcoming ghosted 0.45); `pillText` says "thinking…" while planning so agentic vs deterministic stays legible.

## ActRouting (P4.2)
`ActDomainActivation` (second key → `activate/deactivate`; App binds it to `HotkeyStateMachine`), `ActIntentParser` (stop/confirm/cancel grammar → fuzzy catalogue, app-kind scoped → `.agentic(goal)` for the unmatched/multi-step tail), `ActRouter` (consent + executor for deterministic, backend for agentic). `ActPreRouting` mirrors `Pipeline.GatekeeperPreRouting`; `Actions` does not link `Pipeline`, so the composition root adapts it (return `GatekeeperDecision(route: .none, routeSource: .rules)` when the act domain claims the utterance).

Untested live: real AX planner prompts against a provider LLM; the App-side card wiring.

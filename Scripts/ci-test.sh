#!/bin/bash
# V5 J2 — the CI build + test step, identical on a GitHub-hosted runner, a self-hosted runner and
# this machine (`Scripts/ci-test.sh`). Writes the full test log to $CI_TEST_LOG for upload.
#
#   - Command Line Tools only (this machine, a self-hosted runner): applies bootstrap-toolchain.
#     With Xcode selected (GitHub's macos-15 image) the toolchain is sane and the step is skipped.
#   - Non-hardware suites only: every test target, with the opt-in switches that reach real
#     models, microphones, network datasets or wall-clock budgets unset. Those suites skip
#     themselves (VOICEPLUS_HARDWARE_TESTS, VOICEPLUS_LIVE_MODELS, VOICEPLUS_TIMING_ASSERTS, …).
#   - --no-parallel: timing-sensitive suites are parallel-flaky (V5 J1).
#
# Env: CI_SCRATCH (default .build-ci) · CI_TEST_LOG (default $CI_SCRATCH/test.log)
#      CI_TEST_FILTER (regex; default: every test target) · CI_TEST_SKIP (regex; default: none)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SCRATCH="${CI_SCRATCH:-$ROOT/.build-ci}"
LOG="${CI_TEST_LOG:-$SCRATCH/test.log}"
TARGETS="SharedTests|EngineTests|PipelineTests|InjectionTests|ProvidersTests|LabTests|ActionsTests|SyncTests|KeyboardCoreTests|AppTests"
FILTER="${CI_TEST_FILTER:-^($TARGETS)\.}"
SKIP="${CI_TEST_SKIP:-}"

# Opt-in switches that make a suite touch hardware, downloaded models, datasets or the network.
for var in VOICEPLUS_HARDWARE_TESTS VOICEPLUS_LIVE_MODELS VOICEPLUS_TIMING_ASSERTS VOICEPLUS_EVAL_FETCH \
           VOICEPLUS_CORPUS_PASS VOICEPLUS_CHAIN_AB VOICEPLUS_QWEN_WER VOICEPLUS_REFINE_BENCH \
           VOICEPLUS_LLAMA_GGUF VOICEPLUS_LOCALVQE_DIR VOICEPLUS_GATE_RECALL VOICEPLUS_UPDATE_GOLDENS \
           VOICEPLUS_WRITE_RESULTS; do
  unset "$var"
done

if xcode-select -p 2>/dev/null | grep -q CommandLineTools; then
  eval "$("$ROOT/Scripts/bootstrap-toolchain.sh")"
fi

mkdir -p "$(dirname "$LOG")"
: > "$LOG"
{
  echo "== $(date -u '+%Y-%m-%dT%H:%M:%SZ') $(git rev-parse --short HEAD 2>/dev/null || echo '?')"
  swift --version 2>&1
  sw_vers 2>&1 || true
} | tee -a "$LOG"

echo "== swift build" | tee -a "$LOG"
swift build --scratch-path "$SCRATCH" 2>&1 | tee -a "$LOG"

echo "== swift test --no-parallel --filter '$FILTER'${SKIP:+ --skip '$SKIP'}" | tee -a "$LOG"
ARGS=(--scratch-path "$SCRATCH" --no-parallel --filter "$FILTER")
[ -n "$SKIP" ] && ARGS+=(--skip "$SKIP")
set +e
swift test "${ARGS[@]}" 2>&1 | tee -a "$LOG"
STATUS=${PIPESTATUS[0]}
set -e
echo "== summary" | tee -a "$LOG"
grep -E '^(✔|✘) Test run with|Test run with [0-9]+ tests' "$LOG" | tail -1 | tee -a "$LOG" || true
exit "$STATUS"

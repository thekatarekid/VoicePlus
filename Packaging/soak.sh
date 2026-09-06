#!/bin/bash
# P1.12 T3 — thermal / battery soak.
#
#   Packaging/soak.sh [minutes=3] [fixture=email_reply]
#
# Loops fixture dictations through the full landing path (`VoicePlusApp --soak`: mock engine at
# fixture pace → gatekeeper → formatter → style → mock injector) and samples, every 5 s,
# ProcessInfo.thermalState, this process's CPU %, RSS, and landed-latency p50/p95. Alongside it
# samples the machine-wide thermal pressure (`pmset -g therm`) and battery (`pmset -g batt`) so
# an idle-drain figure can be read off a 2 h run on battery. Output: Packaging/soak/<timestamp>.tsv
# plus a one-line summary. Exit 1 if thermal state ever reaches "serious"/"critical" or latency
# p95 exceeds the 1200 ms budget.
set -euo pipefail
MINUTES="${1:-3}"
FIXTURE="${2:-email_reply}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/Packaging/soak"
mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$OUT_DIR/$STAMP.tsv"
SYS="$OUT_DIR/$STAMP.system.log"
SCRATCH="${SCRATCH_PATH:-$ROOT/.build-soak}"

cd "$ROOT"
if [ -x "Scripts/bootstrap-toolchain.sh" ]; then eval "$(Scripts/bootstrap-toolchain.sh)"; fi
echo "building (scratch $SCRATCH)…"
swift build --disable-keychain --scratch-path "$SCRATCH" --product VoicePlusApp >/dev/null
BIN="$SCRATCH/debug/VoicePlusApp"

echo "soak: ${MINUTES} min, fixture ${FIXTURE}, output $OUT"
{
  echo "# $(date) host=$(hostname) minutes=$MINUTES fixture=$FIXTURE"
  pmset -g batt 2>/dev/null | tr '\n' ' '; echo
} > "$SYS"

# System-side sampler (thermal pressure + battery %) every 30 s.
(
  while true; do
    printf '%s\t' "$(date +%H:%M:%S)"
    pmset -g therm 2>/dev/null | tr '\n' ' ' | tr -s ' '
    printf '\t'
    pmset -g batt 2>/dev/null | grep -o '[0-9]*%;[^;]*;' | head -1
    echo
    sleep 30
  done
) >> "$SYS" &
SAMPLER=$!
# Scoped to our own sampler subshell — never a name match. (See the header of
# Packaging/verify_install.sh: a name-based kill once took out the user's app.)
trap '[ -n "${SAMPLER:-}" ] && kill "$SAMPLER" 2>/dev/null; true' EXIT

"$BIN" --soak "$MINUTES" --fixture "$FIXTURE" | tee "$OUT"

# Verdict.
WORST=$(awk -F'\t' 'NR>1 && $2 ~ /serious|critical/ {print $2}' "$OUT" | head -1)
P95MAX=$(awk -F'\t' 'NR>1 && $7+0 > m {m=$7+0} END {print m+0}' "$OUT")
CPUAVG=$(awk -F'\t' 'NR>1 && $3 ~ /^[0-9.]+$/ {s+=$3; n++} END {if (n) printf "%.1f", s/n; else print 0}' "$OUT")
echo "summary: worst thermal=${WORST:-nominal/fair} cpu avg=${CPUAVG}% latency p95 max=${P95MAX} ms; system log: $SYS"
if [ -n "$WORST" ]; then echo "FAIL: thermal throttling reached $WORST"; exit 1; fi
if awk "BEGIN {exit !($P95MAX > 1200)}"; then echo "FAIL: landed-latency p95 ${P95MAX} ms over 1200 ms budget"; exit 1; fi
echo "PASS"

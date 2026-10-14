#!/bin/bash
# Runs the timing-sensitive tests over and over on a loaded machine, to show
# they do not depend on how fast the machine is. Each class (or single test)
# below runs RUNS times in a row with `swift test --filter`, while
# LOAD_PROCESSES copies of `yes > /dev/null` keep the CPU busy. The load
# processes are killed on every exit. Every run is reported as PASS or FAIL;
# a FAIL prints the failing lines of that run, and the script exits 1 if any
# run failed.
#
# RecoveryScriptTests is slow as a class, so only its timing-sensitive tests
# are listed. Pass test filters as arguments to stress those instead, e.g.
#   scripts/stress-tests.sh PowerMonitorTests/
#   scripts/stress-tests.sh 'RecoveryScriptTests/testUninstallRestoresAppNapViaBackstopThenRemoves$'
#
# Usage: scripts/stress-tests.sh [filter ...]
set -euo pipefail
cd "$(dirname "$0")/.."

# Fixed tool paths, never taken from PATH, as in the other scripts.
SWIFT=/usr/bin/swift
YES=/usr/bin/yes
GREP=/usr/bin/grep
MKTEMP=/usr/bin/mktemp
RM=/bin/rm
SED=/usr/bin/sed
CAT=/bin/cat
RUNS=10
LOAD_PROCESSES=4

# `swift test --filter` matches "Module.Class/test"; the trailing slash keeps
# ClosedLidClockTests from also matching ClosedLidClockLidActionsTests.
# MenuBarTests.swift has no class of that name: its classes are listed.
DEFAULT_FILTERS=(
  "PowerMonitorTests/"
  "ClosedLidSleepTests/"
  "ClosedLidClockTests/"
  "CountdownTests/|StatusMenuControlTests/|StatusItemControllerLogicTests/|StatusMenuTests/"
  "RecoveryScriptTests/testInstallMovesNeitherBundleWhenCodesignDoesNotAnswerDuringTheRepair$"
  "RecoveryScriptTests/testUninstallRestoresAppNapViaBackstopThenRemoves$"
)
if (( $# > 0 )); then
  FILTERS=("$@")
else
  FILTERS=("${DEFAULT_FILTERS[@]}")
fi

LOGS="$("$MKTEMP" -d "${TMPDIR:-/tmp}/awake-stress.XXXXXX")"
load_pids=""
stop_load() {
  local pid
  for pid in $load_pids; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in $load_pids; do
    wait "$pid" 2>/dev/null || true
  done
  load_pids=""
  "$RM" -rf "$LOGS"
}
trap stop_load EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Build once, before the load starts; every run below uses --skip-build.
echo "==> building tests"
if ! "$SWIFT" build --build-tests >"$LOGS/build.log" 2>&1; then
  "$CAT" "$LOGS/build.log" >&2
  exit 1
fi

echo "==> starting $LOAD_PROCESSES load processes"
for (( i = 1; i <= LOAD_PROCESSES; i++ )); do
  "$YES" >/dev/null &
  load_pids="$load_pids $!"
done

failures=0
total=0
for filter in "${FILTERS[@]}"; do
  for (( run = 1; run <= RUNS; run++ )); do
    total=$(( total + 1 ))
    log="$LOGS/run-$total.log"
    started=$SECONDS
    if "$SWIFT" test --skip-build --filter "$filter" >"$log" 2>&1; then
      # A filter that matches nothing also exits 0: count what ran.
      if ! "$GREP" -q -E "Executed [1-9][0-9]* tests?, with 0 failures" "$log"; then
        failures=$(( failures + 1 ))
        echo "FAIL $filter run $run/$RUNS: no test matched the filter"
        continue
      fi
      echo "PASS $filter run $run/$RUNS ($(( SECONDS - started ))s)"
    else
      failures=$(( failures + 1 ))
      echo "FAIL $filter run $run/$RUNS ($(( SECONDS - started ))s)"
      "$GREP" -E "error:|failed|Executed" "$log" | "$SED" 's/^/    /' || true
    fi
  done
done

echo
if (( failures > 0 )); then
  echo "stress: $failures of $total runs failed under $LOAD_PROCESSES load processes"
  exit 1
fi
echo "stress: all $total runs passed under $LOAD_PROCESSES load processes"

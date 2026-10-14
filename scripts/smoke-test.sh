#!/bin/bash
# End-to-end smoke test of the real Awake.app. Builds the test build (the
# lid simulation build: INSOMNIA_LID_SIMULATION=1 scripts/build-app.sh)
# into a temp directory, launches it in test mode with a throwaway
# AWAKE_HOME, drives it through the test-only control channel
# ($AWAKE_HOME/test-control, see TestControl.swift) and scripts/simulate-lid.sh,
# and checks the real effects: the status the app writes
# (test-status.json), session.json, the sleep guard log, and the real IOPM
# "Awake mode" assertion in `pmset -g assertions`.
#
# Test mode needs no root and touches nothing outside the temp AWAKE_HOME:
# the sleep guard is simulated (no pmset, no password prompt) and the
# recovery agent is a stand-in (no launchctl). See TestMode.swift. The
# status item shows in the menu bar while the test runs.
#
# Each step has a 10 s deadline and prints PASS or FAIL with the reason;
# the first FAIL prints what the app wrote and exits 1. The app is killed
# and the temp directory removed on every exit. Runs locally and in CI
# (the smoke job in .github/workflows/ci.yml).
#
# Usage: scripts/smoke-test.sh
set -euo pipefail

# Fixed tool paths, never taken from PATH, as in the other scripts.
PMSET=/usr/bin/pmset
PLUTIL=/usr/bin/plutil
DATE=/bin/date
MKTEMP=/usr/bin/mktemp
MKDIR=/bin/mkdir
MV=/bin/mv
RM=/bin/rm
PS=/bin/ps
GREP=/usr/bin/grep
TAIL=/usr/bin/tail
SLEEP=/bin/sleep
CAT=/bin/cat

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_APP="$ROOT/scripts/build-app.sh"
SIMULATE_LID="$ROOT/scripts/simulate-lid.sh"

# Seconds each step may take to show its effect, and for the app to start.
STEP_DEADLINE=10
LAUNCH_DEADLINE=30
POLL=0.2
LID_SECONDS=600

TMP_ROOT="${TMPDIR:-/tmp}"
WORK="$("$MKTEMP" -d "${TMP_ROOT%/}/awake-smoke.XXXXXX")"
AWAKE_DIR="$WORK/home"
CONTROL="$AWAKE_DIR/test-control"
STATUS="$AWAKE_DIR/test-status.json"
SESSION="$AWAKE_DIR/session.json"
GUARD_LOG="$AWAKE_DIR/test-sleepguard.log"
APP_LOG="$AWAKE_DIR/Logs/awake.log"
APP_OUT="$WORK/app-output.log"
APP_PID=""

cleanup() {
  local status=$?
  if [[ -n $APP_PID ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    local i
    for ((i = 0; i < 25; i++)); do
      kill -0 "$APP_PID" 2>/dev/null || break
      "$SLEEP" "$POLL"
    done
    kill -KILL "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  "$RM" -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# What the app wrote, for a failed step.
diagnose() {
  local file
  for file in "$STATUS" "$SESSION" "$GUARD_LOG"; do
    echo "--- $(basename "$file")"
    if [[ -f $file ]]; then "$CAT" "$file"; else echo "(none)"; fi
  done
  echo "--- awake.log (last 40 lines)"
  if [[ -f $APP_LOG ]]; then "$TAIL" -n 40 "$APP_LOG"; else echo "(none)"; fi
  echo "--- app stdout/stderr (last 20 lines)"
  if [[ -f $APP_OUT ]]; then "$TAIL" -n 20 "$APP_OUT"; else echo "(none)"; fi
}

fail() { # message
  echo "FAIL $1"
  diagnose
  exit 1
}

# True while the app process is alive (a zombie counts as gone).
app_alive() {
  local state
  state=$("$PS" -o stat= -p "$APP_PID" 2>/dev/null) || return 1
  [[ -n $state && $state != Z* ]]
}

# Prints the value at KEY in the JSON FILE, "null" for a JSON null. Fails
# when the file or the key is missing.
field() { # file key
  local type
  [[ -f $1 ]] || return 1
  type=$("$PLUTIL" -type "$2" "$1" 2>/dev/null) || return 1
  if [[ $type == "(any)" ]]; then
    echo null
    return 0
  fi
  "$PLUTIL" -extract "$2" raw -o - "$1" 2>/dev/null
}

# The step's reason for failing, set by the checks below.
REASON=""

want() { # key expected: test-status.json has KEY equal to EXPECTED
  local got
  got=$(field "$STATUS" "$1") || { REASON="test-status.json has no $1"; return 1; }
  [[ $got == "$2" ]] || { REASON="$1 is $got, expected $2"; return 1; }
}

# Whether the app holds the "Awake mode" IOPM assertion, from pmset's list
# by owning process. Matched on the app's pid, so another Awake running on
# this Mac (an installed copy) does not count.
assertion() { # held|gone
  local out held=gone
  out=$("$PMSET" -g assertions) || { REASON="pmset -g assertions failed"; return 1; }
  if "$GREP" -qE "pid $APP_PID\\(.*named: \"Awake mode\"" <<<"$out"; then held=held; fi
  [[ $held == "$1" ]] || { REASON="the \"Awake mode\" assertion is $held, expected $1"; return 1; }
}

# Epoch seconds of an ISO 8601 UTC time as Store writes it.
epoch() { "$DATE" -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s; }

# Retries CHECK until it passes or the step deadline passes.
step() { # number title check
  local deadline=$((SECONDS + STEP_DEADLINE))
  while :; do
    REASON=""
    if [[ $1 != 8 ]] && ! app_alive; then
      fail "$1 $2: the app is no longer running"
    fi
    if "$3"; then
      echo "PASS $1 $2"
      return 0
    fi
    if (( SECONDS >= deadline )); then
      fail "$1 $2: ${REASON:-check failed}"
    fi
    "$SLEEP" "$POLL"
  done
}

# Writes one command for the app, once it has taken the previous one.
send() { # command
  local deadline=$((SECONDS + STEP_DEADLINE))
  while [[ -e $CONTROL ]]; do
    (( SECONDS < deadline )) || fail "the app did not take the previous command from test-control"
    "$SLEEP" "$POLL"
  done
  printf '%s\n' "$1" >"$AWAKE_DIR/.test-control.tmp"
  "$MV" -f "$AWAKE_DIR/.test-control.tmp" "$CONTROL"
}

lid() { # closed|open
  AWAKE_HOME="$AWAKE_DIR" "$SIMULATE_LID" "$1" >/dev/null
}

# 1. Build and launch ---------------------------------------------------------
echo "==> Building the test build into $WORK/build"
INSOMNIA_LID_SIMULATION=1 "$BUILD_APP" --output "$WORK/build"
APP="$WORK/build/Awake.app"

"$MKDIR" -p "$AWAKE_DIR"
# Nothing on a simulated lid close may reach this Mac: no darkening, no
# mute, no frozen apps, no Low Power Mode, no battery or thermal end.
"$CAT" >"$AWAKE_DIR/config.json" <<'JSON'
{
  "lidCloseDefaultsApplied" : true,
  "darkenDisplayOnLidClose" : false,
  "muteOnLidClose" : false,
  "freezeList" : [],
  "freezeAllApps" : false,
  "lowPowerOnLidClose" : false,
  "lowPowerFloor" : 5,
  "endFloor" : 0,
  "thermalRules" : false
}
JSON

echo "==> Launching $APP with AWAKE_HOME=$AWAKE_DIR"
AWAKE_HOME="$AWAKE_DIR" AWAKE_TEST_MODE=1 "$APP/Contents/MacOS/Awake" </dev/null >"$APP_OUT" 2>&1 &
APP_PID=$!

launched() { [[ -f $APP_LOG ]] && "$GREP" -qF "awake: launched" "$APP_LOG"; }
in_test_mode() { "$GREP" -qF "awake: Test mode: " "$APP_LOG"; }
deadline=$((SECONDS + LAUNCH_DEADLINE))
until launched; do
  app_alive || fail "launch: the app exited before logging \"launched\""
  (( SECONDS < deadline )) || fail "launch: no \"launched\" in awake.log after ${LAUNCH_DEADLINE}s"
  "$SLEEP" "$POLL"
done
# Never drive a build that is not in test mode: its sleep guard is the real
# one, and a lid start would ask for the administrator password.
deadline=$((SECONDS + STEP_DEADLINE))
until in_test_mode; do
  (( SECONDS < deadline )) || fail "launch: the app is not in test mode (no \"Test mode:\" line in awake.log)"
  "$SLEEP" "$POLL"
done
echo "launched (pid $APP_PID) in test mode"

# 2. Steps --------------------------------------------------------------------
idle() { want icon off && want lidActive false && assertion gone; }
step 1 "idle: icon off, no \"Awake mode\" assertion" idle

send awake-on
awake_on() { want icon awake && want awakeOn true && assertion held; }
step 2 "awake-on: icon awake, \"Awake mode\" assertion held" awake_on

send awake-off
awake_off() { want icon off && want awakeOn false && assertion gone; }
step 3 "awake-off: icon off, assertion gone" awake_off

send "lid-start $LID_SECONDS"
lid_started() {
  want lidActive true && want lidPaused true && want icon lid && want lidHoldActive true && assertion held || return 1
  local paused
  paused=$(field "$SESSION" pausedRemaining) || { REASON="session.json has no pausedRemaining"; return 1; }
  [[ ${paused%%.*} == "$LID_SECONDS" ]] || { REASON="session.json pausedRemaining is $paused, expected $LID_SECONDS"; return 1; }
  "$GREP" -qx "disablesleep 1" "$GUARD_LOG" 2>/dev/null || { REASON="no \"disablesleep 1\" in the sleep guard log"; return 1; }
}
step 4 "lid-start $LID_SECONDS with the lid open: paused, icon lid, screen held, sleep disabled" lid_started

lid closed
lid_closed() {
  want lidPaused false && want lidHoldActive false && assertion gone || return 1
  if field "$SESSION" pausedRemaining >/dev/null; then REASON="session.json still has pausedRemaining"; return 1; fi
  local ends now off
  ends=$(field "$SESSION" endsAt) || { REASON="session.json has no endsAt"; return 1; }
  ends=$(epoch "$ends") || { REASON="session.json endsAt is not an ISO 8601 time"; return 1; }
  now=$("$DATE" +%s)
  off=$((ends - now - LID_SECONDS))
  (( off >= -15 && off <= 15 )) || { REASON="session.json endsAt is ${off}s from now+${LID_SECONDS}s"; return 1; }
}
step 5 "lid closed: clock runs, screen released, endsAt about now+${LID_SECONDS}s" lid_closed

lid open
lid_open() {
  want lidPaused true && want lidHoldActive true && assertion held || return 1
  local remaining
  remaining=$(field "$STATUS" lidRemaining) || { REASON="test-status.json has no lidRemaining"; return 1; }
  [[ $remaining =~ ^[0-9]+(\.[0-9]+)?$ ]] || { REASON="lidRemaining is $remaining, expected a number"; return 1; }
  (( ${remaining%%.*} > 0 && ${remaining%%.*} <= LID_SECONDS )) || { REASON="lidRemaining is $remaining, expected 1..$LID_SECONDS"; return 1; }
}
step 6 "lid open: paused again with at most ${LID_SECONDS}s left, screen held" lid_open

send lid-end
lid_ended() {
  want icon off && want lidActive false && assertion gone || return 1
  [[ ! -e $SESSION ]] || { REASON="session.json is still there"; return 1; }
  local last
  last=$("$TAIL" -n 1 "$GUARD_LOG" 2>/dev/null) || { REASON="no sleep guard log"; return 1; }
  [[ $last == "disablesleep 0" ]] || { REASON="the sleep guard log ends with \"$last\", expected \"disablesleep 0\""; return 1; }
}
step 7 "lid-end: icon off, no session.json, sleep restored, assertion gone" lid_ended

send quit
quit_done() {
  if app_alive; then REASON="the app is still running"; return 1; fi
  assertion gone
}
step 8 "quit: the app exits, no \"Awake mode\" assertion left" quit_done
status=0
wait "$APP_PID" || status=$?
APP_PID=""
(( status == 0 )) || fail "8 quit: the app exited with status $status"

echo "smoke test passed: 8 of 8 steps"

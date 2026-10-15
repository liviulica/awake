#!/bin/bash
# Guided check, on your own Mac, that Ember's lid-closed promise holds in
# macOS's own sleep log: with a 3-minute "Keep awake with lid closed"
# session, the Mac stays awake while the lid is closed and the timer runs,
# the session ends by its timer about 3 minutes after the lid closed, and
# macOS then goes to sleep within a minute.
#
#   scripts/real-sleep-check.sh              guided run (needs a person, a lid
#                                            and about 10 minutes)
#   scripts/real-sleep-check.sh --dry-run DIR
#                                            parse DIR/ember.log and
#                                            DIR/powerd.txt (saved excerpts,
#                                            see Tests/Fixtures/real-sleep/)
#                                            and print the verdict only
#
# Not run in CI. Task 18's checklist item 4c.
#
# Time zones: ember.log is UTC (`2026-10-14T18:03:41Z`); `log show` prints
# the Mac's local time. Both are turned into epoch seconds before they are
# compared, and every time is shown in UTC.
# The awk programs are single-quoted on purpose: $0 and $2 are awk fields.
# shellcheck disable=SC2016
set -euo pipefail

# Tools by absolute path, never through PATH; RealSleepCheckScriptTests runs
# the dry run only, so these are untouched there.
DATE=/bin/date
GREP=/usr/bin/grep
AWK=/usr/bin/awk
PMSET=/usr/bin/pmset
PGREP=/usr/bin/pgrep
LOGSHOW=/usr/bin/log
MKTEMP=/usr/bin/mktemp
RM=/bin/rm
SLEEP=/bin/sleep
APP="$HOME/Applications/Ember.app"
SUDOERS=/etc/sudoers.d/ember
SESSION_MINUTES=3
# The end must land this close to the planned length: the session clock
# counts closed-lid time only, and the lid event is debounced.
TOLERANCE_SECONDS=70
SLEEP_WITHIN_SECONDS=60
START_WAIT_SECONDS=360

if [[ -n "${EMBER_HOME:-}" ]]; then
  APP_SUPPORT="$EMBER_HOME"
  LOG_FILE="$EMBER_HOME/Logs/ember.log"
else
  APP_SUPPORT="$HOME/Library/Application Support/Ember"
  LOG_FILE="$HOME/Library/Logs/Ember/ember.log"
fi

dry_dir=""
case "${1:-}" in
  "") ;;
  --dry-run)
    if [[ $# -ne 2 ]]; then echo "usage: $0 [--dry-run DIR]" >&2; exit 2; fi
    dry_dir="$2" ;;
  -h|--help) echo "usage: $0 [--dry-run DIR]"; exit 0 ;;
  *) echo "usage: $0 [--dry-run DIR]" >&2; exit 2 ;;
esac

fail_setup() { echo "Cannot run: $*" >&2; exit 2; }

utc_epoch() { "$DATE" -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s; }
local_epoch() { "$DATE" -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s; }
utc_text() { "$DATE" -j -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; }

work=""
cleanup() { if [[ -n "$work" ]]; then "$RM" -rf "$work"; fi; }
trap cleanup EXIT

count_starts() {
  if [[ -f "$LOG_FILE" ]]; then
    local n=0
    n=$("$GREP" -c ' ember: session started' "$LOG_FILE" || true)
    echo "$n"
  else
    echo 0
  fi
}

preconditions() {
  local ok=1
  if [[ ! -d "$APP" ]]; then
    echo "  MISSING: $APP. Run scripts/install.sh first."; ok=0
  fi
  if ! "$PGREP" -x Ember >/dev/null 2>&1; then
    echo "  MISSING: Ember is not running. Open $APP and look for its icon in the menu bar."; ok=0
  fi
  if [[ ! -e "$SUDOERS" ]]; then
    echo "  MISSING: $SUDOERS. scripts/install.sh writes it (it asks for your password)."; ok=0
  fi
  if [[ -e "$APP_SUPPORT/session.json" ]]; then
    echo "  A lid session is already active. End it from the menu (Stop), then run this again."; ok=0
  fi
  local batt pct floor=10 cfg_floor=""
  batt=$("$PMSET" -g batt)
  if [[ "$batt" != *"AC Power"* ]]; then
    pct=$(echo "$batt" | "$AWK" 'match($0, /[0-9]+%/) { print substr($0, RSTART, RLENGTH - 1); exit }')
    if [[ -f "$APP_SUPPORT/config.json" ]]; then
      cfg_floor=$("$AWK" -F'[:,]' '/"endFloor"/ { gsub(/[^0-9]/, "", $2); print $2; exit }' "$APP_SUPPORT/config.json")
    fi
    if [[ -n "$cfg_floor" ]]; then floor="$cfg_floor"; fi
    if [[ -z "$pct" || "$pct" -le "$floor" ]]; then
      echo "  On battery at ${pct:-an unknown level}%, not above Ember's end floor (${floor}%). Plug in the charger."; ok=0
    fi
  fi
  if [[ $ok -eq 0 ]]; then
    echo "Preconditions not met; nothing was started." >&2
    exit 2
  fi
  echo "Preconditions: Ember installed and running, sudoers rule present, no lid session, power fine."
}

# Prints the fields the verdict needs, as `key=value` lines, from the awake
# log ($1) and the powerd excerpt ($2).
analyse() { # ember.log powerd.txt
  local window start close end_line reason req
  window=$("$AWK" '{ l[NR] = $0 } /ember: session started/ { n = NR } END { if (n) for (i = n; i <= NR; i++) print l[i] }' "$1")
  if [[ -z "$window" ]]; then fail_setup "no 'session started' line in $1"; fi
  start=$(echo "$window" | "$GREP" -m1 ' ember: session started' || true)
  close=$(echo "$window" | "$GREP" -m1 ' ember: lid closed$' || true)
  end_line=$(echo "$window" | "$GREP" -m1 ' ember: session end (' || true)
  req=$(echo "$window" | "$GREP" -m1 'session end with the lid closed: sleep requested' || true)
  reason=""
  if [[ -n "$end_line" ]]; then reason="${end_line#*session end (}"; reason="${reason%%)*}"; fi

  echo "Ember's log for this session:"
  echo "$window" | "$GREP" -E ' ember: (session |lid )' | "$AWK" '{ print "  " $0 }' || true
  echo

  S_START=$(utc_epoch "${start%% *}")
  S_CLOSE=""; S_END=""; S_REQ=""
  if [[ -n "$close" ]]; then S_CLOSE=$(utc_epoch "${close%% *}"); fi
  if [[ -n "$end_line" ]]; then S_END=$(utc_epoch "${end_line%% *}"); fi
  if [[ -n "$req" ]]; then S_REQ=$(utc_epoch "${req%% *}"); fi
  S_REASON="$reason"

  S_SLEEPS=""
  local line stamp t
  echo "macOS 'Entering Sleep' lines since the session started (local time, then UTC):"
  while IFS= read -r line; do
    case "$line" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ *) ;; *) continue ;; esac
    stamp="${line:0:19}"
    t=$(local_epoch "$stamp")
    if [[ $t -lt $S_START ]]; then continue; fi
    S_SLEEPS="$S_SLEEPS $t"
    echo "  $stamp  =  $(utc_text "$t")"
  done < <("$GREP" 'Entering Sleep' "$2" || true)
  if [[ -z "$S_SLEEPS" ]]; then echo "  (none)"; fi
  echo
}

verdict() {
  local failed=0 t
  local planned=$((SESSION_MINUTES * 60))

  if [[ -z "$S_CLOSE" ]]; then
    echo "FAIL (a) no 'lid closed' line after the session started, so there is no lid close to measure from"
    failed=1
  elif [[ -z "$S_END" ]]; then
    echo "FAIL (a) the session has not ended in the log: no 'session end (...)' line"
    failed=1
  else
    # The window opens at the session start, not at the logged lid close:
    # LidObserver logs "lid closed" only after a 2 s debounce, so a clamshell
    # sleep right at the close is stamped before that line. During a lid
    # session the screen is held while the lid is open, so any sleep from the
    # session start to the timer end is a failure.
    local early=""
    for t in $S_SLEEPS; do
      if [[ $t -ge $S_START && $t -lt $S_END ]]; then early="$early $(utc_text "$t")"; fi
    done
    if [[ -n "$early" ]]; then
      echo "FAIL (a) macOS entered sleep after the session started and before the timer ended (session start $(utc_text "$S_START"), lid closed $(utc_text "$S_CLOSE"), timer end $(utc_text "$S_END")); the lid-close log line trails the lid by about 2 s, so a sleep at the close counts:$early"
      failed=1
    else
      echo "PASS (a) no sleep while the lid was closed and the timer ran ($(utc_text "$S_START") to $(utc_text "$S_END"))"
    fi
  fi

  if [[ -z "$S_CLOSE" || -z "$S_END" ]]; then
    echo "FAIL (b) cannot measure the session length without both a lid close and a session end"
    failed=1
  else
    local gap=$((S_END - S_CLOSE)) off
    off=$((gap - planned)); if [[ $off -lt 0 ]]; then off=$((-off)); fi
    if [[ "$S_REASON" != "timer" ]]; then
      echo "FAIL (b) the session ended by '$S_REASON', not by timer, at $(utc_text "$S_END")"
      failed=1
    elif [[ $off -gt $TOLERANCE_SECONDS ]]; then
      echo "FAIL (b) the session ended by timer ${gap} s after the lid closed; expected ${planned} s +/- ${TOLERANCE_SECONDS} s"
      failed=1
    else
      echo "PASS (b) the session ended by timer ${gap} s after the lid closed (expected ${planned} s +/- ${TOLERANCE_SECONDS} s)"
    fi
  fi

  if [[ -z "$S_END" ]]; then
    echo "FAIL (c) no session end, so no sleep to look for after it"
    failed=1
  else
    local after="" late=""
    for t in $S_SLEEPS; do
      if [[ $t -ge $S_END ]]; then
        if [[ $((t - S_END)) -le $SLEEP_WITHIN_SECONDS ]]; then after="$t"; break; fi
        if [[ -z "$late" ]]; then late="$t"; fi
      fi
    done
    if [[ -n "$after" ]]; then
      echo "PASS (c) macOS slept $((after - S_END)) s after the session ended ($(utc_text "$after"))"
    elif [[ -n "$late" ]]; then
      echo "FAIL (c) macOS first slept $((late - S_END)) s after the session ended ($(utc_text "$late")); expected within ${SLEEP_WITHIN_SECONDS} s"
      failed=1
    else
      echo "FAIL (c) no 'Entering Sleep' after the session ended at $(utc_text "$S_END")"
      failed=1
    fi
    if [[ -z "$S_REQ" ]]; then
      echo "NOTE  Ember logged no 'sleep requested' line after the end (it only asks while the lid is closed)."
    fi
  fi

  echo
  if [[ $failed -eq 0 ]]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
  return $failed
}

if [[ -n "$dry_dir" ]]; then
  [[ -f "$dry_dir/ember.log" && -f "$dry_dir/powerd.txt" ]] || fail_setup "$dry_dir needs ember.log and powerd.txt"
  analyse "$dry_dir/ember.log" "$dry_dir/powerd.txt"
  verdict
  exit $?
fi

echo "Ember real-sleep check: about 10 minutes, with a real lid."
preconditions
echo
before=$(count_starts)
cat <<STEP
Step 1. In the menu bar, right-click the Ember icon, then:
          Lid tab, then the Custom... chip -> type ${SESSION_MINUTES}m -> Set
        (an install from before the fourth sudoers line also asks for your
        password at the Lid tab). Keep the lid OPEN until you have set the
        ${SESSION_MINUTES} minutes and this script says the session started.
STEP
waited=0
while [[ $(count_starts) -le $before ]]; do
  if [[ $waited -ge $START_WAIT_SECONDS ]]; then
    echo "No 'session started' line in $LOG_FILE after ${START_WAIT_SECONDS} s. Nothing to check." >&2
    exit 2
  fi
  "$SLEEP" 2
  waited=$((waited + 2))
done
echo "Session started. The ${SESSION_MINUTES}-minute timer counts only while the lid is closed."
echo
cat <<STEP
Step 2. Close the lid now and leave it closed for at least 5 minutes.
        Then open it, log in, and press Enter here.
STEP
read -r _

work=$("$MKTEMP" -d)
start_line=$("$AWK" '/ember: session started/ { l = $0 } END { print l }' "$LOG_FILE")
start_epoch=$(utc_epoch "${start_line%% *}")
show_rc=0
echo "Reading macOS's sleep log (this can take a few seconds)..."
"$LOGSHOW" show --style compact \
  --start "$("$DATE" -j -r "$start_epoch" '+%Y-%m-%d %H:%M:%S')" \
  --predicate 'process == "powerd" AND eventMessage CONTAINS "Entering Sleep"' >"$work/powerd.txt" 2>"$work/powerd.err" || show_rc=$?
if [[ $show_rc -ne 0 || ( ! -s "$work/powerd.txt" && -s "$work/powerd.err" ) ]]; then
  echo "log show failed (exit $show_rc); no verdict without macOS's sleep log:" >&2
  "$AWK" '{ print "  " $0 }' "$work/powerd.err" >&2
  exit 2
fi
echo
analyse "$LOG_FILE" "$work/powerd.txt"
verdict

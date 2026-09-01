#!/bin/bash
# Shared runner for scheduled headless Claude jobs (standup, wrapdown, pr-queue).
# A job script defines the variables below, then sources this file, which runs
# the whole job: preflight -> claude (watchdog-guarded) -> JSON parse -> retry
# once -> local notification on failure -> dashboard-compatible log markers.
#
# Required:  JOB (name), LOG (log file), PROMPT, CLAUDE_ARGS (array of flags)
# Optional:  MAX_TURNS (default 40), PREFLIGHT (function; nonzero return aborts
#            the run before claude starts — deterministic checks, e.g. gh auth)
#
# Log format (parsed by workflows-dashboard.py — keep the markers stable):
#   === YYYY-MM-DD HH:MM <job> cron start ===
#   <result text>
#   meta: cost $X · N turns · Ns · session <id>
#   === exit: N ===
#
# Exit codes: 0 ok · 1 claude error · 2 FEED FAILURE (skill refused, see the
# command's feed-check rule) · 3 preflight failed · 124 watchdog kill.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"
USAGE_LIMIT=0

notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"Claude ${JOB}\"" >/dev/null 2>&1
}

run_once() {
  local tmp rc waited=0
  tmp=$(mktemp)
  # env -u: strip nested-session guards so this also works when started from
  # inside a Claude session (no-op under launchd).
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    "$HOME/.local/bin/claude" -p "$PROMPT" \
    --output-format json --max-turns "${MAX_TURNS:-40}" \
    "${CLAUDE_ARGS[@]}" >"$tmp" 2>&1 &
  local cpid=$!
  # Watchdog: a 2026-07-08 run hung forever on stalled API connections.
  while kill -0 "$cpid" 2>/dev/null && [ "$waited" -lt 900 ]; do
    sleep 10; waited=$((waited + 10))
  done
  if kill -0 "$cpid" 2>/dev/null; then
    echo "WATCHDOG: claude ($cpid) still running after 15 min - killing"
    kill -9 "$cpid" 2>/dev/null; wait "$cpid" 2>/dev/null
    rm -f "$tmp"; return 124
  fi
  wait "$cpid"; rc=$?

  if jq -e . "$tmp" >/dev/null 2>&1; then
    local result is_err
    result=$(jq -r '.result // empty' "$tmp")
    is_err=$(jq -r '.is_error // false' "$tmp")
    [ -n "$result" ] && echo "$result"
    jq -r '"meta: cost $\((.total_cost_usd // 0) * 100 | round / 100) · \(.num_turns // 0) turns · \((.duration_ms // 0) / 1000 | round)s · session \(.session_id // "?")"' "$tmp"
    if [ "$is_err" = "true" ] && [ "$rc" -eq 0 ]; then rc=1; fi
    if [ "$rc" -ne 0 ] && echo "$result" | grep -qiE 'usage limit|rate limit|quota|exceeded'; then
      USAGE_LIMIT=1
    fi
    case "$result" in "FEED FAILURE"*) rc=2 ;; esac
  else
    cat "$tmp"  # crash output, not JSON
    [ "$rc" -eq 0 ] && rc=1
  fi
  rm -f "$tmp"
  return "$rc"
}

{
  echo "=== $(date '+%Y-%m-%d %H:%M') ${JOB} cron start ==="
  if declare -F PREFLIGHT >/dev/null && ! PREFLIGHT; then
    echo "PREFLIGHT failed - aborting before claude ran"
    notify "pre-flight check failed — nothing was written"
    echo "=== exit: 3 ==="
  else
    run_once; rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ] && [ "$USAGE_LIMIT" -eq 0 ]; then
      echo "--- first attempt failed (rc=$rc), retrying in 60s ---"
      sleep 60
      run_once; rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      if [ "$USAGE_LIMIT" -eq 1 ]; then
        notify "hit the usage limit — run skipped, no retry"
      elif [ "$rc" -eq 2 ]; then
        notify "a data feed is broken — refused to write (see log)"
      else
        notify "failed (rc=$rc) — see ~/.claude/logs/${JOB}-cron.log"
      fi
    fi
    echo "=== exit: $rc ==="
  fi
} >> "$LOG" 2>&1

# Keep the log from growing forever.
tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

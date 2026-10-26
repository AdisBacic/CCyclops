#!/bin/bash
# Runs one job headless: pre-flight -> claude (watchdog-guarded) -> JSON parse
# -> retry once -> local notification on failure -> dashboard log markers.
# launchd calls it with the job name (install.sh generates the agents from the
# JOB_* lines in config.sh). Run it yourself to test a job right now:
#
#   bash ~/.claude/scripts/run-job.sh standup
#
# Per-job settings live in the frontmatter of ~/.claude/commands/<job>.md:
#   allowed-tools  the tool allowlist — the same one the manual /<job> uses
#   max-turns      turn cap (default: MAX_TURNS in config.sh)
#   preflight      checks before claude starts: gh-auth, calendar-cache
#   add-dirs       extra folders claude may read: projects (the vault and
#                  ~/.claude are always added)
#   model          model for this job (default: MODEL in config.sh)
# Jobs run from the vault, and whatever the allowlist says, writes only land
# there: Edit/Write are denied in ~/.claude and PROJECTS_DIR.
#
# Log format (parsed by workflows-dashboard.py — keep the markers stable):
#   === YYYY-MM-DD HH:MM <job> cron start ===
#   <result text>
#   meta: cost $X · N turns · Ns · session <id>
#   === exit: N ===
#
# Exit codes: 0 ok · 1 claude error · 2 FEED FAILURE (the command refused to
# write, see its feed-check rule) · 3 pre-flight failed · 124 watchdog kill.

JOB="${1:?usage: run-job.sh <job>   (a file name from ~/.claude/commands, without .md)}"
CMD="$HOME/.claude/commands/$JOB.md"
LOG="$HOME/.claude/logs/$JOB-cron.log"
CONFIG="$HOME/.claude/ccyclops/config.sh"
USAGE_LIMIT=0

# shellcheck source=/dev/null
. "$CONFIG" 2>/dev/null || CONFIG_MISSING=1
# launchd starts jobs with a bare PATH: add Homebrew (gh, jq, icalBuddy) and
# claude's own folder, so an npm-installed claude finds its node.
PATH="$(dirname "${CLAUDE_BIN:-/usr/bin/true}"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"
export PATH

fm() {  # fm <key> — a single-line value from the command's frontmatter
  awk -v k="$1" 'NR == 1 { if ($0 != "---") exit; next }
                 $0 == "---" { exit }
                 index($0, k ":") == 1 { v = substr($0, length(k) + 2); sub(/^[ \t]+/, "", v); print v; exit }' "$CMD"
}

notify() {
  [ "${NOTIFICATIONS:-true}" = true ] || return 0
  osascript -e "display notification \"$1\" with title \"CCyclops · ${JOB}\"" >/dev/null 2>&1
}

preflight() {
  if [ -n "${CONFIG_MISSING:-}" ]; then echo "PREFLIGHT: $CONFIG missing — run ./install.sh"; return 1; fi
  if [ ! -f "$CMD" ]; then echo "PREFLIGHT: $CMD not found — is this job set to \"off\" in config.sh?"; return 1; fi
  if [ ! -x "${CLAUDE_BIN:-}" ]; then
    echo "PREFLIGHT: claude not found at '${CLAUDE_BIN:-}' — set CLAUDE_BIN in config.sh and run ./install.sh"; return 1
  fi
  cd "$VAULT" 2>/dev/null || { echo "PREFLIGHT: VAULT not found: $VAULT (config.sh)"; return 1; }
  local check
  for check in $(fm preflight); do
    case "$check" in
      gh-auth)  # catch expired GitHub auth deterministically, before burning a session
        gh auth status >/dev/null 2>&1 || { echo "PREFLIGHT: gh auth status failed — GitHub token expired? (gh auth login)"; return 1; } ;;
      calendar-cache)  # icalBuddy has Calendar access here (direct launchd child) but NOT inside claude
        "$HOME/.claude/scripts/standup-calendar.sh" --write-cache ;;
      *) echo "PREFLIGHT: unknown check '$check' in the preflight: line of $CMD"; return 1 ;;
    esac
  done
}

build_args() {
  local turns tools model deny d
  turns=$(fm max-turns | grep -E '^[0-9]+$' || echo "${MAX_TURNS:-40}")
  tools=$(fm allowed-tools | sed 's/, */,/g')
  model=$(fm model); model="${model:-${MODEL:-}}"
  ARGS=(--output-format json --max-turns "$turns" --permission-mode acceptEdits
        --add-dir "$VAULT" --add-dir "$HOME/.claude"
        --allowedTools "Skill,${tools:-Read,Write,Edit,Glob,Grep}")
  [ -z "$model" ] || ARGS+=(--model "$model")
  for d in $(fm add-dirs); do
    case "$d" in
      projects) ARGS+=(--add-dir "$PROJECTS_DIR") ;;
      vault) ;;  # always added
      *) ARGS+=(--add-dir "$d") ;;
    esac
  done
  # acceptEdits would auto-accept writes in every added dir; deny them
  # outside the vault (unless the vault lives inside one of these).
  deny=""
  for d in "$HOME/.claude" "$PROJECTS_DIR"; do
    case "$VAULT/" in "$d"/*) ;; *) deny="$deny${deny:+,}Edit(/$d/**)" ;; esac
  done
  [ -z "$deny" ] || ARGS+=(--disallowedTools "$deny")
  PROMPT="Invoke the $JOB skill now (the user-defined command named $JOB) and follow its instructions exactly. If the skill fails to load, Read $CMD, run the commands it injects (its !\`...\` lines) yourself, then follow the rest of its instructions."
}

run_once() {
  local tmp rc waited=0 limit=$(( ${WATCHDOG_MINUTES:-15} * 60 ))
  tmp=$(mktemp)
  # env -u: strip nested-session guards so this also works when started from
  # inside a Claude session (no-op under launchd).
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    "$CLAUDE_BIN" -p "$PROMPT" "${ARGS[@]}" </dev/null >"$tmp" 2>&1 &
  local cpid=$!
  # Watchdog: a 2026-07-08 run hung forever on stalled API connections.
  while kill -0 "$cpid" 2>/dev/null && [ "$waited" -lt "$limit" ]; do
    sleep 10; waited=$((waited + 10))
  done
  if kill -0 "$cpid" 2>/dev/null; then
    echo "WATCHDOG: claude ($cpid) still running after ${WATCHDOG_MINUTES:-15} min - killing"
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

mkdir -p "$(dirname "$LOG")"
FIRST_LINE=$(( $(wc -l <"$LOG" 2>/dev/null || echo 0) + 1 ))
{
  echo "=== $(date '+%Y-%m-%d %H:%M') ${JOB} cron start ==="
  if ! preflight; then
    echo "PREFLIGHT failed - aborting before claude ran"
    notify "pre-flight check failed — nothing was written"
    rc=3
  else
    build_args
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
  fi
  echo "=== exit: $rc ==="
} >> "$LOG" 2>&1

# Started by hand: show this run's log block.
[ -t 1 ] && tail -n +"$FIRST_LINE" "$LOG"
# Keep the log from growing forever.
tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
exit "$rc"

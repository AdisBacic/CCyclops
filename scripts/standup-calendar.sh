#!/bin/bash
# Calendar fetch for /standup and /wrapdown, with cache fallback.
# icalBuddy works interactively (terminal has the Calendar TCC grant) and
# directly under launchd — but NOT when spawned inside a headless claude
# session (the responsible process lacks the grant). The cron wrappers
# therefore run `--write-cache` BEFORE launching claude; this script then
# serves live data when it can, cached data when it can't.
#
# Usage: standup-calendar.sh yesterday|today|--write-cache

CACHE_DIR="$HOME/.claude/cache"
CACHE="$CACHE_DIR/standup-calendar-$(date +%Y-%m-%d).txt"
ICB=(icalBuddy -ic "__CALENDARS__"
     -npn -nc -iep "title,datetime,attendees" -po "datetime,title,attendees"
     -ps "/ — / · med: /" -b "" -eed)

fetch() {
  if [ "$1" = "yesterday" ]; then
    # On Mondays "yesterday" means last Friday.
    if [ "$(date +%u)" = "1" ]; then
      local fri; fri=$(date -v-3d '+%Y-%m-%d')
      "${ICB[@]}" eventsFrom:"$fri" to:"$fri" 2>/dev/null
    else
      "${ICB[@]}" eventsFrom:yesterday to:yesterday 2>/dev/null
    fi
  else
    "${ICB[@]}" eventsToday 2>/dev/null
  fi | grep -v "__SKIP_MEETING__" | sed -E 's/^([0-9]{4}-[0-9]{2}-[0-9]{2}|yesterday|today) at //' | sort -u
}

case "${1:-}" in
  --write-cache)
    mkdir -p "$CACHE_DIR"
    find "$CACHE_DIR" -name 'standup-calendar-*.txt' -mtime +3 -delete 2>/dev/null
    { echo "[yesterday]"; fetch yesterday; echo "[today]"; fetch today; } > "$CACHE"
    ;;
  yesterday|today)
    OUT=$(fetch "$1")
    if [ -n "$OUT" ]; then
      echo "$OUT"
    elif [ -f "$CACHE" ]; then
      sed -n "/^\[$1\]/,/^\[/p" "$CACHE" | grep -v '^\['
    else
      echo "(calendar unavailable — no live access and no cache)"
    fi
    ;;
  *)
    echo "usage: $0 yesterday|today|--write-cache" >&2; exit 1
    ;;
esac

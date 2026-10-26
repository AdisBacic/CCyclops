#!/bin/bash
# Injected-context helper for /standup: my commits per repo since yesterday
# (since Friday when run on a Monday). Lives in a script because the slash
# command permission check rejects inline commands with $-expansions.
# shellcheck source=/dev/null
. "$HOME/.claude/ccyclops/config.sh" || exit 1

SINCE="yesterday 00:00"
[ "$(date +%u)" = "1" ] && SINCE="last friday 00:00"
# "today" arg (used by /wrapdown): only today's commits.
[ "${1:-}" = "today" ] && SINCE="today 00:00"
echo "(window: --since=\"$SINCE\")"

# Fail loud: a wrong PROJECTS_DIR must not look like a quiet day.
[ -d "$PROJECTS_DIR" ] || { echo "error: PROJECTS_DIR not found: $PROJECTS_DIR (config.sh)"; exit 1; }

for d in "$PROJECTS_DIR"/*/.git; do
  [ -e "$d" ] || continue
  r=$(dirname "$d")
  e=$(git -C "$r" config user.email)
  [ -n "$e" ] || continue  # no identity: --author="" would match everyone's commits
  echo "== $(basename "$r") =="
  git -C "$r" log --all --oneline --no-merges --since="$SINCE" --author="$e" 2>/dev/null
done

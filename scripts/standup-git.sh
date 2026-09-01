#!/bin/bash
# Injected-context helper for /standup: my commits per repo since yesterday
# (since Friday when run on a Monday). Lives in a script because the slash
# command permission check rejects inline commands with $-expansions.

SINCE="yesterday 00:00"
[ "$(date +%u)" = "1" ] && SINCE="last friday 00:00"
# "today" arg (used by /wrapdown): only today's commits.
[ "${1:-}" = "today" ] && SINCE="today 00:00"
echo "(window: --since=\"$SINCE\")"

for d in "__PROJECTS_DIR__"/*/.git; do
  r=$(dirname "$d")
  e=$(git -C "$r" config user.email)
  echo "== $(basename "$r") =="
  git -C "$r" log --all --oneline --no-merges --since="$SINCE" --author="$e" 2>/dev/null
done

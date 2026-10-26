#!/bin/bash
# Injected-context helper for /weekly: my PRs merged in the last 7 days.
# Lives in a script because the slash command permission check rejects
# inline commands with $-expansions.
# shellcheck source=/dev/null
. "$HOME/.claude/ccyclops/config.sh" || exit 1

SINCE=$(date -v-7d '+%Y-%m-%d')
gh pr list -R "$MAIN_REPO" --author "@me" --state merged \
  --search "merged:>=$SINCE" --json number,title \
  --jq '.[] | "#\(.number) \(.title)"' 2>/dev/null

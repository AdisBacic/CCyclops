#!/bin/bash
# Injected-context helper for /veckan: my PRs merged in the last 7 days.
# Lives in a script because the slash command permission check rejects
# inline commands with $-expansions.

SINCE=$(date -v-7d '+%Y-%m-%d')
gh pr list -R __MAIN_REPO__ --author "@me" --state merged \
  --search "merged:>=$SINCE" --json number,title \
  --jq '.[] | "#\(.number) \(.title)"' 2>/dev/null

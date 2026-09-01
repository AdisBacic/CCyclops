#!/bin/bash
# SessionEnd hook: notify about leftover rails servers, Claude worktrees, and unpushed commits.
input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] && [ -d "$cwd" ] && cd "$cwd"

msgs=()

ports=$(lsof -nP -iTCP:3000 -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1}' | sort -u | tr '\n' ' ')
[ -n "$ports" ] && msgs+=("Server still on :3000 ($ports)")

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  wt=$(git worktree list 2>/dev/null | grep -c '\.claude/worktrees')
  [ "$wt" -gt 0 ] && msgs+=("$wt Claude worktree(s) left")
  up=$(git log --oneline @{u}..HEAD 2>/dev/null | wc -l | tr -d ' ')
  [ "${up:-0}" -gt 0 ] && msgs+=("$up unpushed commit(s) on $(git branch --show-current))")
fi

if [ ${#msgs[@]} -gt 0 ]; then
  body=$(IFS='; ' ; echo "${msgs[*]}")
  osascript -e "display notification \"${body//\"/\\\"}\" with title \"Claude Code session ended\"" 2>/dev/null
fi
exit 0

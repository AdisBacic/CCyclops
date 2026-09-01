#!/bin/bash
# SessionStart hook: if the session starts on a branch with a ticket number,
# inject that ticket's vault note (frontmatter + latest work-log entries)
# as context, so every session starts knowing the ticket's history.
# Counterpart to ticket-log.sh (SessionEnd), which writes the log.
# Must be fast — it blocks session startup. No LLM, no network.

set -u
TICKETS_DIR="__VAULT__/Workflows/Tickets"

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

[ -d "$CWD" ] || exit 0
cd "$CWD" || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

BRANCH=$(git branch --show-current 2>/dev/null)
case "$BRANCH" in
  ""|master|main|dev|production) exit 0 ;;
esac

TICKET=$(echo "$BRANCH" | grep -oE '[0-9]{4,5}' | tail -1)
if [ -n "$TICKET" ]; then
  NOTE=$(find "$TICKETS_DIR" -maxdepth 1 -name "$TICKET*.md" 2>/dev/null | head -1)
else
  SLUG=$(echo "$BRANCH" | tr '/' '-')
  NOTE=$(find "$TICKETS_DIR" -maxdepth 1 -name "$SLUG*.md" 2>/dev/null | head -1)
fi
[ -n "${NOTE:-}" ] && [ -f "$NOTE" ] || exit 0

# Frontmatter + human sections (up to Work log), then only the last 2 log
# entries — old sessions shouldn't flood the context.
HEAD_PART=$(awk '/^## Work log/{exit} {print}' "$NOTE" | head -40)
LOG_PART=""
FROM=$(grep -n '^### ' "$NOTE" | tail -2 | head -1 | cut -d: -f1)
if [ -n "$FROM" ]; then
  LOG_PART=$(printf '## Work log (latest entries)\n'; tail -n +"$FROM" "$NOTE" | head -50)
fi
CONTEXT=$(printf '%s\n\n%s' "$HEAD_PART" "$LOG_PART")

[ -n "$(echo "$CONTEXT" | tr -d '[:space:]')" ] || exit 0

BODY=$(printf 'Ticket note for this branch (%s), from the vault at %s — prior sessions on this ticket:\n\n%s' "$BRANCH" "$NOTE" "$CONTEXT")

jq -n --arg ctx "$BODY" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'
exit 0

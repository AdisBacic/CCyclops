#!/bin/bash
# SessionStart hook: if the session starts on a branch with a ticket number,
# inject that ticket's vault note (frontmatter + latest work-log entries)
# as context, so every session starts knowing the ticket's history.
# Counterpart to ticket-log.sh (SessionEnd), which writes the log.
# Must be fast — it blocks session startup. No LLM, no network.

set -u
# shellcheck source=/dev/null
. "$HOME/.claude/ccyclops/config.sh" 2>/dev/null || exit 0
# shellcheck source=scripts/ticket-lib.sh
. "$HOME/.claude/scripts/ticket-lib.sh" 2>/dev/null || exit 0

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

[ -d "$CWD" ] || exit 0
cd "$CWD" || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

BRANCH=$(ticket_branch) || exit 0
NOTE=$(ticket_note "$BRANCH")
[ -f "$NOTE" ] || exit 0

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

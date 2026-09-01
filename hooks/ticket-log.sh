#!/bin/bash
# SessionEnd hook: append a cheap work-log entry to the ticket note in the
# vault, keyed by the ticket number parsed from the git branch name.
# No LLM calls, no network — must never slow down session exit.
#
# Input (stdin): hook JSON with .cwd, .transcript_path, .reason
# Output: Workflows/Tickets/<ticket>*.md gets a "## Work log" entry appended.

set -u
VAULT="__VAULT__"
TICKETS_DIR="$VAULT/Workflows/Tickets"

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')

[ -d "$CWD" ] || exit 0
cd "$CWD" || exit 0

# Only log work in git repos, on a real feature branch.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
BRANCH=$(git branch --show-current 2>/dev/null)
case "$BRANCH" in
  ""|master|main|dev|production) exit 0 ;;
esac

REPO=$(basename "$(git rev-parse --show-toplevel)")

# Ticket number = last standalone 4-5 digit group in the branch name.
TICKET=$(echo "$BRANCH" | grep -oE '[0-9]{4,5}' | tail -1)

# Note file: prefer an existing note whose name starts with the ticket number
# (so "1234.md" renamed to "1234 Some title.md" keeps working).
mkdir -p "$TICKETS_DIR"
if [ -n "$TICKET" ]; then
  NOTE=$(find "$TICKETS_DIR" -maxdepth 1 -name "$TICKET*.md" | head -1)
  [ -n "$NOTE" ] || NOTE="$TICKETS_DIR/$TICKET.md"
else
  # No number in the branch — fall back to a note named after the branch.
  SLUG=$(echo "$BRANCH" | tr '/' '-')
  NOTE=$(find "$TICKETS_DIR" -maxdepth 1 -name "$SLUG*.md" | head -1)
  [ -n "$NOTE" ] || NOTE="$TICKETS_DIR/$SLUG.md"
fi

NOW=$(date '+%Y-%m-%d %H:%M')
TODAY=$(date '+%Y-%m-%d')

# Cheap facts about the session's work. Commits: today's, on this branch only
# (fall back to plain HEAD history if there is no master).
RANGE="master..HEAD"
git rev-parse --verify -q master >/dev/null 2>&1 || RANGE="HEAD"
COMMITS=$(git log $RANGE --oneline --since=midnight --author="$(git config user.email)" 2>/dev/null | head -5)
CHANGED=$( { git diff --name-only master...HEAD 2>/dev/null; git status --porcelain 2>/dev/null | awk '{print $2}'; } | sort -u | head -12)

# First user prompt from the transcript = what the session was about.
TOPIC=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  TOPIC=$(jq -r 'select(.type == "user") | .message.content
                 | if type == "array" then (map(select(.type == "text") | .text) | join(" ")) else . end' \
          "$TRANSCRIPT" 2>/dev/null \
          | grep -v '^\s*$' | grep -v '^<' | head -1 | cut -c1-160)
fi

# Create the note with frontmatter if it's new.
if [ ! -f "$NOTE" ]; then
  cat > "$NOTE" <<EOF
---
type: ticket
ticket: ${TICKET:-unknown}
status: active
repo: $REPO
updated: $TODAY
---

# ${TICKET:-$BRANCH}

## What it is

_(fill in)_

## Work log
EOF
else
  # Refresh the updated: field if the note has one.
  sed -i '' "s/^updated: .*/updated: $TODAY/" "$NOTE" 2>/dev/null
  # Ensure a Work log section exists to append under.
  grep -q '^## Work log' "$NOTE" || printf '\n## Work log\n' >> "$NOTE"
fi

{
  printf '\n### %s — session (%s)\n' "$NOW" "$REPO"
  printf -- '- branch: `%s`\n' "$BRANCH"
  [ -n "$TOPIC" ]   && printf -- '- topic: %s\n' "$TOPIC"
  if [ -n "$COMMITS" ]; then
    printf -- '- commits today:\n'
    echo "$COMMITS" | sed 's/^/    - `/; s/$/`/'
  fi
  if [ -n "$CHANGED" ]; then
    printf -- '- files touched:\n'
    echo "$CHANGED" | sed 's/^/    - `/; s/$/`/'
  fi
} >> "$NOTE"

exit 0

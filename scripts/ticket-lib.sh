# shellcheck shell=bash
# Shared by the ticket-context.sh (SessionStart) and ticket-log.sh (SessionEnd)
# hooks: which ticket a session's branch belongs to, and that ticket's note.
# Sourced after config.sh (VAULT, TICKET_PATTERN, IGNORE_BRANCHES), not run.

TICKETS_DIR="$VAULT/Workflows/Tickets"

# The repo's default branch: origin/HEAD, else main, else master.
default_branch() {
  local b
  if b=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); then
    echo "${b#origin/}"; return
  fi
  for b in main master; do
    if git rev-parse --verify -q "$b" >/dev/null; then echo "$b"; return; fi
  done
}

# Prints the current branch, or fails for detached HEAD, the default branch
# and IGNORE_BRANCHES — sessions there are not ticket work.
ticket_branch() {
  local branch b
  branch=$(git branch --show-current 2>/dev/null)
  [ -n "$branch" ] || return 1
  for b in ${IGNORE_BRANCHES:-} $(default_branch); do
    [ "$branch" = "$b" ] && return 1
  done
  echo "$branch"
}

# ticket_id <branch> — last TICKET_PATTERN match in the branch name, if any.
ticket_id() {
  local pattern="${TICKET_PATTERN:-}"
  [ -n "$pattern" ] || pattern='[0-9]{4,5}'  # not ${..:-[0-9]{4,5}}: the first } would end it
  echo "$1" | grep -oE "$pattern" | tail -1
}

# ticket_note <branch> — the note for this branch (it may not exist yet).
# Named after the ticket number, else the branch; "1234.md" renamed to
# "1234 Some title.md" keeps matching.
ticket_note() {
  local key note
  key=$(ticket_id "$1")
  [ -n "$key" ] || key=$(echo "$1" | tr '/' '-')
  note=$(find "$TICKETS_DIR" -maxdepth 1 \( -name "$key.md" -o -name "$key *.md" \) 2>/dev/null | head -1)
  echo "${note:-$TICKETS_DIR/$key.md}"
}

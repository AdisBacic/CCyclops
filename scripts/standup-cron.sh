#!/bin/bash
# Runs /standup headless — invoked by launchd weekday mornings at 09:00
# (~/Library/LaunchAgents/__PREFIX__.claude-standup.plist).
# Writes the daily note into the vault so it's ready before your daily standup.
# Watchdog/retry/JSON parsing/notifications live in job-lib.sh.
#
# NOTE: "/standup" as the -p prompt exits with 0 turns (slash commands
# don't expand in print mode) — asking the model to invoke the skill works.

JOB=standup
LOG="$HOME/.claude/logs/standup-cron.log"
MAX_TURNS=50
PROMPT="Invoke the standup skill now (the user-defined command named standup) and follow its instructions exactly. If the skill fails to load, Read __HOME__/.claude/commands/standup.md, run the commands from its 'Injected context' section yourself, then follow its Task section."
CLAUDE_ARGS=(
  --add-dir "__VAULT__"
  --add-dir "__HOME__/.claude"
  --permission-mode acceptEdits
  --allowedTools "Skill,Read,Write,Edit,Glob,Grep,Bash(date:*),Bash(find:*),Bash(ls:*),Bash(icalBuddy:*),Bash(git -C:*),Bash(gh pr list:*),Bash(gh pr view:*),Bash(gh issue view:*),Bash(__HOME__/.claude/scripts/standup-git.sh),Bash(__HOME__/.claude/scripts/standup-calendar.sh:*)"
)

PREFLIGHT() {
  cd "__MAIN_REPO_DIR__" || return 1
  # Catch expired GitHub auth deterministically, before burning a session.
  if ! gh auth status >/dev/null 2>&1; then
    echo "PREFLIGHT: gh auth status failed — GitHub token expired?"
    return 1
  fi
  # Pre-fetch calendar to cache: icalBuddy has Calendar access here (direct
  # launchd child) but NOT inside the claude session it spawns.
  "$HOME/.claude/scripts/standup-calendar.sh" --write-cache
  return 0
}

source "$HOME/.claude/scripts/job-lib.sh"

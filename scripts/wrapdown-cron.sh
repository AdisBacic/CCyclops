#!/bin/bash
# Runs /wrapdown headless — invoked by launchd weekday evenings at 17:30
# (~/Library/LaunchAgents/__PREFIX__.claude-wrapdown.plist).
# Appends the evening Wrap-up section to today's daily note in the vault.
# Watchdog/retry/JSON parsing/notifications live in job-lib.sh.

JOB=wrapdown
LOG="$HOME/.claude/logs/wrapdown-cron.log"
MAX_TURNS=50
PROMPT="Invoke the wrapdown skill now (the user-defined command named wrapdown) and follow its instructions exactly. If the skill fails to load, Read __HOME__/.claude/commands/wrapdown.md, run the commands from its 'Injected context' section yourself, then follow its Task section."
CLAUDE_ARGS=(
  --add-dir "__VAULT__"
  --add-dir "__HOME__/.claude"
  --permission-mode acceptEdits
  --allowedTools "Skill,Read,Write,Edit,Glob,Grep,Bash(date:*),Bash(find:*),Bash(ls:*),Bash(icalBuddy:*),Bash(git -C:*),Bash(gh pr list:*),Bash(gh pr view:*),Bash(gh issue view:*),Bash(__HOME__/.claude/scripts/standup-git.sh:*),Bash(__HOME__/.claude/scripts/standup-calendar.sh:*)"
)

PREFLIGHT() {
  cd "__MAIN_REPO_DIR__" || return 1
  if ! gh auth status >/dev/null 2>&1; then
    echo "PREFLIGHT: gh auth status failed — GitHub token expired?"
    return 1
  fi
  # Refresh today's calendar cache (live icalBuddy works here, not inside claude).
  "$HOME/.claude/scripts/standup-calendar.sh" --write-cache
  return 0
}

source "$HOME/.claude/scripts/job-lib.sh"

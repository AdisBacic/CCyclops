#!/bin/bash
# Runs /pr-queue headless — invoked by launchd weekday mornings at 08:40
# (~/Library/LaunchAgents/__PREFIX__.claude-pr-queue.plist), 20 min before
# the standup job so the daily note can wikilink the fresh pre-review notes.
# Read-only against GitHub; writes severity-filtered pre-review notes into
# the vault. Watchdog/retry/JSON parsing/notifications live in job-lib.sh.

JOB=pr-queue
LOG="$HOME/.claude/logs/pr-queue-cron.log"
MAX_TURNS=60
PROMPT="Invoke the pr-queue skill now (the user-defined command named pr-queue) and follow its instructions exactly. If the skill fails to load, Read __HOME__/.claude/commands/pr-queue.md, run the commands from its 'Injected context' section yourself, then follow its Task section."
CLAUDE_ARGS=(
  --add-dir "__VAULT__"
  --add-dir "__HOME__/.claude"
  --add-dir "__PROJECTS_DIR__"
  --permission-mode acceptEdits
  --allowedTools "Skill,Read,Write,Edit,Glob,Grep,Bash(date:*),Bash(ls:*),Bash(find:*),Bash(gh search:*),Bash(gh pr list:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(git -C:*)"
)

PREFLIGHT() {
  cd "__MAIN_REPO_DIR__" || return 1
  if ! gh auth status >/dev/null 2>&1; then
    echo "PREFLIGHT: gh auth status failed — GitHub token expired?"
    return 1
  fi
  return 0
}

source "$HOME/.claude/scripts/job-lib.sh"

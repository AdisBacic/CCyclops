# shellcheck shell=bash disable=SC2034
# Claude Workflows — the one file you edit.
#
# ./install.sh copies this to config.sh on first run (config.sh is gitignored).
# Change any value there, then run ./install.sh again to apply it. Re-running
# is always safe. Plain bash: quote values, $HOME works, # starts a comment.

# ── Where things live ────────────────────────────────────────────────────────
VAULT="$HOME/Notes"                       # notes are written to $VAULT/Workflows/
PROJECTS_DIR="$HOME/Projects"             # folder that contains your git repos
MAIN_REPO="your-org/your-repo"            # owner/name: PR feeds for standup/wrapdown/weekly
MAIN_REPO_DIR="$PROJECTS_DIR/your-repo"   # local clone of MAIN_REPO (jobs run from here)
GITHUB_ORG="your-org"                     # org scanned for PRs awaiting your review

# ── Jobs ─────────────────────────────────────────────────────────────────────
# One line per file in commands/ (JOB_<FILE NAME>). The value is a schedule,
# "manual" (slash command only, never scheduled) or "off" (not installed).
#   "weekdays 09:00"   "daily 07:30"   "mon,wed,fri 16:00"   "weekends 10:00"
#   "weekdays 09:00 13:00" (several times a day)   "every 30m"   "every 2h"
# A command without a line here is installed as "manual".
JOB_PR_QUEUE="weekdays 08:40"             # pre-review PRs awaiting your review
JOB_STANDUP="weekdays 09:00"              # write today's daily note + team standup
JOB_WRAPDOWN="weekdays 17:30"             # append the evening wrap-up
JOB_WEEKLY="manual"                       # fold the week's dailies into one note
JOB_CATCHUP="manual"                      # re-orient on the current feature branch

# ── Features (true / false) ──────────────────────────────────────────────────
DASHBOARD=true                 # always-on dashboard + "Claude Workflows" Dock/Spotlight app
CALENDAR=true                  # meeting feeds from icalBuddy (brew install ical-buddy)
NOTIFICATIONS=true             # macOS notification when a scheduled job fails
# Session hooks — one line per file in hooks/ (HOOK_<FILE NAME>).
HOOK_TICKET_CONTEXT=true       # session start: load the ticket note for this branch
HOOK_TICKET_LOG=true           # session end: append a work-log entry to the ticket note
HOOK_SESSION_END_CHECK=true    # session end: warn about running servers, worktrees, unpushed commits

# ── Calendar ─────────────────────────────────────────────────────────────────
CALENDARS="you@example.com"    # icalBuddy calendar names, comma-separated
SKIP_MEETING="Daily Standup"   # recurring meeting left out of notes ("" keeps everything)

# ── Writing ──────────────────────────────────────────────────────────────────
LANGUAGE="English"             # language of the notes and the copy-paste team standup

# ── Tickets & branches ───────────────────────────────────────────────────────
TICKET_PATTERN="[0-9]{4,5}"    # extended regex for the ticket number in a branch name
IGNORE_BRANCHES="main master dev develop production"  # never logged as ticket work

# ── Session-end check ────────────────────────────────────────────────────────
DEV_SERVER_PORTS="3000"        # warn if something still listens here, e.g. "3000 5173" ("" = off)

# ── Runner & dashboard ───────────────────────────────────────────────────────
MAX_TURNS=40                   # turn cap per job (a command can set its own max-turns:)
WATCHDOG_MINUTES=15            # kill a job that runs longer than this
DASHBOARD_PORT=8787
LAUNCHD_PREFIX="com.$(whoami)" # launchd labels become <prefix>.claude-<job>
CLAUDE_BIN=""                  # path to claude; empty = found automatically at install

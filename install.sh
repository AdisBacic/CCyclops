#!/bin/bash
# Claude Workflows installer.
# Copies commands/scripts/hooks/launchd agents into place, filling in your
# personal values (vault path, GitHub org, calendars, ...) where the repo
# files carry __TOKEN__ placeholders. Safe to re-run: it overwrites the
# machinery but never your quotes, favicon, notes, or logs.
#
# Usage:  ./install.sh            interactive install
#         ./install.sh --dry-run  show what would happen, change nothing
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

say()  { printf '\033[32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*"; }
run()  { if [ "$DRY" = 1 ]; then echo "  [dry] $*"; else "$@"; fi; }

# ---------------------------------------------------------------- prerequisites
say "Checking dependencies"
missing=0
for dep in claude gh jq python3; do
  if command -v "$dep" >/dev/null; then
    echo "  ok: $dep ($(command -v "$dep"))"
  else
    echo "  MISSING: $dep"; missing=1
  fi
done
python3 - <<'EOF' || { echo "  MISSING: python3 >= 3.10"; missing=1; }
import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)
EOF
[ "$missing" = 1 ] && { echo "Install the missing dependencies first (see README)."; exit 1; }
command -v icalBuddy >/dev/null || warn "icalBuddy not found — calendar feeds will be empty (optional; brew install ical-buddy)"
gh auth status >/dev/null 2>&1 || warn "gh is not authenticated — run 'gh auth login' before the first scheduled run"

# ---------------------------------------------------------------- configuration
ask() {  # ask "Question" default -> REPLY
  local q="$1" d="$2"
  read -r -p "$q [$d]: " REPLY </dev/tty 2>/dev/null || REPLY=""
  REPLY="${REPLY:-$d}"
}

say "Configuration (Enter accepts the default)"
ask "Obsidian vault / notes directory (created if missing)" "$HOME/Notes"
VAULT="${REPLY/#\~/$HOME}"
ask "Directory containing your git repos" "$HOME/Projects"
PROJECTS_DIR="${REPLY/#\~/$HOME}"
ask "Your main repo as org/name (for PR feeds)" "your-org/your-repo"
MAIN_REPO="$REPLY"
ask "Local working copy of that repo" "$PROJECTS_DIR/$(basename "$MAIN_REPO")"
MAIN_REPO_DIR="${REPLY/#\~/$HOME}"
ask "GitHub org to scan for PRs awaiting your review" "${MAIN_REPO%%/*}"
GITHUB_ORG="$REPLY"
ask "icalBuddy calendar names, comma-separated (email calendar works)" "you@example.com"
CALENDARS="$REPLY"
ask "Recurring daily meeting to filter out of notes" "Daily Standup"
SKIP_MEETING="$REPLY"
ask "launchd label prefix" "com.$(whoami)"
PREFIX="$REPLY"
PYTHON3="$(command -v python3)"

fill() {  # fill <src> <dst> — copy with tokens replaced
  run mkdir -p "$(dirname "$2")"
  if [ "$DRY" = 1 ]; then echo "  [dry] install $1 -> $2"; return; fi
  sed -e "s|__HOME__|$HOME|g" \
      -e "s|__VAULT__|$VAULT|g" \
      -e "s|__PROJECTS_DIR__|$PROJECTS_DIR|g" \
      -e "s|__MAIN_REPO_DIR__|$MAIN_REPO_DIR|g" \
      -e "s|__MAIN_REPO__|$MAIN_REPO|g" \
      -e "s|__GITHUB_ORG__|$GITHUB_ORG|g" \
      -e "s|__CALENDARS__|$CALENDARS|g" \
      -e "s|__SKIP_MEETING__|$SKIP_MEETING|g" \
      -e "s|__PREFIX__|$PREFIX|g" \
      -e "s|__PYTHON3__|$PYTHON3|g" \
      "$1" > "$2"
}

# --------------------------------------------------------------------- install
say "Installing commands -> ~/.claude/commands/"
for f in "$REPO_DIR"/commands/*.md; do fill "$f" "$HOME/.claude/commands/$(basename "$f")"; done

say "Installing scripts -> ~/.claude/scripts/"
for f in "$REPO_DIR"/scripts/*.sh "$REPO_DIR"/scripts/*.py; do
  fill "$f" "$HOME/.claude/scripts/$(basename "$f")"
  run chmod +x "$HOME/.claude/scripts/$(basename "$f")"
done
# Quotes and favicon are personal — install only when absent, never overwrite.
for f in workflows-quotes.json workflows-favicon.png; do
  if [ ! -f "$HOME/.claude/scripts/$f" ]; then
    run cp "$REPO_DIR/scripts/$f" "$HOME/.claude/scripts/$f"
  else
    echo "  keeping existing $f"
  fi
done

say "Installing hooks -> ~/.claude/hooks/"
for f in "$REPO_DIR"/hooks/*.sh; do
  fill "$f" "$HOME/.claude/hooks/$(basename "$f")"
  run chmod +x "$HOME/.claude/hooks/$(basename "$f")"
done

say "Registering hooks in ~/.claude/settings.json"
SETTINGS="$HOME/.claude/settings.json"
if [ "$DRY" = 1 ]; then
  echo "  [dry] merge SessionStart/SessionEnd hooks into $SETTINGS"
else
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  jq --arg h "$HOME" '
    def ensure(ev; cmds):
      .hooks[ev] = ((.hooks[ev] // []) as $groups
        | (cmds - ([$groups[].hooks[]?.command])) as $new
        | if ($new | length) == 0 then $groups
          else $groups + [{hooks: ($new | map({type: "command", command: ., timeout: 15}))}] end);
    .hooks = (.hooks // {})
    | ensure("SessionStart"; [$h + "/.claude/hooks/ticket-context.sh"])
    | ensure("SessionEnd";   [$h + "/.claude/hooks/session-end-check.sh",
                              $h + "/.claude/hooks/ticket-log.sh"])
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
fi

say "Installing dashboard launcher -> ~/.local/bin/workflows"
fill "$REPO_DIR/bin/workflows" "$HOME/.local/bin/workflows"
run chmod +x "$HOME/.local/bin/workflows"

say "Building Claude Workflows.app -> ~/Applications/"
APP="$HOME/Applications/Claude Workflows.app"
run mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
fill "$REPO_DIR/app/Info.plist" "$APP/Contents/Info.plist"
fill "$REPO_DIR/app/launcher" "$APP/Contents/MacOS/launcher"
run chmod +x "$APP/Contents/MacOS/launcher"
run cp "$REPO_DIR/app/icon.icns" "$APP/Contents/Resources/app.icns"

say "Installing launchd agents -> ~/Library/LaunchAgents/"
run mkdir -p "$HOME/.claude/logs" "$HOME/.claude/cache" "$VAULT/Workflows"
for f in "$REPO_DIR"/launchd/__PREFIX__.*.plist; do
  dst="$HOME/Library/LaunchAgents/$(basename "${f/__PREFIX__/$PREFIX}")"
  fill "$f" "$dst"
done

if [ "$DRY" = 1 ]; then
  echo "  [dry] launchctl bootstrap the four agents"
else
  read -r -p "Load the launchd agents now? [Y/n]: " yn </dev/tty || yn=Y
  if [ "${yn:-Y}" != "n" ] && [ "${yn:-Y}" != "N" ]; then
    for name in standup wrapdown pr-queue workflows; do
      launchctl bootout "gui/$(id -u)/$PREFIX.claude-$name" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$PREFIX.claude-$name.plist" \
        && echo "  loaded $PREFIX.claude-$name"
    done
  fi
fi

say "Done"
cat <<EOF

Next steps:
  1. gh auth login                      (if the check above warned about it)
  2. workflows                          (opens the dashboard app window)
  3. bash ~/.claude/scripts/standup-cron.sh   (test a job right now)
  4. Grant Calendar access: run 'icalBuddy eventsToday' once in Terminal and
     approve the prompt — the scheduled jobs inherit that grant via launchd.
  5. Optional Dock icon:
     defaults write com.apple.dock persistent-apps -array-add '<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$APP</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>' && killall Dock

Schedules: pr-queue weekdays 08:40 · standup 09:00 · wrapdown 17:30.
Edit the plists in ~/Library/LaunchAgents to change them.
EOF

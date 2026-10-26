#!/bin/bash
# CCyclops installer — applies config.sh to this Mac.
#
#   ./install.sh                install or update from config.sh (the first run
#                               asks a few questions and writes config.sh)
#   ./install.sh --dry-run      show what would change, change nothing
#   ./install.sh --reconfigure  ask the setup questions again, then install
#   ./install.sh --uninstall    remove everything the installer put in place
#                               (add --yes to skip the confirmation)
#
# config.sh is the only file you edit; re-running is always safe. Machinery is
# replaced, your notes, logs, quotes and favicon are never touched. Set
# CCYCLOPS_CONFIG=/path/to/config.sh to keep the config somewhere else.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
EXAMPLE="$REPO_DIR/config.example.sh"
CONFIG="${CCYCLOPS_CONFIG:-$REPO_DIR/config.sh}"
HELPER="$REPO_DIR/tools/ccyclops.py"
CLAUDE_DIR="$HOME/.claude"
INSTALLED_CONFIG="$CLAUDE_DIR/ccyclops/config.sh"
AGENTS="$HOME/Library/LaunchAgents"
APP="$HOME/Applications/CCyclops.app"
LAUNCHER="$HOME/.local/bin/ccyclops"
GUI="gui/$(id -u)"
# Files earlier layouts installed in ~/.claude, removed on upgrade.
LEGACY="scripts/job-lib.sh scripts/standup-cron.sh scripts/wrapdown-cron.sh scripts/pr-queue-cron.sh
        scripts/veckan-prs.sh scripts/weekly-prs.sh scripts/make_icon.py scripts/mask_icon.py commands/veckan.md"

DRY=0 MODE=install YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --reconfigure) MODE=reconfigure ;;
    --uninstall) MODE=uninstall ;;
    --yes) YES=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (see ./install.sh --help)" >&2; exit 1 ;;
  esac
done
HAVE_TTY=0  # CCYCLOPS_NONINTERACTIVE=1: never ask (scripted installs, tests)
[ -n "${CCYCLOPS_NONINTERACTIVE:-}" ] || { { : </dev/tty; } 2>/dev/null && HAVE_TTY=1; }

say()    { printf '\033[32m==>\033[0m %s\n' "$*"; }
warn()   { printf '\033[33mwarn:\033[0m %s\n' "$*"; }
pretty() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }
helper() { python3 "$HELPER" "$@"; }
var()    { local v="${!1-}"; printf '%s' "${v:-${2-}}"; }  # config value $1, else default $2
# key_for JOB pr-queue -> JOB_PR_QUEUE (tools/ccyclops.py flag_key does the same)
key_for() { printf '%s_%s' "$1" "$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"; }

# put <tmp> <dst> [mode] — move a freshly generated file into place if it
# differs from what's there. Sets CHANGED=1 when it did (or would, dry).
put() {
  CHANGED=0
  if cmp -s "$1" "$2"; then rm -f "$1"; return 0; fi
  CHANGED=1
  local verb=update; [ -e "$2" ] || verb=create
  if [ "$DRY" = 1 ]; then rm -f "$1"; echo "  [dry] $verb $(pretty "$2")"; return 0; fi
  mkdir -p "$(dirname "$2")"
  mv "$1" "$2"; chmod "${3:-644}" "$2"
  echo "  ${verb}d $(pretty "$2")"
}
copy()   { local t; t=$(mktemp); cp "$1" "$t"; put "$t" "$2" "${3:-644}"; }
render() { local t; t=$(mktemp); helper render "$1" "$t"; put "$t" "$2" "${3:-644}"; }
remove() {  # remove <path>... — delete things this installer owns, reporting each
  local p
  for p in "$@"; do
    [ -e "$p" ] || continue
    if [ "$DRY" = 1 ]; then echo "  [dry] remove $(pretty "$p")"; else rm -rf "$p"; echo "  removed $(pretty "$p")"; fi
  done
}

# ----------------------------------------------------------------------- launchd
label()       { printf '%s.claude-%s' "$LAUNCHD_PREFIX" "$1"; }
agent_plist() { printf '%s/%s.plist' "$AGENTS" "$(label "$1")"; }
is_loaded()   { launchctl print "$GUI/$(label "$1")" >/dev/null 2>&1; }
load_agent() {  # (re)load when its plist just changed or it isn't loaded
  if [ "$CHANGED" = 0 ] && is_loaded "$1"; then return 0; fi
  if [ "$DRY" = 1 ]; then echo "  [dry] load $(label "$1")"; return 0; fi
  launchctl bootout "$GUI/$(label "$1")" 2>/dev/null || true
  launchctl bootstrap "$GUI" "$(agent_plist "$1")"
}
unload_agent() {
  [ -f "$(agent_plist "$1")" ] || return 0
  [ "$DRY" = 1 ] || launchctl bootout "$GUI/$(label "$1")" 2>/dev/null || true
  remove "$(agent_plist "$1")"
}

legacy_paths() {  # what earlier layouts left behind, one path per line
  local rel
  for rel in $LEGACY; do
    if [ -e "$CLAUDE_DIR/$rel" ]; then printf '%s\n' "$CLAUDE_DIR/$rel"; fi
  done
  # The app and launcher were "Claude Workflows.app" and "workflows" — remove them only if they're ours.
  if grep -qs claude-workflows-app "$HOME/Applications/Claude Workflows.app/Contents/Info.plist"; then
    printf '%s\n' "$HOME/Applications/Claude Workflows.app"
  fi
  if grep -qs workflows-dashboard.py "$HOME/.local/bin/workflows"; then printf '%s\n' "$HOME/.local/bin/workflows"; fi
  return 0
}

# ----------------------------------------------------------------- session hooks
hook_event() { sed -n '2s/^# \([A-Za-z]*\) hook:.*/\1/p' "$1"; }  # "# SessionEnd hook: ..."

# sync_hooks <enabled-json> — make settings.json register exactly the enabled
# hooks of ours ([{event, command}]), leaving everyone else's hooks alone.
sync_hooks() {
  local settings="$CLAUDE_DIR/settings.json" current='{}' all="[]" f tmp
  for f in "$REPO_DIR"/hooks/*.sh; do
    all=$(jq -c --arg c "$CLAUDE_DIR/hooks/$(basename "$f")" '. + [$c]' <<<"$all")
  done
  if [ -f "$settings" ]; then
    current=$(cat "$settings")
  elif [ "$1" = "[]" ]; then
    return 0
  fi
  tmp=$(mktemp)
  jq --argjson on "$1" --argjson ours "$all" '
    def strip: map(.hooks |= map(select(.command as $c | [$ours[] | select(. == $c)] | length == 0)))
               | map(select(.hooks | length > 0));
    .hooks = ((.hooks // {}) | with_entries(.value |= strip))
    | reduce ($on | group_by(.event))[] as $g (.;
        .hooks[$g[0].event] += [{hooks: ($g | map({type: "command", command: .command, timeout: 15}))}])
    | .hooks |= with_entries(select(.value | length > 0))
    | if .hooks == {} then del(.hooks) else . end
  ' <<<"$current" > "$tmp" || { rm -f "$tmp"; echo "$(pretty "$settings") is not valid JSON — fix it and run again." >&2; exit 1; }
  if [ -f "$settings" ] && [ "$(jq -S . "$settings")" = "$(jq -S . "$tmp")" ]; then rm -f "$tmp"; return 0; fi
  if [ "$DRY" = 1 ]; then rm -f "$tmp"; echo "  [dry] update hooks in $(pretty "$settings")"; return 0; fi
  mv "$tmp" "$settings"; echo "  updated hooks in $(pretty "$settings")"
}

# ------------------------------------------------------------------------ config
load_config() {  # defaults from config.example.sh, overridden by config.sh
  set -a
  # shellcheck source=config.example.sh
  . "$EXAMPLE"
  # shellcheck source=/dev/null
  if [ -f "${1:-$CONFIG}" ]; then . "${1:-$CONFIG}"; fi
  set +a
}

ask() {  # ask VAR "Question" — Enter keeps the current value
  local cur="${!1-}" reply=""
  printf '  %s [%s]: ' "$2" "$(pretty "$cur")" >&2
  IFS= read -r reply </dev/tty || reply=""
  [ -n "$reply" ] || reply="$cur"
  printf -v "$1" '%s' "${reply/#\~/$HOME}"
}

# shellcheck disable=SC2034  # the answers are read by tools/ccyclops.py from the environment
configure() {  # the setup questions; answers go into config.sh
  local base="$EXAMPLE"
  [ ! -f "$CONFIG" ] || base="$CONFIG"
  say "Setup — Enter keeps the value in [brackets]. Everything else is in $(pretty "$CONFIG")."
  ask VAULT "Notes folder (Obsidian vault or any folder; created if missing)"
  ask PROJECTS_DIR "Folder that contains your git clones"
  ask GITHUB_SCOPE "Where your PRs live (org:acme, or repo:acme/shop repo:acme/api)"
  if command -v icalBuddy >/dev/null; then
    ask CALENDARS "icalBuddy calendar names, comma-separated (an email calendar works)"
    ask SKIP_MEETING "Recurring meeting to leave out of notes"
  else
    CALENDAR=false
    echo "  icalBuddy isn't installed, so CALENDAR=false (brew install ical-buddy, then set it to true)"
  fi
  ask LANGUAGE "Language the notes are written in"
  if [ "$DRY" = 1 ]; then echo "  [dry] write $(pretty "$CONFIG")"; return 0; fi
  helper write-config "$base" "$CONFIG" VAULT PROJECTS_DIR GITHUB_SCOPE CALENDAR CALENDARS SKIP_MEETING LANGUAGE
  echo "  wrote $(pretty "$CONFIG")"
}

[ "$(uname -s)" = Darwin ] || { echo "CCyclops needs macOS (it schedules jobs with launchd)." >&2; exit 1; }
command -v jq >/dev/null || { echo "MISSING: jq (brew install jq)" >&2; exit 1; }
command -v python3 >/dev/null || { echo "MISSING: python3 (brew install python3)" >&2; exit 1; }
export CCYCLOPS_EXAMPLE="$EXAMPLE" CCYCLOPS_CONFIG="$CONFIG"

# --------------------------------------------------------------------- uninstall
if [ "$MODE" = uninstall ]; then
  # What is installed wins over config.sh, which may have changed since.
  if [ -f "$INSTALLED_CONFIG" ]; then load_config "$INSTALLED_CONFIG"; else load_config; fi
  if [ "$DRY" = 0 ] && [ "$YES" = 0 ] && [ "$HAVE_TTY" = 1 ]; then
    printf 'Remove CCyclops from this Mac? Notes, logs and quotes stay. [y/N]: ' >&2
    read -r yn </dev/tty || yn=""
    case "$yn" in y|Y|yes) ;; *) echo "Nothing removed."; exit 0 ;; esac
  fi
  say "Removing launchd agents, commands and the app"
  for f in "$REPO_DIR"/commands/*.md; do
    unload_agent "$(basename "$f" .md)"
    remove "$CLAUDE_DIR/commands/$(basename "$f")"
  done
  unload_agent workflows
  remove "$APP" "$LAUNCHER"
  say "Unregistering session hooks"
  sync_hooks "[]"
  for f in "$REPO_DIR"/hooks/*.sh; do remove "$CLAUDE_DIR/hooks/$(basename "$f")"; done
  say "Removing scripts"
  for f in "$REPO_DIR"/scripts/*.sh "$REPO_DIR"/scripts/*.py; do remove "$CLAUDE_DIR/scripts/$(basename "$f")"; done
  while IFS= read -r p; do remove "$p"; done <<<"$(legacy_paths)"
  remove "$CLAUDE_DIR/ccyclops"
  say "Done"
  echo "Left in place: your notes in $(pretty "$VAULT")/Workflows/, ~/.claude/scripts/workflows-quotes.json,"
  echo "workflows-favicon.png, run logs in ~/.claude/logs and the calendar cache in ~/.claude/cache."
  exit 0
fi

# ------------------------------------------------------------------ prerequisites
say "Checking dependencies"
missing=0
for dep in gh jq python3; do
  if command -v "$dep" >/dev/null; then echo "  ok: $dep"; else echo "  MISSING: $dep"; missing=1; fi
done
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || { echo "  MISSING: python3 >= 3.10"; missing=1; }
[ "$missing" = 0 ] || { echo "Install the missing dependencies first (see README)."; exit 1; }
gh auth status >/dev/null 2>&1 || warn "gh is not authenticated — run 'gh auth login' before the first scheduled run"

# ------------------------------------------------------------------------ config
load_config
FIRST_RUN=0
if [ ! -f "$CONFIG" ] || [ "$MODE" = reconfigure ]; then
  [ -f "$CONFIG" ] || FIRST_RUN=1
  if [ "$HAVE_TTY" = 1 ]; then
    configure
  elif [ "$FIRST_RUN" = 1 ]; then
    if [ "$DRY" = 1 ]; then
      echo "  [dry] create $(pretty "$CONFIG") from config.example.sh (no terminal to ask in)"
    else
      cp "$EXAMPLE" "$CONFIG"
      say "Wrote $(pretty "$CONFIG") with the defaults — edit it, then run ./install.sh again."
      exit 0
    fi
  else
    warn "--reconfigure needs a terminal to ask in — installing $(pretty "$CONFIG") as it is"
  fi
  [ "$DRY" = 1 ] || load_config
fi

CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || true)}"
PYTHON3="$(command -v python3)"
CCYCLOPS_REPO="$REPO_DIR"
export CLAUDE_BIN PYTHON3 CCYCLOPS_REPO

say "Checking $(pretty "$CONFIG")"
helper check "$REPO_DIR/commands" "$REPO_DIR/hooks" || { echo "Fix the errors above and run ./install.sh again — nothing was changed."; exit 1; }

say "Config -> $(pretty "$INSTALLED_CONFIG")"
t=$(mktemp); helper resolved "$t"; put "$t" "$INSTALLED_CONFIG"
[ "$DRY" = 1 ] || mkdir -p "$CLAUDE_DIR/logs" "$CLAUDE_DIR/cache" "$VAULT/Workflows"

say "Scripts -> ~/.claude/scripts/"
for f in "$REPO_DIR"/scripts/*.sh "$REPO_DIR"/scripts/*.py; do
  copy "$f" "$CLAUDE_DIR/scripts/$(basename "$f")" 755
done
# Quotes and favicon are personal — install only when absent, never overwrite.
for f in workflows-quotes.json workflows-favicon.png; do
  [ -f "$CLAUDE_DIR/scripts/$f" ] || copy "$REPO_DIR/scripts/$f" "$CLAUDE_DIR/scripts/$f"
done

say "Session hooks -> ~/.claude/hooks/"
enabled="[]" hook_names=""
for f in "$REPO_DIR"/hooks/*.sh; do
  name=$(basename "$f" .sh); event=$(hook_event "$f")
  if [ -z "$event" ]; then warn "hooks/$name.sh: line 2 must read '# <Event> hook: ...' — skipped"; continue; fi
  if [ "$(var "$(key_for HOOK "$name")" true)" = true ]; then
    copy "$f" "$CLAUDE_DIR/hooks/$name.sh" 755
    enabled=$(jq -c --arg e "$event" --arg c "$CLAUDE_DIR/hooks/$name.sh" '. + [{event: $e, command: $c}]' <<<"$enabled")
    hook_names="$hook_names${hook_names:+, }$name"
  else
    remove "$CLAUDE_DIR/hooks/$name.sh"
  fi
done
sync_hooks "$enabled"

say "Commands and jobs -> ~/.claude/commands/, ~/Library/LaunchAgents/"
summary=""
for f in "$REPO_DIR"/commands/*.md; do
  name=$(basename "$f" .md)
  mode=$(var "$(key_for JOB "$name")" manual)
  case "$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')" in
    off)
      mode=off
      unload_agent "$name"
      remove "$CLAUDE_DIR/commands/$name.md" ;;
    manual)
      mode="manual (/$name)"
      render "$f" "$CLAUDE_DIR/commands/$name.md"
      unload_agent "$name" ;;
    *)
      render "$f" "$CLAUDE_DIR/commands/$name.md"
      t=$(mktemp); helper plist "$name" "$mode" "$t"; put "$t" "$(agent_plist "$name")"
      load_agent "$name" ;;
  esac
  summary="$summary$(printf '  %-12s %s' "$name" "$mode")"$'\n'
done

if [ "$DASHBOARD" = true ]; then
  say "Dashboard -> ~/Applications/CCyclops.app, ~/.local/bin/ccyclops"
  copy "$REPO_DIR/bin/ccyclops" "$LAUNCHER" 755
  render "$REPO_DIR/app/Info.plist" "$APP/Contents/Info.plist"
  copy "$REPO_DIR/app/launcher" "$APP/Contents/MacOS/launcher" 755
  copy "$REPO_DIR/app/icon.icns" "$APP/Contents/Resources/app.icns"
  t=$(mktemp); helper dashboard-plist "$t"; put "$t" "$(agent_plist workflows)"
  if [ "$CHANGED" = 0 ] && is_loaded workflows; then
    # Same agent, maybe new dashboard code: restart the server.
    if [ "$DRY" = 1 ]; then echo "  [dry] restart $(label workflows)"; else launchctl kickstart -k "$GUI/$(label workflows)"; fi
  else
    load_agent workflows
  fi
  summary="$summary$(printf '  %-12s http://127.0.0.1:%s  (open it: ccyclops)' dashboard "$DASHBOARD_PORT")"$'\n'
else
  say "Dashboard off — removing it"
  unload_agent workflows
  remove "$APP" "$LAUNCHER"
fi

legacy=$(legacy_paths)
if [ -n "$legacy" ]; then
  say "Removing files from the previous layout"
  while IFS= read -r p; do remove "$p"; done <<<"$legacy"
fi

say "Done$([ "$DRY" = 1 ] && echo ' (dry run — nothing was changed)')"
printf '%s' "$summary"
printf '  %-12s %s\n' hooks "${hook_names:-none}"
cat <<EOF

Change anything: edit $(pretty "$CONFIG"), then run ./install.sh again.
Run a job now:   bash ~/.claude/scripts/run-job.sh standup
EOF
if [ "$FIRST_RUN" = 1 ]; then
  cat <<EOF

First-time setup:
  1. gh auth login       (if the dependency check warned about it)
  2. Calendar access: run 'icalBuddy eventsToday' once in Terminal and approve
     the prompt — scheduled jobs inherit that grant via launchd.
  3. Optional Dock icon:
     defaults write com.apple.dock persistent-apps -array-add '<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$APP</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>' && killall Dock
EOF
fi

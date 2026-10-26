#!/bin/bash
# End-to-end check of install.sh, run-job.sh and the hooks in a throwaway
# $HOME (with a space in it). claude, gh, launchctl and osascript are fakes;
# jq, python3 and git are real. Never touches your ~/.claude or launchd.
#
#   bash tests/smoke.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export SANDBOX HOME="$SANDBOX/home dir" CCYCLOPS_NONINTERACTIVE=1 CCYCLOPS_CONFIG="$SANDBOX/config.sh"
FAKE="$SANDBOX/bin"
export PATH="$FAKE:$PATH"
mkdir -p "$HOME" "$FAKE"

passed=0
ok()    { passed=$((passed + 1)); printf '  ok   %s\n' "$1"; }
check() { local what="$1"; shift; if "$@" >/dev/null; then ok "$what"; else printf '  FAIL %s\n' "$what" >&2; exit 1; fi; }
install() { "$REPO/install.sh" "$@" </dev/null >"$SANDBOX/out" 2>&1; }
install_ok() { install "$@" || { cat "$SANDBOX/out"; echo "install.sh $* failed" >&2; exit 1; }; }
output_has() { grep -q -- "$1" "$SANDBOX/out"; }
snapshot() { find "$HOME" -type f -exec md5 -q {} + 2>/dev/null | sort | md5 -q; }
label() { python3 -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["Label"])' "$1"; }

# ------------------------------------------------------------------- fakes
cat > "$FAKE/launchctl" <<'EOF'
#!/bin/bash
# Records calls and remembers which labels are "loaded".
echo "$*" >> "$SANDBOX/launchctl.log"
state="$SANDBOX/loaded"; touch "$state"
case "$1" in
  bootstrap) python3 -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["Label"])' "$3" >> "$state" ;;
  bootout)   grep -vxF "${2##*/}" "$state" > "$state.tmp" || true; mv "$state.tmp" "$state" ;;
  print)     grep -qxF "${2##*/}" "$state"; exit $? ;;
  list)      printf 'PID\tStatus\tLabel\n'; awk '{ print "-\t0\t" $0 }' "$state" ;;
esac
exit 0
EOF
cat > "$FAKE/claude" <<'EOF'
#!/bin/bash
# Logs its arguments one per line, answers like `claude -p --output-format json`.
{ echo "--- call"; printf '%s\n' "$@"; } >> "$SANDBOX/claude.log"
jq -n --arg r "${FAKE_RESULT:-Wrote the note}" --argjson e "${FAKE_ERROR:-false}" \
  '{type: "result", is_error: $e, result: $r, total_cost_usd: 0.42, num_turns: 7, duration_ms: 12000, session_id: "s1"}'
EOF
printf '#!/bin/bash\nexit 0\n' > "$FAKE/gh"
printf '#!/bin/bash\nexit 0\n' > "$FAKE/osascript"
chmod +x "$FAKE"/*

echo "first run"
install_ok
check "without a terminal it writes config.sh from the example and stops" \
  test -f "$CCYCLOPS_CONFIG" -a ! -e "$HOME/.claude/commands"
check "config.sh is the documented example" cmp -s "$CCYCLOPS_CONFIG" "$REPO/config.example.sh"

# ----------------------------------------------------------- a real setup
cat > "$CCYCLOPS_CONFIG" <<EOF
VAULT="\$HOME/My Vault"
PROJECTS_DIR="\$HOME/Projects"
MAIN_REPO="acme/widgets"
MAIN_REPO_DIR="\$HOME/Projects/widgets"
GITHUB_ORG="acme"
JOB_PR_QUEUE="weekdays 08:40 13:00"
JOB_WEEKLY="fri 16:00"
CALENDAR=false
NOTIFICATIONS=false
SKIP_MEETING='Standup & Sync | "Daily"'
CLAUDE_BIN="$FAKE/claude"
EOF
mkdir -p "$HOME/.claude/scripts" "$HOME/.claude/commands" "$HOME/Projects/widgets"
echo '{"model": "opus", "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "/usr/local/bin/my-hook"}]}]}}' \
  > "$HOME/.claude/settings.json"
touch "$HOME/.claude/scripts/standup-cron.sh" "$HOME/.claude/commands/veckan.md"  # v1 leftovers

echo "dry run"
before=$(snapshot)
install_ok --dry-run
check "changes nothing" test "$before" = "$(snapshot)"
check "lists what it would do" output_has "\[dry\] create ~/.claude/commands/standup.md"

echo "install"
install_ok
C="$HOME/.claude"
for n in pr-queue standup wrapdown weekly catchup; do
  check "installs /$n" test -f "$C/commands/$n.md"
done
check "fills every {{KEY}}" bash -c '! grep -rq "{{" "$1"' _ "$C/commands"
check "quotes vault paths with spaces in shell lines" grep -qF "find \"$HOME/My Vault/Workflows/Tickets\"" "$C/commands/standup.md"
check "pr-queue can't run git" bash -c '! grep -q "git -C" "$1"' _ "$C/commands/pr-queue.md"
check "pr-queue runs at 08:40 and 13:00 on weekdays (10 entries)" test "$(python3 -c '
import plistlib, sys; print(len(plistlib.load(open(sys.argv[1], "rb"))["StartCalendarInterval"]))' \
  "$HOME/Library/LaunchAgents/com.$(whoami).claude-pr-queue.plist")" = 10
check "weekly runs Fridays 16:00" python3 -c '
import plistlib, sys; assert plistlib.load(open(sys.argv[1], "rb"))["StartCalendarInterval"] == [{"Weekday": 5, "Hour": 16, "Minute": 0}]' \
  "$HOME/Library/LaunchAgents/com.$(whoami).claude-weekly.plist"
check "manual commands get no agent" test ! -e "$HOME/Library/LaunchAgents/com.$(whoami).claude-catchup.plist"
for p in "$HOME"/Library/LaunchAgents/*.plist; do
  check "valid plist: $(basename "$p")" plutil -lint -s "$p"
done
check "loads the 4 jobs + dashboard" test "$(sort "$SANDBOX/loaded" | tr '\n' ' ')" = \
  "$(for n in pr-queue standup weekly workflows wrapdown; do printf 'com.%s.claude-%s ' "$(whoami)" "$n"; done)"
check "keeps the user's own hook and settings" jq -e '.model == "opus" and
  (.hooks.SessionStart | map(.hooks[].command) | index("/usr/local/bin/my-hook") != null)' "$C/settings.json"
check "registers the 3 session hooks" test "$(jq -r --arg h "$C/hooks/" \
  '[.hooks[][].hooks[].command | select(startswith($h))] | length' "$C/settings.json")" = 3
check "removes the v1 leftovers" test ! -e "$C/scripts/standup-cron.sh" -a ! -e "$C/commands/veckan.md"
check "round-trips odd characters through the installed config" bash -c \
  '. "$1"; [ "$SKIP_MEETING" = "Standup & Sync | \"Daily\"" ]' _ "$C/ccyclops/config.sh"
check "dashboard renders the new schedules" bash -c \
  'python3 "$1/.claude/scripts/workflows-dashboard.py" --dump | grep -q "Fri 16:00"' _ "$HOME"

echo "re-run with nothing changed"
cp "$C/settings.json" "$SANDBOX/settings.before"
loads=$(grep -c bootstrap "$SANDBOX/launchctl.log")
install_ok
check "rewrites nothing" bash -c '! grep -qE "^  (updated|created|removed) " "$1"' _ "$SANDBOX/out"
check "leaves settings.json alone" cmp -s "$C/settings.json" "$SANDBOX/settings.before"
check "reloads no job" test "$(grep -c bootstrap "$SANDBOX/launchctl.log")" = "$loads"

echo "run-job.sh"
job() { bash "$C/scripts/run-job.sh" "$1" >/dev/null 2>&1; }
last_call() { awk '/^--- call$/ { n++ } { if (n) a[n] = a[n] $0 "\n" } END { printf "%s", a[n] }' "$SANDBOX/claude.log"; }
arg_after() { last_call | awk -v f="$1" 'p { print; exit } $0 == f { p = 1 }'; }
check "standup succeeds" job standup
check "logs result and cost for the dashboard" grep -q '^meta: cost \$0.42 · 7 turns · 12s' "$C/logs/standup-cron.log"
check "turn cap from the command's frontmatter" test "$(arg_after --max-turns)" = 50
check "allowlist from the frontmatter" bash -c '[[ "$1" == Skill,Bash\(date:\*\),* ]]' _ "$(arg_after --allowedTools)"
check "edits denied in ~/.claude and the repos" test "$(arg_after --disallowedTools)" = \
  "Edit(/$C/**),Edit(/$HOME/Projects/**),Edit(/$HOME/Projects/widgets/**)"
check "vault added as a working dir" bash -c 'printf "%s" "$1" | grep -qxF -- "$2"' _ "$(last_call)" "$HOME/My Vault"
job pr-queue
check "pr-queue may read the projects folder" bash -c 'printf "%s" "$1" | grep -qxF -- "$2"' _ "$(last_call)" "$HOME/Projects"
check "pr-queue turn cap" test "$(arg_after --max-turns)" = 60
rc=0; FAKE_RESULT="FEED FAILURE: gh auth" job standup || rc=$?
check "FEED FAILURE exits 2" test "$rc" = 2
rc=0; FAKE_ERROR=true FAKE_RESULT="Claude usage limit reached" job standup || rc=$?
check "usage limit exits 1" test "$rc" = 1
check "and neither one retries" bash -c '! grep -q retrying "$1"' _ "$C/logs/standup-cron.log"
mv "$HOME/Projects/widgets" "$HOME/Projects/gone"
rc=0; job standup || rc=$?
check "missing MAIN_REPO_DIR fails pre-flight (exit 3)" test "$rc" = 3
mv "$HOME/Projects/gone" "$HOME/Projects/widgets"

echo "hooks"
W="$HOME/Projects/widgets" T="$HOME/My Vault/Workflows/Tickets"
git -C "$W" init -q -b main && git -C "$W" config user.email me@example.com && git -C "$W" config user.name Me
echo a > "$W/readme.txt" && git -C "$W" add . && git -C "$W" commit -qm init
git -C "$W" checkout -qb feature/1234-login
echo b > "$W/login.txt" && git -C "$W" add . && git -C "$W" commit -qm "Add login form"
echo c > "$W/draft notes.txt"
mkdir -p "$T" && echo untouched > "$T/12345 Other ticket.md"
hook() { echo "{\"cwd\": \"$W\"}" | bash "$C/hooks/$1.sh"; }
hook ticket-log
check "ticket-log writes the note for ticket 1234" grep -q "Add login form" "$T/1234.md"
check "with committed and uncommitted files" bash -c 'grep -q login.txt "$1" && grep -q "draft notes.txt" "$1"' _ "$T/1234.md"
check "and leaves ticket 12345's note alone" test "$(cat "$T/12345 Other ticket.md")" = untouched
check "ticket-context loads it at session start" bash -c '[[ "$1" == *"feature/1234-login"* ]]' _ \
  "$(hook ticket-context | jq -r .hookSpecificOutput.additionalContext)"
git -C "$W" checkout -q main
entries=$(grep -c '^### ' "$T/1234.md")
hook ticket-log
check "no log entry on the default branch" test "$(grep -c '^### ' "$T/1234.md")" = "$entries"

echo "turn things off in config.sh"
printf '%s\n' 'JOB_WRAPDOWN="off"' 'JOB_WEEKLY="manual"' 'HOOK_TICKET_LOG=false' 'DASHBOARD=false' >> "$CCYCLOPS_CONFIG"
install_ok
A="$HOME/Library/LaunchAgents/com.$(whoami).claude"
check "wrapdown is gone" test ! -e "$C/commands/wrapdown.md" -a ! -e "$A-wrapdown.plist"
check "weekly is manual again" test -f "$C/commands/weekly.md" -a ! -e "$A-weekly.plist"
check "ticket-log hook is unregistered" bash -c '! grep -q ticket-log "$1" && [ ! -e "$2" ]' _ "$C/settings.json" "$C/hooks/ticket-log.sh"
check "ticket-context hook stays" grep -q ticket-context "$C/settings.json"
check "dashboard, app and launcher are gone" \
  test ! -e "$A-workflows.plist" -a ! -e "$HOME/Applications/Claude Workflows.app" -a ! -e "$HOME/.local/bin/workflows"
check "unloaded what was turned off" test "$(sort "$SANDBOX/loaded" | tr '\n' ' ')" = \
  "$(for n in pr-queue standup; do printf 'com.%s.claude-%s ' "$(whoami)" "$n"; done)"

echo "a broken config"
cp "$CCYCLOPS_CONFIG" "$SANDBOX/config.good"
printf '%s\n' 'JOB_STANDUP="weekdayz 9"' 'JOB_STANDUPP="daily 09:00"' 'CALENDAR=yes' >> "$CCYCLOPS_CONFIG"
before=$(snapshot)
rc=0; install || rc=$?
check "is refused" test "$rc" = 1
check "names the bad schedule" output_has 'JOB_STANDUP: "weekdayz 9": unknown day'
check "flags the typo" output_has "JOB_STANDUPP doesn't match a file in commands/"
check "flags the bad boolean" output_has 'CALENDAR="yes": use true or false'
check "and changes nothing" test "$before" = "$(snapshot)"
cp "$SANDBOX/config.good" "$CCYCLOPS_CONFIG"

echo "write-config (the setup answers)"
CCYCLOPS_EXAMPLE="$REPO/config.example.sh" VAULT="$HOME/a \"b\" \$c" LANGUAGE=Svenska \
  python3 "$REPO/tools/ccyclops.py" write-config "$REPO/config.example.sh" "$SANDBOX/answers.sh" VAULT LANGUAGE
check "answers survive shell quoting" bash -c '. "$1"; [ "$VAULT" = "$HOME/a \"b\" \$c" ] && [ "$LANGUAGE" = Svenska ]' _ "$SANDBOX/answers.sh"
check "comments are kept" grep -q '^LANGUAGE="Svenska" .*# language of the notes' "$SANDBOX/answers.sh"

echo "uninstall"
install_ok --uninstall --yes
check "removes commands, hooks, scripts and config" bash -c \
  '[ -z "$(find "$1/commands" "$1/hooks" -type f)" ] && [ ! -e "$1/scripts/run-job.sh" ] && [ ! -e "$1/ccyclops" ]' _ "$C"
check "removes every agent" bash -c '[ -z "$(ls "$1" 2>/dev/null)" ] && [ ! -s "$2" ]' _ "$HOME/Library/LaunchAgents" "$SANDBOX/loaded"
check "leaves only the user's own hook" jq -e '.model == "opus" and ([.hooks[][].hooks[].command] == ["/usr/local/bin/my-hook"])' "$C/settings.json"
check "keeps notes and quotes" test -f "$T/1234.md" -a -f "$C/scripts/workflows-quotes.json"

echo "all $passed checks passed"

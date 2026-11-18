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
{ echo "--- call"; echo "cwd=$PWD"; printf '%s\n' "$@"; } >> "$SANDBOX/claude.log"
# FAKE_LEFTOVER=1: leave a background child behind, like a tool a job started.
if [ -n "${FAKE_LEFTOVER:-}" ]; then sleep 300 </dev/null & echo $! > "$SANDBOX/leftover.pid"; fi
# FAKE_WARNING=1: a warning on stderr, like claude's "[claude-code:unrecognized_model]".
if [ -n "${FAKE_WARNING:-}" ]; then echo '[claude-code:unrecognized_model] {"model":"x"}' >&2; fi
jq -n --arg r "${FAKE_RESULT:-Wrote the note}" --argjson e "${FAKE_ERROR:-false}" \
  '{type: "result", is_error: $e, result: $r, total_cost_usd: 0.42, num_turns: 7, duration_ms: 12000, session_id: "s1"}'
EOF
cat > "$FAKE/gh" <<'EOF'
#!/bin/bash
# Logs its arguments; FAKE_GH_FAIL=1 makes it fail like an expired token.
echo "$*" >> "$SANDBOX/gh.log"
if [ -n "${FAKE_GH_FAIL:-}" ]; then echo "gh: Bad credentials (HTTP 401)" >&2; exit 1; fi
exit 0
EOF
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
GITHUB_SCOPE="org:acme repo:acme-labs/api"
MODEL="haiku"
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
# v1 leftovers, including its app and launcher under their old names
touch "$HOME/.claude/scripts/standup-cron.sh" "$HOME/.claude/commands/veckan.md"
mkdir -p "$HOME/Applications/Claude Workflows.app/Contents" "$HOME/.local/bin"
echo '<string>com.me.claude-workflows-app</string>' > "$HOME/Applications/Claude Workflows.app/Contents/Info.plist"
echo 'exec python3 "$HOME/.claude/scripts/workflows-dashboard.py" "$@"' > "$HOME/.local/bin/workflows"

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
check "and the old Claude Workflows.app and workflows launcher" \
  test ! -e "$HOME/Applications/Claude Workflows.app" -a ! -e "$HOME/.local/bin/workflows"
check "installs CCyclops.app and the ccyclops launcher" \
  test -x "$HOME/Applications/CCyclops.app/Contents/MacOS/launcher" -a -x "$HOME/.local/bin/ccyclops"
check "PR feeds go through pr-feed.sh" grep -qF "!\`$C/scripts/pr-feed.sh review-requested\`" "$C/commands/standup.md"
check "round-trips odd characters through the installed config" bash -c \
  '. "$1"; [ "$SKIP_MEETING" = "Standup & Sync | \"Daily\"" ]' _ "$C/ccyclops/config.sh"
python3 "$C/scripts/workflows-dashboard.py" --dump > "$SANDBOX/dash.html"
check "dashboard renders the new schedules" grep -q "Fri 16:00" "$SANDBOX/dash.html"
check "dashboard is branded CCyclops" grep -q "<title>CCyclops</title>" "$SANDBOX/dash.html"
check "its own card says dashboard" grep -q '<span class="name">dashboard</span>' "$SANDBOX/dash.html"
check "is English by default, with a toggle to Swedish" bash -c \
  'grep -qF "<html lang=\"en\">" "$1" && grep -qF "class=\"langbtn\" data-lang=\"sv\"" "$1" && grep -qF "</svg>SV</button>" "$1"' _ "$SANDBOX/dash.html"
python3 "$C/scripts/workflows-dashboard.py" --dump --lang sv > "$SANDBOX/dash-sv.html"
check "--lang sv renders it in Swedish" bash -c \
  'grep -qF "<html lang=\"sv\">" "$1" && grep -qF "<h2>Schemalagt</h2>" "$1" && grep -qF ">pausa</button>" "$1" && grep -qF "fre 16:00" "$1"' _ "$SANDBOX/dash-sv.html"
check "but not the user's own text" bash -c \
  'grep -qF "<span class=\"name\">dashboard</span>" "$1" && grep -qF "<title>CCyclops</title>" "$1"' _ "$SANDBOX/dash-sv.html"
check "--lang takes only en and sv" bash -c '! python3 "$1" --dump --lang de 2>/dev/null' _ "$C/scripts/workflows-dashboard.py"
check "and nothing calls setlocale" bash -c '! grep -q setlocale "$1"' _ "$C/scripts/workflows-dashboard.py"

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
check "edits denied in ~/.claude and the repos" test "$(arg_after --disallowedTools)" = "Edit(/$C/**),Edit(/$HOME/Projects/**)"
check "runs from the vault" bash -c 'printf "%s" "$1" | grep -qxF -- "cwd=$2"' _ "$(last_call)" "$HOME/My Vault"
check "MODEL from config.sh" test "$(arg_after --model)" = haiku
check "vault added as a working dir" bash -c 'printf "%s" "$1" | grep -qxF -- "$2"' _ "$(last_call)" "$HOME/My Vault"
job pr-queue
check "pr-queue may read the projects folder" bash -c 'printf "%s" "$1" | grep -qxF -- "$2"' _ "$(last_call)" "$HOME/Projects"
check "pr-queue turn cap" test "$(arg_after --max-turns)" = 60
rc=0; FAKE_RESULT="FEED FAILURE: gh auth" job standup || rc=$?
check "FEED FAILURE exits 2" test "$rc" = 2
rc=0; FAKE_ERROR=true FAKE_RESULT="Claude usage limit reached" job standup || rc=$?
check "usage limit exits 1" test "$rc" = 1
check "and neither one retries" bash -c '! grep -q retrying "$1"' _ "$C/logs/standup-cron.log"
FAKE_LEFTOVER=1 job standup
check "a child a tool left behind dies with claude (#5)" bash -c \
  'sleep 1; case "$(ps -o stat= -p "$(cat "$1")" 2>/dev/null)" in ""|Z*) ;; *) exit 1 ;; esac' _ "$SANDBOX/leftover.pid"
python3 -c 'import sys; p = sys.argv[1]; t = open(p).read(); open(p, "w").write(t.replace("max-turns: 50\n", "max-turns: 50\nmodel: sonnet\n", 1))' "$C/commands/standup.md"
job standup
check "a command's model: line beats MODEL" test "$(arg_after --model)" = sonnet
rc=0; FAKE_WARNING=1 job standup || rc=$?
check "a warning on claude's stderr doesn't fail the run" bash -c \
  '[ "$1" = 0 ] && ! tail -4 "$2" | grep -q -e retrying -e unrecognized_model' _ "$rc" "$C/logs/standup-cron.log"

echo "model dropdown"
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 "$C/scripts/workflows-dashboard.py" --no-open --port "$PORT" >/dev/null 2>&1 &
DASH=$!
set_model() { curl -s -o /dev/null -w '%{http_code}' --retry 5 --retry-connrefused --retry-delay 1 \
  -H 'Content-Type: application/json' -d "{\"name\": \"$1\", \"model\": \"$2\"}" "http://127.0.0.1:$PORT/model"; }
card() { curl -s "http://127.0.0.1:$PORT/" | grep -o "<select class=\"modelsel\" data-name=\"$1\".*</select>"; }
check "picking a model is saved" test "$(set_model standup opus)" = 200
check "and shown as selected" bash -c '[[ "$1" == *"value=\"opus\" selected"* ]]' _ "$(card standup)"
check "a job's default is its model: line" bash -c '[[ "$1" == *">default · sonnet<"* ]]' _ "$(card standup)"
check "or MODEL" bash -c '[[ "$1" == *">default · haiku<"* ]]' _ "$(card pr-queue)"
check "the dashboard's own card has no dropdown" bash -c '[ -z "$1" ]' _ "$(card workflows || true)"
job standup
check "the pick beats the model: line and MODEL" test "$(arg_after --model)" = opus
check "an unknown model or job is refused" test "$(set_model standup gpt)$(set_model workflows opus)" = 400400
check "picking default clears it" test "$(set_model standup "")" = 200
job standup
check "back on the model: line" test "$(arg_after --model)" = sonnet

echo "pause toggle"
P="$C/ccyclops/job-paused.json"
set_pause() { curl -s -o /dev/null -w '%{http_code}' -H "Content-Type: ${3:-application/json}" \
  -d "{\"name\": \"$1\", \"paused\": $2}" "http://127.0.0.1:$PORT/pause"; }
page() { curl -s "http://127.0.0.1:$PORT/"; }
exits() { grep -c '^=== exit' "$C/logs/standup-cron.log"; }
calls() { grep -c '^--- call$' "$SANDBOX/claude.log"; }
check "the dashboard renders with no pause file" test "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")" = 200
check "each job card has a pause button" bash -c '[[ "$1" == *"class=\"pausebtn\" data-name=\"pr-queue\" data-paused=\"false\""*">pause</button>"* ]]' _ "$(page)"
set_model standup opus >/dev/null
check "pausing a job is saved" test "$(set_pause standup true)" = 200
check "as {\"<job>\": true}" jq -e '. == {"standup": true}' "$P"
check "the card shows it paused" bash -c '[[ "$1" == *"<span class=\"dot warn\"></span>"* && "$1" == *"<span class=\"chip\">paused · "* && "$1" == *"data-name=\"standup\" data-paused=\"true\""*">resume</button>"* ]]' _ "$(page)"
check "a lang=sv cookie serves it in Swedish" bash -c '[[ "$1" == *"<html lang=\"sv\">"* && "$1" == *"<h2>Schemalagt</h2>"* && "$1" == *"</svg>EN</button>"* && "$1" == *"data-name=\"standup\" data-paused=\"true\""*">återuppta</button>"* ]]' _ \
  "$(curl -s -b lang=sv "http://127.0.0.1:$PORT/")"
check "no cookie or an unknown one serves English" bash -c '[[ "$1" == *"<html lang=\"en\">"* && "$2" == *"<html lang=\"en\">"* && "$2" == *"</svg>SV</button>"* ]]' _ \
  "$(page)" "$(curl -s -b lang=xx "http://127.0.0.1:$PORT/")"
check "with no next run" bash -c '[ -n "$1" ] && [[ "$1" != *"next "* ]]' _ "$(page | grep -o '<div class="kv">[^<]*claude-standup.plist')"
check "and its model dropdown" bash -c '[[ "$1" == *"value=\"opus\" selected"* ]]' _ "$(card standup)"
e0=$(exits) c0=$(calls)
rc=0; out=$(bash "$C/scripts/run-job.sh" standup 2>&1) || rc=$?
check "a paused job exits 0" test "$rc" = 0
check "with one line telling how to resume it" test "$out" = "standup is paused — resume it on the dashboard (ccyclops)"
check "and neither logs a run nor starts claude" test "$(exits) $(calls)" = "$e0 $c0"
cp "$P" "$SANDBOX/paused.before"
check "an unknown job, the dashboard, a non-boolean or a non-JSON body is refused" \
  test "$(set_pause nope true)$(set_pause workflows true)$(set_pause standup '"yes"')$(set_pause standup null)$(set_pause standup true text/plain)" = 400400400400400
check "and leaves the pause file alone" cmp -s "$P" "$SANDBOX/paused.before"
check "the dashboard's own card has no pause button" bash -c '[[ "$1" != *"class=\"pausebtn\" data-name=\"workflows\""* ]]' _ "$(page)"
install_ok
check "a re-install keeps the pause" cmp -s "$P" "$SANDBOX/paused.before"
check "resuming is saved" test "$(set_pause standup false)" = 200
check "and removes the key" jq -e '. == {}' "$P"
job standup
check "the next run logs again" test "$(exits) $(calls)" = "$((e0 + 1)) $((c0 + 1))"
check "with its model pick" test "$(arg_after --model)" = opus
set_model standup "" >/dev/null
echo 'not json' > "$P"
check "a malformed pause file pauses nothing" job standup
check "and the dashboard still renders" test "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")" = 200
: > "$P"
check "nor does an empty one" job standup
rm -f "$P"

echo "quotes"
Q="$C/scripts/workflows-quotes.json"
cp "$Q" "$SANDBOX/quotes.orig"
set_quotes() { curl -s -o "$SANDBOX/qres" -w '%{http_code}' -H "Content-Type: ${2:-application/json}" \
  --data-binary "$1" "http://127.0.0.1:$PORT/quotes"; }
check "saving the quotes returns 200" test "$(set_quotes '{"quotes": ["a", "b"]}')" = 200
check "with the list as saved" jq -e '. == {"ok": true, "quotes": ["a", "b"]}' "$SANDBOX/qres"
check "and writes it to the quotes file" jq -e '.quotes == ["a", "b"]' "$Q"
check "without leaving its tmp file behind" test ! -e "$Q.tmp"
check "quotes are trimmed" test "$(set_quotes '{"quotes": ["  a  ", "b"]}')" = 200
check "before they are saved" jq -e '.quotes == ["a", "b"]' "$Q"
cp "$Q" "$SANDBOX/quotes.before"
long=$(printf '%501s' | tr ' ' x)
check "a non-JSON body, text/plain, a non-list, a non-string, an empty or blank quote and one over 500 characters are refused" \
  test "$(set_quotes 'not json')$(set_quotes '{"quotes": ["a"]}' text/plain)$(set_quotes '{"quotes": "a"}')$(set_quotes '{"quotes": ["a", 1]}')$(set_quotes '{"quotes": ["a", ""]}')$(set_quotes '{"quotes": ["a", "  "]}')$(set_quotes "{\"quotes\": [\"a\", \"$long\"]}")" = 400400400400400400400
check "and leave the quotes file byte-for-byte alone" cmp -s "$Q" "$SANDBOX/quotes.before"
python3 -c 'import json; print(json.dumps({"quotes": ["x" * 500] * 140}))' > "$SANDBOX/big.json"
check "so is a body over 64 KB, even of valid quotes" test "$(set_quotes "@$SANDBOX/big.json")" = 400
check "which leaves the file alone too" cmp -s "$Q" "$SANDBOX/quotes.before"
check "500 characters is still fine" test "$(set_quotes "{\"quotes\": [\"${long:1}\"]}")" = 200
printf '{"theme": "green", "quotes": ["a"]}\n' > "$Q"
set_quotes '{"quotes": ["c"]}' >/dev/null
check "other top-level keys in the file are kept" jq -e '. == {"theme": "green", "quotes": ["c"]}' "$Q"
set_quotes '{"quotes": ["Talk is <cheap>", "b"]}' >/dev/null
check "the page has a Quotes section after the hooks, inside .wrap" bash -c \
  '[[ "$1" == *"<div class=\"wrap\">"*"class=\"hooks\""*"<section class=\"quotes\"><h2>Quotes</h2>"*"<footer>"*"</div>"*"let QUOTES"* ]]' _ "$(page)"
check "with one row per quote" test "$(page | grep -o 'class="qrow"' | wc -l | tr -d ' ')" = 2
check "each with an edit and a delete control, and an add field" bash -c \
  '[[ "$1" == *"<div class=\"qrow\" data-q=\"Talk is &lt;cheap&gt;\"><span class=\"qtext\">Talk is &lt;cheap&gt;</span><textarea class=\"qinput\""*"class=\"qbtn qedit\""*"class=\"qbtn qdel\""*"<div class=\"qrow\" data-q=\"b\">"*"class=\"qbtn qedit\""*"class=\"qbtn qdel\""*"<input class=\"qnew\""*"class=\"qbtn qaddbtn\""* ]]' _ "$(page)"
check "and the rain gets the same list" bash -c '[[ "$1" == *"let QUOTES = [\"Talk is <cheap>\", \"b\"];"* ]]' _ "$(page)"
check "a lang=sv cookie shows the section in Swedish, the quotes as they are" bash -c \
  '[[ "$1" == *"<h2>Citat</h2>"* && "$1" == *">redigera</button>"* && "$1" == *">ta bort</button>"* && "$1" == *">lägg till</button>"* && "$1" == *"<span class=\"qtext\">Talk is &lt;cheap&gt;</span>"* ]]' _ \
  "$(curl -s -b lang=sv "http://127.0.0.1:$PORT/")"
check "so does --dump --lang sv" bash -c 'python3 "$1" --dump --lang sv | grep -qF "<h2>Citat</h2>"' _ "$C/scripts/workflows-dashboard.py"
set_quotes '{"quotes": ["a</script>b"]}' >/dev/null
check "a quote can't end the page's script" bash -c 'curl -s "$1" | grep -qF "let QUOTES = [\"a<\\/script>b\"];"' _ "http://127.0.0.1:$PORT/"
check "an empty list is saved" bash -c '[ "$1" = 200 ] && jq -e ".quotes == []" "$2"' _ "$(set_quotes '{"quotes": []}')" "$Q"
check "and the dashboard still renders" test "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")" = 200
check "with no quote rows" bash -c '[[ "$1" != *"class=\"qrow\""* && "$1" == *"let QUOTES = [];"* ]]' _ "$(page)"
cp "$SANDBOX/quotes.orig" "$Q"
kill "$DASH"; wait "$DASH" 2>/dev/null || true

mv "$HOME/My Vault" "$HOME/gone"
rc=0; job standup || rc=$?
check "missing VAULT fails pre-flight (exit 3)" test "$rc" = 3
mv "$HOME/gone" "$HOME/My Vault"

echo "pr-feed.sh"
bash "$C/scripts/pr-feed.sh" review-requested >/dev/null
check "searches every term of GITHUB_SCOPE" grep -qF "q=is:pr is:open review-requested:@me org:acme repo:acme-labs/api" "$SANDBOX/gh.log"
rc=0; out=$(FAKE_GH_FAIL=1 bash "$C/scripts/pr-feed.sh" mine) || rc=$?
check "a failing search is loud: exit 1 and an error: line for the feed check" \
  bash -c '[ "$1" = 1 ] && [[ "$2" == "error: GitHub search failed"*"Bad credentials"* ]]' _ "$rc" "$out"

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
  test ! -e "$A-workflows.plist" -a ! -e "$HOME/Applications/CCyclops.app" -a ! -e "$HOME/.local/bin/ccyclops"
check "unloaded what was turned off" test "$(sort "$SANDBOX/loaded" | tr '\n' ' ')" = \
  "$(for n in pr-queue standup; do printf 'com.%s.claude-%s ' "$(whoami)" "$n"; done)"

echo "a broken config"
cp "$CCYCLOPS_CONFIG" "$SANDBOX/config.good"
printf '%s\n' 'JOB_STANDUP="weekdayz 9"' 'JOB_STANDUPP="daily 09:00"' 'CALENDAR=yes' 'GITHUB_SCOPE="acme"' >> "$CCYCLOPS_CONFIG"
before=$(snapshot)
rc=0; install || rc=$?
check "is refused" test "$rc" = 1
check "names the bad schedule" output_has 'JOB_STANDUP: "weekdayz 9": unknown day'
check "flags the typo" output_has "JOB_STANDUPP doesn't match a file in commands/"
check "flags the bad boolean" output_has 'CALENDAR="yes": use true or false'
check "flags a scope that isn't search terms" output_has 'GITHUB_SCOPE="acme": use org:NAME'
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

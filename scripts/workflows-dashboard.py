#!/usr/bin/env python3
"""Claude Workflows — single-file, stdlib-only status dashboard.

Scans on every request (a browser refresh always shows live state):
  * ~/Library/LaunchAgents/*.plist        -> scheduled Claude workflows
      (agents whose label mentions "claude" or whose program touches ~/.claude)
  * launchctl list                        -> loaded state / last exit status
  * ~/.claude/logs/<name>-cron.log        -> run history (=== ... start === / === exit: N === blocks)
  * ~/.claude/commands/*.md frontmatter   -> descriptions + manual commands
  * ~/.claude/settings.json               -> session hooks

Usage:
  workflows                 serve on http://127.0.0.1:8787 and open the browser
  workflows --port 9000     serve on another port
  workflows --no-open       don't open the browser
  workflows --dump          print the HTML once to stdout (no server)
"""

import argparse
import base64
import html
import json
import plistlib
import re
import subprocess
import sys
import threading
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path

HOME = Path.home()
LAUNCH_AGENTS = HOME / "Library" / "LaunchAgents"
CLAUDE_DIR = HOME / ".claude"
LOGS_DIR = CLAUDE_DIR / "logs"
COMMANDS_DIR = CLAUDE_DIR / "commands"
SETTINGS = CLAUDE_DIR / "settings.json"

WEEKDAYS = {0: "Sun", 1: "Mon", 2: "Tue", 3: "Wed", 4: "Thu", 5: "Fri", 6: "Sat", 7: "Sun"}
QUOTES_FILE = Path(__file__).with_name("workflows-quotes.json")
DISMISSED_FILE = CLAUDE_DIR / "cache" / "workflows-dismissed.json"

# Hand-written descriptions win over anything derived from files.
DESCRIPTIONS = {
    "workflows": "This dashboard — serves this page at localhost:8787, always running, "
                 "listing every Claude automation on this Mac.",
}


# --------------------------------------------------------------------------- data

@dataclass
class Run:
    ts: str                      # "2026-09-01 09:06"
    exit: int | None             # None = still running / no exit marker yet
    summary: str
    body: str
    watchdog: bool = False
    cost: float | None = None    # from job-lib's "meta: cost $X · N turns · Ns" line
    turns: int | None = None
    dur: int | None = None

    @property
    def ok(self):
        return self.exit == 0


@dataclass
class Workflow:
    name: str
    label: str
    plist: Path
    schedule: str
    next_run: str
    description: str
    program: str
    log_path: Path | None
    runs: list = field(default_factory=list)
    loaded: bool = False
    launchctl_status: str = ""


def read_text(path: Path) -> str:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""


# ------------------------------------------------------------------- frontmatter

def first_sentence(text: str, limit: int = 180) -> str:
    text = text.strip()
    m = re.match(r"(.+?[.!?])\s", text + " ")
    if m:
        text = m.group(1)
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def frontmatter_description(md: Path) -> str:
    text = read_text(md)
    m = re.match(r"\A---\n(.*?)\n---", text, re.S)
    if not m:
        return ""
    d = re.search(r"^description:\s*(.+)$", m.group(1), re.M)
    return first_sentence(d.group(1)) if d else ""


def script_blurb(path: Path) -> str:
    """First sentence of a script's leading comment/docstring block."""
    lines = []
    for ln in read_text(path).splitlines()[1:8]:
        ln = ln.strip()
        if ln.startswith(("#", '"""', "'''")):
            lines.append(ln.lstrip("#\"' ").strip())
        else:
            break
    blurb = re.sub(r"^Session\w+ hook:\s*", "", " ".join(filter(None, lines)))
    return first_sentence(blurb) if blurb else ""


def load_commands() -> dict:
    """name -> description for ~/.claude/commands/*.md"""
    out = {}
    if COMMANDS_DIR.is_dir():
        for md in sorted(COMMANDS_DIR.glob("*.md")):
            out[md.stem] = frontmatter_description(md)
    return out


# ----------------------------------------------------------------------- launchd

def humanize_schedule(plist: dict) -> str:
    cal = plist.get("StartCalendarInterval")
    if cal:
        entries = cal if isinstance(cal, list) else [cal]
        by_time = {}
        for e in entries:
            t = f"{e.get('Hour', 0):02d}:{e.get('Minute', 0):02d}"
            by_time.setdefault(t, set())
            if "Weekday" in e:
                by_time[t].add(e["Weekday"] % 7)
        parts = []
        for t, days in sorted(by_time.items()):
            if not days or len(days) == 7:
                parts.append(f"Daily {t}")
            elif days == {1, 2, 3, 4, 5}:
                parts.append(f"Weekdays {t}")
            elif days == {0, 6}:
                parts.append(f"Weekends {t}")
            else:
                names = "/".join(WEEKDAYS[d] for d in sorted(days))
                parts.append(f"{names} {t}")
        return " · ".join(parts)
    if plist.get("KeepAlive"):
        return "always on"
    if "StartInterval" in plist:
        s = int(plist["StartInterval"])
        if s % 3600 == 0:
            return f"every {s // 3600}h"
        if s % 60 == 0:
            return f"every {s // 60}m"
        return f"every {s}s"
    return "on demand"


def next_run_text(plist: dict) -> str:
    cal = plist.get("StartCalendarInterval")
    if not cal:
        return ""
    entries = cal if isinstance(cal, list) else [cal]
    now = datetime.now()
    best = None
    for e in entries:
        for day in range(0, 9):
            cand = (now + timedelta(days=day)).replace(
                hour=e.get("Hour", 0), minute=e.get("Minute", 0), second=0, microsecond=0)
            if "Weekday" in e and cand.isoweekday() % 7 != e["Weekday"] % 7:
                continue
            if cand <= now:
                continue
            best = cand if best is None or cand < best else best
            break
    if not best:
        return ""
    if best.date() == now.date():
        return f"today {best:%H:%M}"
    if best.date() == (now + timedelta(days=1)).date():
        return f"tomorrow {best:%H:%M}"
    return f"{best:%a %H:%M}"


def launchctl_state() -> dict:
    """label -> (loaded, status_text)"""
    out = {}
    try:
        res = subprocess.run(["launchctl", "list"], capture_output=True, text=True, timeout=10)
        for line in res.stdout.splitlines()[1:]:
            cols = line.split("\t")
            if len(cols) >= 3:
                pid, status, label = cols[0], cols[1], cols[2]
                running = pid != "-"
                out[label] = (True, "running now" if running else f"last exit {status}")
    except Exception:
        pass
    return out


# -------------------------------------------------------------------- log parsing

RUN_START = re.compile(r"^=== (\d{4}-\d{2}-\d{2} \d{2}:\d{2}(?::\d{2})?) .*start ===\s*$")
RUN_EXIT = re.compile(r"^=== exit: (-?\d+) ===\s*$")


def parse_runs(log: Path) -> list:
    runs, cur, body = [], None, []
    for line in read_text(log).splitlines():
        m = RUN_START.match(line)
        if m:
            if cur:
                cur.body = "\n".join(body).strip()
                runs.append(cur)
            cur, body = Run(ts=m.group(1), exit=None, summary="", body=""), []
            continue
        m = RUN_EXIT.match(line)
        if m and cur:
            cur.exit = int(m.group(1))
            cur.body = "\n".join(body).strip()
            runs.append(cur)
            cur, body = None, []
            continue
        if cur is not None:
            body.append(line)
    if cur:
        cur.body = "\n".join(body).strip()
        runs.append(cur)
    for r in runs:
        r.watchdog = "WATCHDOG" in r.body
        m = re.search(r"^meta: cost \$([\d.]+) · (\d+) turns · (\d+)s", r.body, re.M)
        if m:
            r.cost, r.turns, r.dur = float(m.group(1)), int(m.group(2)), int(m.group(3))
        for ln in r.body.splitlines():
            ln = ln.strip()
            if ln and not ln.startswith(("---", "===", "meta:")):
                r.summary = ln[:160]
                break
        if not r.summary:
            r.summary = "(no output captured)"
    return runs


def find_log(name: str, plist: dict) -> Path | None:
    candidates = [LOGS_DIR / f"{name}-cron.log",
                  LOGS_DIR / f"{name}.log"]
    for key in ("StandardOutPath", "StandardErrorPath"):
        if plist.get(key):
            candidates.append(Path(plist[key]))
    best, best_runs = None, -1
    for c in candidates:
        if c and c.is_file():
            n = len(parse_runs(c))
            if n > best_runs:
                best, best_runs = c, n
    return best


# ---------------------------------------------------------------------- scanning

def scan_workflows(commands: dict) -> list:
    state = launchctl_state()
    flows = []
    if not LAUNCH_AGENTS.is_dir():
        return flows
    for pl in sorted(LAUNCH_AGENTS.glob("*.plist")):
        try:
            data = plistlib.loads(pl.read_bytes())
        except Exception:
            continue
        label = data.get("Label", pl.stem)
        args = " ".join(map(str, data.get("ProgramArguments", []))) + str(data.get("Program", ""))
        if "claude" not in label.lower() and "/.claude/" not in args:
            continue
        name = label.rsplit("claude-", 1)[-1] if "claude-" in label else label.split(".")[-1]
        script = next((a for a in data.get("ProgramArguments", []) if "/" in str(a) and "bash" not in str(a) and "python" not in str(a)), args)
        description = (DESCRIPTIONS.get(name)
                       or commands.get(name, "")
                       or script_blurb(Path(str(script))))
        log = find_log(name, data)
        loaded, status = state.get(label, (False, "not loaded"))
        flows.append(Workflow(
            name=name, label=label, plist=pl,
            schedule=humanize_schedule(data), next_run=next_run_text(data),
            description=description, program=str(script),
            log_path=log, runs=parse_runs(log)[::-1] if log else [],
            loaded=loaded, launchctl_status=status,
        ))
    return flows


def scan_hooks() -> list:
    """[(event, [(script basename, blurb)])]"""
    try:
        hooks = json.loads(read_text(SETTINGS)).get("hooks", {})
    except Exception:
        return []
    out = []
    for event, groups in hooks.items():
        scripts = []
        for g in groups:
            for h in g.get("hooks", []):
                if h.get("command"):
                    p = Path(h["command"])
                    scripts.append((p.name, script_blurb(p)))
        if scripts:
            out.append((event, scripts))
    return out


def load_quotes() -> list:
    try:
        q = json.loads(read_text(QUOTES_FILE)).get("quotes", [])
        return [s for s in q if isinstance(s, str) and s.strip()]
    except Exception:
        return []


def load_dismissed() -> set:
    try:
        return set(json.loads(read_text(DISMISSED_FILE)))
    except Exception:
        return set()


def save_dismissed(keys: set):
    # prune keys older than 14 days so the file never grows unbounded
    cutoff = (datetime.now() - timedelta(days=14)).strftime("%Y-%m-%d")
    fresh = [k for k in keys if k.split("|")[1][:10] >= cutoff]
    DISMISSED_FILE.parent.mkdir(parents=True, exist_ok=True)
    DISMISSED_FILE.write_text(json.dumps(sorted(fresh)))


def recent_failures(flows: list, days: int = 7) -> list:
    """[(key, text)] for non-dismissed failures in the window."""
    cutoff = datetime.now() - timedelta(days=days)
    dismissed = load_dismissed()
    fails = []
    for f in flows:
        for r in f.runs:
            try:
                ts = datetime.strptime(r.ts[:16], "%Y-%m-%d %H:%M")
            except ValueError:
                continue
            if ts >= cutoff and r.exit not in (0, None):
                key = f"{f.name}|{r.ts}|{r.exit}"
                if key in dismissed:
                    continue
                why = "watchdog timeout" if r.watchdog else f"exit {r.exit}"
                fails.append((key, f"{r.ts} — {f.name} failed ({why})"))
    return fails


# --------------------------------------------------------------------- rendering

def e(s):  # noqa: E743 - tiny escape alias keeps the template readable
    return html.escape(str(s))


def favicon_href() -> str:
    """Ninja icon if workflows-favicon.png sits next to this script, else the dot."""
    png = Path(__file__).with_name("workflows-favicon.png")
    if png.is_file():
        return "data:image/png;base64," + base64.b64encode(png.read_bytes()).decode()
    return ("data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'>"
            "<circle cx='8' cy='8' r='6' fill='%237fd97a'/></svg>")


CSS = """
:root {
  --bg: #0b100d; --panel: #101711; --panel2: #0e1410; --line: #223024;
  --ink: #cfe3d0; --dim: #7f957f; --faint: #55684f;
  --ok: #7fd97a; --warn: #e8b04b; --err: #ef6b5e; --chip: #16211a;
}
* { box-sizing: border-box; }
body {
  margin: 0; min-height: 100vh; color: var(--ink); background: var(--bg);
  font: 13.5px/1.55 "IBM Plex Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
}
#rain { position: fixed; inset: 0; z-index: -1; opacity: .55; }
#quote { position: fixed; right: 28px; top: 50%; transform: translateY(-50%);
  z-index: 0; width: calc((100vw - 960px) / 2 - 56px); max-width: 400px;
  text-align: left; font-size: 14px; line-height: 1.8; color: #9fdf9c;
  letter-spacing: .03em; text-shadow: 0 0 8px #7fd97a55, 0 0 24px #7fd97a22;
  opacity: 0; transition: opacity .6s; pointer-events: none; white-space: pre-wrap; }
@media (max-width: 1380px) {  /* narrow window: no side margin, use bottom band */
  #quote { right: auto; top: auto; left: 50%; bottom: 30px; transform: translateX(-50%);
    width: auto; max-width: min(720px, 86vw); text-align: center;
    background: rgba(11, 16, 13, .85); backdrop-filter: blur(3px);
    padding: 8px 18px; border-radius: 8px; border: 1px solid #22302466; }
}
.wrap { position: relative; z-index: 1; max-width: 900px; margin: 0 auto; padding: 40px 28px 96px; }
header { display: flex; align-items: baseline; justify-content: space-between;
  border-bottom: 1px solid var(--line); padding-bottom: 18px; margin-bottom: 8px; }
h1 { font-family: "Instrument Serif", Georgia, serif; font-style: italic; font-weight: 400;
  font-size: 44px; margin: 0; color: #e9f4e6; letter-spacing: .5px; }
h1 .tld { color: var(--ok); }
.meta { text-align: right; color: var(--dim); font-size: 12px; }
.meta b { color: var(--ink); font-weight: 500; }
.banner { border: 1px solid #5b2f28; background: #1c1210; color: #f0b9ae;
  padding: 10px 14px; margin: 18px 0 0; border-radius: 6px; font-size: 12.5px; }
.banner-line { display: flex; align-items: center; gap: 10px; }
.banner-line span { flex: 1; }
.banner-line span::before { content: "⚠ "; color: var(--err); }
.dismiss { background: none; border: none; color: #f0b9ae77; font-size: 17px;
  cursor: pointer; padding: 0 2px; line-height: 1; font-family: inherit; }
.dismiss:hover { color: #f0b9ae; }
section { margin-top: 34px; animation: rise .45s ease-out backwards; }
section:nth-of-type(2) { animation-delay: .08s; } section:nth-of-type(3) { animation-delay: .16s; }
@keyframes rise { from { opacity: 0; transform: translateY(8px); } }
h2 { font-size: 11px; font-weight: 600; letter-spacing: .28em; text-transform: uppercase;
  color: var(--faint); margin: 0 0 4px; }
.sub { color: var(--dim); font-size: 12px; margin: 0 0 12px; max-width: 74ch; }
.card { border: 1px solid var(--line); border-radius: 8px; background: var(--panel);
  padding: 16px 18px; margin-bottom: 14px; }
.row { display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap; }
.dot { width: 9px; height: 9px; border-radius: 50%; display: inline-block; position: relative; top: -1px; }
.dot.ok   { background: var(--ok);   box-shadow: 0 0 8px 1px #7fd97a66; }
.dot.err  { background: var(--err);  box-shadow: 0 0 8px 1px #ef6b5e66; }
.dot.off  { background: #3a4a3a; }
.dot.ok.live { animation: pulse 2.4s ease-in-out infinite; }
@keyframes pulse { 50% { box-shadow: 0 0 12px 3px #7fd97a55; } }
.name { font-size: 16px; font-weight: 600; color: #eaf5e7; }
.chip { background: var(--chip); border: 1px solid var(--line); color: var(--dim);
  border-radius: 99px; padding: 1.5px 10px; font-size: 11.5px; white-space: nowrap; }
.right { margin-left: auto; color: var(--dim); font-size: 12px; white-space: nowrap; }
.right .ok { color: var(--ok); } .right .err { color: var(--err); }
.desc { color: var(--dim); margin: 7px 0 0; max-width: 62ch; }
.ticks { display: flex; gap: 5px; margin-top: 12px; align-items: center; }
.tick { width: 16px; height: 8px; border-radius: 2px; }
.tick.ok { background: #3f7a44; } .tick.err { background: #a33d33; }
.tick.none { background: #22301f; }
.ticks .lbl { color: var(--faint); font-size: 11px; margin-left: 6px; }
details { margin-top: 12px; border-top: 1px dashed var(--line); padding-top: 10px; }
summary { cursor: pointer; color: var(--dim); font-size: 12px; user-select: none; }
summary:hover { color: var(--ink); }
.run { padding: 8px 0 2px; font-size: 12px; border-bottom: 1px dotted #1c281e; }
.run:last-child { border-bottom: 0; }
.run .ts { color: var(--faint); margin-right: 8px; }
.run .rmeta { color: var(--faint); margin-left: 10px; }
.run .rc-ok { color: var(--ok); } .run .rc-err { color: var(--err); }
.run p { margin: 3px 0 0; color: var(--dim); overflow-wrap: anywhere; }
.kv { color: var(--faint); font-size: 11.5px; margin-top: 10px; overflow-wrap: anywhere; }
table.hooks { border-collapse: collapse; width: 100%; }
table.hooks td { border-top: 1px solid var(--line); padding: 8px 10px 8px 0;
  font-size: 12.5px; vertical-align: top; }
table.hooks td:first-child { color: var(--warn); white-space: nowrap; width: 1%; padding-right: 26px; }
table.hooks td:nth-child(2) { white-space: nowrap; width: 1%; padding-right: 26px; color: var(--ink); }
table.hooks td:last-child { color: var(--dim); }
table.hooks tr:first-child td { border-top: 0; }
.manual .name { font-size: 14px; } .manual .card { padding: 12px 18px; }
footer { margin-top: 44px; color: var(--faint); font-size: 11px;
  border-top: 1px solid var(--line); padding-top: 14px; }
"""

JS = """
// ---- live clock ----
setInterval(() => {
  const el = document.getElementById("clock");
  if (el) el.textContent = new Date().toTimeString().slice(0, 8);
}, 1000);

// ---- content refresh via fetch (keeps the rain running, no page reload) ----
setInterval(async () => {
  try {
    const t = await (await fetch(location.pathname)).text();
    const doc = new DOMParser().parseFromString(t, "text/html");
    const cur = document.querySelector(".wrap"), next = doc.querySelector(".wrap");
    if (cur && next) cur.innerHTML = next.innerHTML;
  } catch (e) {}
}, 60000);

// ---- dismissable failure banner (persists server-side) ----
document.addEventListener("click", async ev => {
  const btn = ev.target.closest(".dismiss");
  if (!btn) return;
  try {
    await fetch("/dismiss", {method: "POST", headers: {"Content-Type": "application/json"},
                             body: JSON.stringify({key: btn.dataset.key})});
  } catch (e) {}
  const banner = btn.closest(".banner");
  btn.closest(".banner-line").remove();
  if (banner && !banner.querySelector(".banner-line")) banner.remove();
});

// ---- matrix rain ----
const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
const cv = document.getElementById("rain"), ctx = cv.getContext("2d");
const GLYPHS = "ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789アイウエオカキクケコサシスセソ";
const CELL = 17;
let cols = 0, drops = [], speeds = [];
function resize() {
  cv.width = innerWidth; cv.height = innerHeight;
  cols = Math.ceil(cv.width / CELL);
  drops = Array.from({length: cols}, () => Math.random() * cv.height / CELL);
  speeds = Array.from({length: cols}, () => 0.22 + Math.random() * 0.33);
  ctx.fillStyle = "#0b100d"; ctx.fillRect(0, 0, cv.width, cv.height);
}
resize();
addEventListener("resize", resize);
let last = 0;
function rain(t) {
  requestAnimationFrame(rain);
  if (t - last < 40) return;                 // ~24 fps cap, easy on the battery
  last = t;
  ctx.fillStyle = "rgba(11, 16, 13, 0.045)";  // fading trails (slow fade = longer streams)
  ctx.fillRect(0, 0, cv.width, cv.height);
  ctx.font = "15px 'IBM Plex Mono', monospace";
  for (let i = 0; i < cols; i++) {
    const y = drops[i] * CELL;
    ctx.fillStyle = Math.random() < 0.06 ? "#7fd97a" : "#295c31";
    ctx.fillText(GLYPHS[(Math.random() * GLYPHS.length) | 0], i * CELL, y);
    drops[i] += speeds[i];
    if (y > cv.height && Math.random() > 0.975) drops[i] = 0;
  }
}
if (!reduced) requestAnimationFrame(rain);

// ---- quotes decoding in and out of the rain ----
const qel = document.getElementById("quote");
const sleep = ms => new Promise(r => setTimeout(r, ms));
const scramble = () => GLYPHS[(Math.random() * GLYPHS.length) | 0];
async function showQuote(text) {
  const chars = [...text];
  const hold = Math.max(3500, chars.length * 45);       // long quotes stay longer
  if (reduced) {
    qel.textContent = text; qel.style.opacity = 1;
    await sleep(hold);
    qel.style.opacity = 0; await sleep(600); qel.textContent = "";
    return;
  }
  qel.style.opacity = 1;
  for (let settled = 0; settled <= chars.length; settled += 3) {   // decode in, L->R
    qel.textContent = chars.map((c, i) =>
      i < settled || c === " " ? c : scramble()).join("");
    await sleep(33);
  }
  qel.textContent = text;
  await sleep(hold);
  for (let alive = chars.length; alive >= 0; alive -= 4) {         // dissolve out
    qel.textContent = chars.slice(0, alive).map((c, i) =>
      i > alive - 12 && c !== " " ? scramble() : c).join("");
    await sleep(28);
  }
  qel.textContent = ""; qel.style.opacity = 0;
}
(async function quoteLoop() {
  if (!QUOTES.length) return;
  let prev = -1;
  await sleep(2000);
  for (;;) {
    let i = (Math.random() * QUOTES.length) | 0;
    if (QUOTES.length > 1 && i === prev) i = (i + 1) % QUOTES.length;
    prev = i;
    await showQuote(QUOTES[i]);
    await sleep(3000);                                   // pause between quotes
  }
})();
"""


def render_workflow(f: Workflow) -> str:
    last = f.runs[0] if f.runs else None
    if last and last.exit == 0:
        dot, last_txt = "ok", f'<span class="ok">✓</span> {e(last.ts)}'
    elif last and last.exit not in (0, None):
        dot, last_txt = "err", f'<span class="err">✗</span> {e(last.ts)} (exit {last.exit})'
    else:
        dot, last_txt = ("ok" if f.loaded else "off"), "no runs logged"
    live = " live" if f.loaded else ""
    nxt = f" · next {e(f.next_run)}" if f.next_run else ""
    loaded_txt = "loaded" if f.loaded else '<span class="err">NOT LOADED</span>'

    ticks = ""
    for r in f.runs[:12][::-1]:
        cls = "ok" if r.ok else ("err" if r.exit is not None else "none")
        ticks += f'<span class="tick {cls}" title="{e(r.ts)} — exit {e(r.exit)}"></span>'
    if ticks:
        costs = [r.cost for r in f.runs[:12] if r.cost is not None]
        spent = f' · ${sum(costs):.2f} spent' if costs else ""
        ticks = f'<div class="ticks">{ticks}<span class="lbl">last {min(len(f.runs), 12)} runs{spent}</span></div>'

    hist = ""
    for r in f.runs[:8]:
        rc = f'<span class="rc-ok">exit 0</span>' if r.ok else f'<span class="rc-err">exit {e(r.exit)}{" · watchdog" if r.watchdog else ""}</span>'
        meta = ""
        if r.cost is not None:
            meta = f'<span class="rmeta">${r.cost:.2f} · {r.turns} turns · {r.dur}s</span>'
        hist += f'<div class="run"><span class="ts">{e(r.ts)}</span>{rc}{meta}<p>{e(r.summary)}</p></div>'
    if hist:
        hist = f'<details><summary>run history</summary>{hist}</details>'

    return f"""
    <div class="card">
      <div class="row">
        <span class="dot {dot}{live}"></span>
        <span class="name">{e(f.name)}</span>
        <span class="chip">{e(f.schedule)}</span>
        <span class="right">last: {last_txt}</span>
      </div>
      <p class="desc">{e(f.description) or "&mdash;"}</p>
      {ticks}
      {hist}
      <div class="kv">{loaded_txt}{nxt} · {e(f.plist.name)} · log: {e(f.log_path.name) if f.log_path else "—"}</div>
    </div>"""


def build_html() -> str:
    commands = load_commands()
    flows = scan_workflows(commands)
    hooks = scan_hooks()
    fails = recent_failures(flows)
    scheduled_names = {f.name for f in flows}
    manual = {n: d for n, d in commands.items() if n not in scheduled_names}

    banner = ""
    if fails:
        lines = "".join(
            f'<div class="banner-line"><span>{e(txt)}</span>'
            f'<button class="dismiss" data-key="{e(key)}" title="Dismiss">×</button></div>'
            for key, txt in fails)
        banner = f'<div class="banner">{lines}</div>'

    manual_html = "".join(
        f'<div class="card"><div class="row"><span class="dot off"></span>'
        f'<span class="name">/{e(n)}</span><span class="right">manual</span></div>'
        f'<p class="desc">{e(d) or "&mdash;"}</p></div>'
        for n, d in sorted(manual.items()))

    hooks_html = ""
    for ev, scripts in hooks:
        for i, (nm, blurb) in enumerate(scripts):
            hooks_html += (f"<tr><td>{e(ev) if i == 0 else ''}</td>"
                           f"<td>{e(nm)}</td><td>{e(blurb) or '&mdash;'}</td></tr>")

    now = datetime.now()
    return f"""<!doctype html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claude Workflows</title>
<link rel="icon" href="{favicon_href()}">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=Instrument+Serif:ital@0;1&display=swap" rel="stylesheet">
<style>{CSS}</style></head><body>
<canvas id="rain"></canvas>
<div id="quote" aria-hidden="true"></div>
<div class="wrap">
  <header>
    <h1>Workflows<span class="tld">.</span></h1>
    <div class="meta"><b id="clock">{now:%H:%M:%S}</b> · {now:%a %d %b}<br>
    scanned {now:%H:%M:%S} · auto-refresh 60s</div>
  </header>
  {banner}
  <section><h2>Scheduled</h2>
    <p class="sub">launchd agents that run Claude (or serve this page) automatically — no session or terminal needed.</p>
    {"".join(render_workflow(f) for f in flows) or '<p class="desc">No launchd agents found.</p>'}</section>
  <section class="manual"><h2>Manual commands</h2>
    <p class="sub">slash commands you run yourself inside a Claude Code session — nothing happens until you type them.</p>
    {manual_html or '<p class="desc">None.</p>'}</section>
  <section><h2>Session hooks</h2>
    <p class="sub">scripts Claude Code fires automatically at the start and end of every session (configured in ~/.claude/settings.json).</p>
    <table class="hooks">{hooks_html or '<tr><td colspan="3">None.</td></tr>'}</table></section>
  <footer>docs: ~/.claude/AUTOMATIONS.md · sources: ~/Library/LaunchAgents · ~/.claude/logs · ~/.claude/commands · ~/.claude/settings.json</footer>
</div>
<script>const QUOTES = {json.dumps(load_quotes(), ensure_ascii=False)};</script>
<script>{JS}</script>
</body></html>"""


# ------------------------------------------------------------------------ server

def serve(port: int, open_browser: bool):
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path not in ("/", "/index.html"):
                self.send_error(404)
                return
            body = build_html().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            if self.path != "/dismiss":
                self.send_error(404)
                return
            try:
                ln = int(self.headers.get("Content-Length", 0))
                key = json.loads(self.rfile.read(ln)).get("key", "")
            except Exception:
                key = ""
            if key:
                d = load_dismissed()
                d.add(key)
                save_dismissed(d)
            self.send_response(204)
            self.end_headers()

        def log_message(self, *args):
            pass

    url = f"http://127.0.0.1:{port}"
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    except OSError:
        # Already being served (e.g. by the launchd agent) — just show it.
        print(f"Dashboard already running → {url}")
        if open_browser and sys.platform == "darwin":
            subprocess.run(["open", url], check=False)
        return
    print(f"Claude Workflows dashboard → {url}  (Ctrl-C to stop)")
    if open_browser and sys.platform == "darwin":
        threading.Timer(0.3, lambda: subprocess.run(["open", url], check=False)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--no-open", action="store_true")
    ap.add_argument("--dump", action="store_true", help="print HTML to stdout and exit")
    args = ap.parse_args()
    if args.dump:
        print(build_html())
    else:
        serve(args.port, not args.no_open)


if __name__ == "__main__":
    main()

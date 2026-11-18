#!/usr/bin/env python3
"""CCyclops dashboard — single-file, stdlib-only status page.

Scans on every request (a browser refresh always shows live state):
  * ~/Library/LaunchAgents/*.plist        -> scheduled Claude workflows
      (agents whose label mentions "claude" or whose program touches ~/.claude)
  * launchctl list                        -> loaded state / last exit status
  * ~/.claude/logs/<name>-cron.log        -> run history (=== ... start === / === exit: N === blocks)
  * ~/.claude/commands/*.md frontmatter   -> descriptions + manual commands
  * ~/.claude/settings.json               -> session hooks
  * ~/.claude/ccyclops/config.sh          -> port and config location (written by install.sh)
  * ~/.claude/ccyclops/job-models.json    -> the model picked per job in the dropdown (read by run-job.sh)

Usage:
  ccyclops                  serve on http://127.0.0.1:<DASHBOARD_PORT> (default 8787) and open the browser
  ccyclops --port 9000      serve on another port
  ccyclops --no-open        don't open the browser
  ccyclops --dump           print the HTML once to stdout (no server)
  ccyclops --dump --lang sv print it in Swedish (the server uses the page's lang cookie instead)
"""

import argparse
import base64
import html
import json
import plistlib
import re
import shlex
import subprocess
import sys
import threading
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from http.cookies import CookieError, SimpleCookie
from pathlib import Path

HOME = Path.home()
LAUNCH_AGENTS = HOME / "Library" / "LaunchAgents"
CLAUDE_DIR = HOME / ".claude"
LOGS_DIR = CLAUDE_DIR / "logs"
COMMANDS_DIR = CLAUDE_DIR / "commands"
SETTINGS = CLAUDE_DIR / "settings.json"

QUOTES_FILE = Path(__file__).with_name("workflows-quotes.json")
QUOTES_LOCK = threading.Lock()
QUOTE_MAX = 500   # characters per quote, after trimming
DISMISSED_FILE = CLAUDE_DIR / "cache" / "workflows-dismissed.json"
CONFIG_FILE = CLAUDE_DIR / "ccyclops" / "config.sh"
MODELS_FILE = CLAUDE_DIR / "ccyclops" / "job-models.json"   # {"<job>": "<model>"}
MODEL_CHOICES = ("opus", "sonnet", "haiku")
MODELS_LOCK = threading.Lock()
PAUSED_FILE = CLAUDE_DIR / "ccyclops" / "job-paused.json"   # {"<job>": true}
PAUSED_LOCK = threading.Lock()


def load_config() -> dict:
    """KEY -> value from the installed config (install.sh writes it shell-quoted)."""
    out = {}
    try:
        lines = CONFIG_FILE.read_text().splitlines()
    except OSError:
        return out
    for line in lines:
        m = re.match(r"([A-Za-z_]\w*)=(.*)$", line)
        if m:
            try:
                out[m[1]] = "".join(shlex.split(m[2]))
            except ValueError:
                pass
    return out


CONFIG = load_config()
PORT = int(CONFIG.get("DASHBOARD_PORT") or 8787)

# The dashboard's own agent is labelled claude-workflows; show it as what it is.
DISPLAY_NAMES = {"workflows": "dashboard"}

# Hand-written descriptions win over anything derived from files (keys into STRINGS).
DESCRIPTIONS = {"workflows": "desc_workflows"}

# Every string the dashboard itself produces, per language. User data (job names,
# descriptions, run summaries, file names, quotes) is never translated.
STRINGS = {
    "en": {
        "days": ("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"),
        "months": ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"),
        "lang_switch": "Switch the dashboard to Swedish",
        "scanned": "scanned {time} · auto-refresh 60s",
        "scheduled": "Scheduled",
        "scheduled_sub": "launchd agents that run Claude (or serve this page) automatically — no session or terminal needed.",
        "no_agents": "No launchd agents found.",
        "manual_h": "Manual commands",
        "manual_sub": "slash commands you run yourself inside a Claude Code session — nothing happens until you type them.",
        "manual": "manual",
        "none": "None.",
        "hooks_h": "Session hooks",
        "hooks_sub": "scripts Claude Code fires automatically at the start and end of every session (configured in ~/.claude/settings.json).",
        "footer": "settings: {config} — edit it, then run ./install.sh · sources: ~/Library/LaunchAgents · ~/.claude/logs · ~/.claude/commands · ~/.claude/settings.json",
        "footer_config": "config.sh in your clone",
        "dismiss": "Dismiss",
        "failed": "{ts} — {name} failed ({why})",
        "watchdog_timeout": "watchdog timeout",
        "exit": "exit {code}",
        "no_runs": "no runs logged",
        "next": "next {when}",
        "paused": "paused · {schedule}",
        "loaded": "loaded",
        "not_loaded": "NOT LOADED",
        "last": "last:",
        "last_runs": "last {n} runs",
        "spent": "${cost:.2f} spent",
        "run_history": "run history",
        "watchdog": "watchdog",
        "turns": "{n} turns",
        "log": "log:",
        "model_default": "default · {model}",
        "claude_code": "Claude Code",
        "model_title": "Model for this job — used from its next run",
        "model_err": "could not save the model",
        "pause": "pause",
        "resume": "resume",
        "pause_tip": "Skip this job's runs until you resume it",
        "resume_tip": "Paused — scheduled and manual runs are skipped until you resume it",
        "pause_err": "could not save the pause state",
        "quotes_h": "Quotes",
        "quotes_sub": "the lines that decode in the rain behind this page — saved to workflows-quotes.json, which you can still edit by hand.",
        "quote_edit": "edit",
        "quote_edit_tip": "Edit this quote",
        "quote_delete": "delete",
        "quote_delete_tip": "Delete this quote",
        "quote_save": "save",
        "quote_save_tip": "Save the edited quote",
        "quote_cancel": "cancel",
        "quote_cancel_tip": "Discard the edit",
        "quote_new": "A new quote",
        "quote_add": "add",
        "quote_add_tip": "Add this quote to the rain",
        "quotes_err": "could not save the quotes — each one must be 1–500 characters",
        "daily": "Daily",
        "weekdays": "Weekdays",
        "weekends": "Weekends",
        "always_on": "always on",
        "every": "every {n}",
        "on_demand": "on demand",
        "today": "today",
        "tomorrow": "tomorrow",
        "no_output": "(no output captured)",
        "desc_workflows": "This dashboard — serves this page at localhost:{port}, always running, "
                          "listing every Claude automation on this Mac.",
    },
    "sv": {
        "days": ("sön", "mån", "tis", "ons", "tor", "fre", "lör"),
        "months": ("jan", "feb", "mar", "apr", "maj", "jun", "jul", "aug", "sep", "okt", "nov", "dec"),
        "lang_switch": "Byt panelen till engelska",
        "scanned": "skannad {time} · uppdateras var 60:e s",
        "scheduled": "Schemalagt",
        "scheduled_sub": "launchd-agenter som kör Claude (eller serverar den här sidan) automatiskt — ingen session eller terminal behövs.",
        "no_agents": "Inga launchd-agenter hittades.",
        "manual_h": "Manuella kommandon",
        "manual_sub": "snedstreckskommandon du kör själv i en Claude Code-session — inget händer förrän du skriver dem.",
        "manual": "manuell",
        "none": "Inga.",
        "hooks_h": "Sessionskrokar",
        "hooks_sub": "skript som Claude Code kör automatiskt i början och slutet av varje session (inställda i ~/.claude/settings.json).",
        "footer": "inställningar: {config} — redigera den och kör sedan ./install.sh · källor: ~/Library/LaunchAgents · ~/.claude/logs · ~/.claude/commands · ~/.claude/settings.json",
        "footer_config": "config.sh i din klon",
        "dismiss": "Avfärda",
        "failed": "{ts} — {name} misslyckades ({why})",
        "watchdog_timeout": "watchdog-tidsgräns",
        "exit": "slutkod {code}",
        "no_runs": "inga körningar loggade",
        "next": "nästa {when}",
        "paused": "pausad · {schedule}",
        "loaded": "laddad",
        "not_loaded": "INTE LADDAD",
        "last": "senast:",
        "last_runs": "senaste {n} körningarna",
        "spent": "${cost:.2f} förbrukat",
        "run_history": "körhistorik",
        "watchdog": "watchdog",
        "turns": "{n} turer",
        "log": "logg:",
        "model_default": "standard · {model}",
        "claude_code": "Claude Code",
        "model_title": "Modell för det här jobbet — används från nästa körning",
        "model_err": "kunde inte spara modellen",
        "pause": "pausa",
        "resume": "återuppta",
        "pause_tip": "Hoppa över jobbets körningar tills du återupptar det",
        "resume_tip": "Pausad — schemalagda och manuella körningar hoppas över tills du återupptar det",
        "pause_err": "kunde inte spara pausläget",
        "quotes_h": "Citat",
        "quotes_sub": "raderna som avkodas i regnet bakom sidan — sparas i workflows-quotes.json, som du fortfarande kan redigera för hand.",
        "quote_edit": "redigera",
        "quote_edit_tip": "Redigera citatet",
        "quote_delete": "ta bort",
        "quote_delete_tip": "Ta bort citatet",
        "quote_save": "spara",
        "quote_save_tip": "Spara det redigerade citatet",
        "quote_cancel": "avbryt",
        "quote_cancel_tip": "Släng ändringen",
        "quote_new": "Ett nytt citat",
        "quote_add": "lägg till",
        "quote_add_tip": "Lägg till citatet i regnet",
        "quotes_err": "kunde inte spara citaten — vart och ett måste vara 1–500 tecken",
        "daily": "Dagligen",
        "weekdays": "Vardagar",
        "weekends": "Helger",
        "always_on": "alltid på",
        "every": "var {n}",
        "on_demand": "vid behov",
        "today": "idag",
        "tomorrow": "imorgon",
        "no_output": "(ingen utdata fångades)",
        "desc_workflows": "Den här panelen — serverar sidan på localhost:{port}, körs alltid "
                          "och listar varje Claude-automation på den här Macen.",
    },
}


def tr(lang: str, key: str, **kw) -> str:
    s = STRINGS[lang][key]
    return s.format(**kw) if kw else s


def weekday(lang: str, dt: datetime) -> str:
    return STRINGS[lang]["days"][dt.isoweekday() % 7]


def request_lang(cookie_header: str) -> str:
    """The page language from a Cookie header: exactly "en" or "sv", else "en"."""
    jar = SimpleCookie()
    try:
        jar.load(cookie_header or "")
    except CookieError:
        return "en"
    m = jar.get("lang")
    return m.value if m and m.value in STRINGS else "en"


# --------------------------------------------------------------------------- data

@dataclass
class Run:
    ts: str                      # "2026-09-01 09:06"
    exit: int | None             # None = still running / no exit marker yet
    summary: str
    body: str
    watchdog: bool = False
    cost: float | None = None    # from run-job.sh's "meta: cost $X · N turns · Ns" line
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
    default_model: str | None = None   # set for run-job.sh jobs; "" = the Claude Code default


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


def frontmatter_field(md: Path, key: str) -> str:
    m = re.match(r"\A---\n(.*?)\n---", read_text(md), re.S)
    if not m:
        return ""
    d = re.search(rf"^{re.escape(key)}:[ \t]*(.+)$", m.group(1), re.M)
    return d.group(1).strip() if d else ""


def frontmatter_description(md: Path) -> str:
    return first_sentence(frontmatter_field(md, "description"))


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

def humanize_schedule(plist: dict, lang: str = "en") -> str:
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
                parts.append(f"{tr(lang, 'daily')} {t}")
            elif days == {1, 2, 3, 4, 5}:
                parts.append(f"{tr(lang, 'weekdays')} {t}")
            elif days == {0, 6}:
                parts.append(f"{tr(lang, 'weekends')} {t}")
            else:
                names = "/".join(STRINGS[lang]["days"][d] for d in sorted(days))
                parts.append(f"{names} {t}")
        return " · ".join(parts)
    if plist.get("KeepAlive"):
        return tr(lang, "always_on")
    if "StartInterval" in plist:
        s = int(plist["StartInterval"])
        if s % 3600 == 0:
            return tr(lang, "every", n=f"{s // 3600}h")
        if s % 60 == 0:
            return tr(lang, "every", n=f"{s // 60}m")
        return tr(lang, "every", n=f"{s}s")
    return tr(lang, "on_demand")


def next_run_text(plist: dict, lang: str = "en") -> str:
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
        return f"{tr(lang, 'today')} {best:%H:%M}"
    if best.date() == (now + timedelta(days=1)).date():
        return f"{tr(lang, 'tomorrow')} {best:%H:%M}"
    return f"{weekday(lang, best)} {best:%H:%M}"


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

def scan_workflows(commands: dict, lang: str = "en") -> list:
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
        description = ((tr(lang, DESCRIPTIONS[name], port=PORT) if name in DESCRIPTIONS else "")
                       or commands.get(name, "")
                       or script_blurb(Path(str(script))))
        log = find_log(name, data)
        loaded, status = state.get(label, (False, "not loaded"))
        default_model = None
        if str(script).endswith("/run-job.sh"):  # same fallback as run-job.sh: model: line, then MODEL
            default_model = frontmatter_field(COMMANDS_DIR / f"{name}.md", "model") or CONFIG.get("MODEL", "")
        flows.append(Workflow(
            name=name, label=label, plist=pl,
            schedule=humanize_schedule(data, lang), next_run=next_run_text(data, lang),
            description=description, program=str(script),
            log_path=log, runs=parse_runs(log)[::-1] if log else [],
            loaded=loaded, launchctl_status=status, default_model=default_model,
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


def load_models() -> dict:
    try:
        d = json.loads(read_text(MODELS_FILE))
        return {k: v for k, v in d.items() if isinstance(v, str) and v}
    except Exception:
        return {}


def set_job_model(name: str, model: str) -> dict:
    """Pin a job to a model; "" puts it back on its default. Applies from the next run."""
    flow = next((f for f in scan_workflows(load_commands()) if f.name == name), None)
    if not flow or flow.default_model is None:
        return {"ok": False, "error": f"no job named {name!r}"}
    if model and model not in MODEL_CHOICES:
        return {"ok": False, "error": f"unknown model {model!r}"}
    with MODELS_LOCK:
        models = load_models()
        if model:
            models[name] = model
        else:
            models.pop(name, None)
        MODELS_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = MODELS_FILE.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(models, indent=1, sort_keys=True) + "\n")
        tmp.replace(MODELS_FILE)
    return {"ok": True}


def load_paused() -> set:
    try:
        d = json.loads(read_text(PAUSED_FILE))
        return {k for k, v in d.items() if v is True}
    except Exception:
        return set()


def set_job_paused(name: str, paused) -> dict:
    """Pause a job (run-job.sh skips it, launchd or by hand) or resume it. Applies from the next run."""
    flow = next((f for f in scan_workflows(load_commands()) if f.name == name), None)
    if not flow or flow.default_model is None:
        return {"ok": False, "error": f"no job named {name!r}"}
    if not isinstance(paused, bool):
        return {"ok": False, "error": "paused must be true or false"}
    with PAUSED_LOCK:
        jobs = {k: True for k in load_paused()}
        if paused:
            jobs[name] = True
        else:
            jobs.pop(name, None)
        PAUSED_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = PAUSED_FILE.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(jobs, indent=1, sort_keys=True) + "\n")
        tmp.replace(PAUSED_FILE)
    return {"ok": True}


def load_quotes() -> list:
    try:
        q = json.loads(read_text(QUOTES_FILE)).get("quotes", [])
        return [s for s in q if isinstance(s, str) and s.strip()]
    except Exception:
        return []


def set_quotes(quotes) -> dict:
    """Replace the whole list of quotes; other top-level keys in the file are kept."""
    if not isinstance(quotes, list):
        return {"ok": False, "error": "quotes must be a list"}
    clean = []
    for q in quotes:
        if not isinstance(q, str):
            return {"ok": False, "error": "every quote must be a string"}
        q = q.strip()
        if not q or len(q) > QUOTE_MAX:
            return {"ok": False, "error": f"every quote must be 1-{QUOTE_MAX} characters"}
        clean.append(q)
    with QUOTES_LOCK:
        text = read_text(QUOTES_FILE)
        try:
            data = json.loads(text) if text.strip() else {}
        except ValueError:
            data = None
        if not isinstance(data, dict):  # hand-edited into something else: don't overwrite it
            return {"ok": False, "error": f"{QUOTES_FILE.name} is not a JSON object"}
        data["quotes"] = clean
        tmp = QUOTES_FILE.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        tmp.replace(QUOTES_FILE)
    return {"ok": True, "quotes": clean}


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


def recent_failures(flows: list, lang: str = "en", days: int = 7) -> list:
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
                why = tr(lang, "watchdog_timeout") if r.watchdog else tr(lang, "exit", code=r.exit)
                fails.append((key, tr(lang, "failed", ts=r.ts, name=f.name, why=why)))
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
.meta { position: relative; text-align: right; color: var(--dim); font-size: 12px; }
.meta b { color: var(--ink); font-weight: 500; }
/* out of flow, so the header's baseline (h1 + clock line) doesn't move */
.langbtn { position: absolute; right: 0; bottom: calc(100% + 6px);
  display: inline-flex; align-items: center; gap: 5px;
  background: var(--chip); border: 1px solid var(--line); color: var(--dim);
  border-radius: 99px; padding: 1.5px 10px; font: inherit; font-size: 11.5px; cursor: pointer; }
.langbtn:hover, .langbtn:focus { outline: none; border-color: var(--ok); color: var(--ink); }
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
.dot.warn { background: var(--warn); box-shadow: 0 0 8px 1px #e8b04b66; }
.dot.ok.live { animation: pulse 2.4s ease-in-out infinite; }
@keyframes pulse { 50% { box-shadow: 0 0 12px 3px #7fd97a55; } }
.name { font-size: 16px; font-weight: 600; color: #eaf5e7; }
.chip { background: var(--chip); border: 1px solid var(--line); color: var(--dim);
  border-radius: 99px; padding: 1.5px 10px; font-size: 11.5px; white-space: nowrap; }
.modelsel { background: var(--chip); border: 1px solid var(--line); color: var(--dim);
  border-radius: 99px; padding: 1.5px 6px; font: inherit; font-size: 11.5px; cursor: pointer; }
.modelsel:hover, .modelsel:focus { outline: none; border-color: var(--ok); color: var(--ink); }
.modelsel.err { border-color: var(--err); color: var(--err); }
.pausebtn { background: var(--chip); border: 1px solid var(--line); color: var(--dim);
  border-radius: 99px; padding: 1.5px 10px; font: inherit; font-size: 11.5px; cursor: pointer; }
.pausebtn:hover, .pausebtn:focus { outline: none; border-color: var(--ok); color: var(--ink); }
.pausebtn.err { border-color: var(--err); color: var(--err); }
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
.qrow { display: flex; align-items: baseline; gap: 8px; border-top: 1px solid var(--line); padding: 7px 0; }
.qrow:first-child { border-top: 0; padding-top: 0; }
.qtext { flex: 1; white-space: pre-wrap; overflow-wrap: anywhere; }
.qrow .qinput, .qrow .qsave, .qrow .qcancel { display: none; }
.qrow.editing .qinput, .qrow.editing .qsave, .qrow.editing .qcancel { display: inline-block; }
.qrow.editing .qtext, .qrow.editing .qedit, .qrow.editing .qdel { display: none; }
.qinput, .qnew { flex: 1; background: var(--panel2); border: 1px solid var(--line); color: var(--ink);
  border-radius: 6px; padding: 4px 8px; font: inherit; font-size: 12.5px; resize: vertical; }
.qinput:focus, .qnew:focus { outline: none; border-color: var(--ok); }
.qadd { display: flex; align-items: baseline; gap: 8px; margin-top: 12px; }
.qbtn { background: var(--chip); border: 1px solid var(--line); color: var(--dim);
  border-radius: 99px; padding: 1.5px 10px; font: inherit; font-size: 11.5px; cursor: pointer; }
.qbtn:hover, .qbtn:focus { outline: none; border-color: var(--ok); color: var(--ink); }
.qerr { display: none; color: var(--err); font-size: 12px; margin: 8px 0 0; }
.quotes.err .qerr { display: block; }
.quotes.err .qrow.editing .qinput, .quotes.err .qnew { border-color: var(--err); }
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
// force: also replace a Quotes section that is being edited (after it was saved)
async function refresh(force) {
  try {
    const t = await (await fetch(location.pathname)).text();
    const doc = new DOMParser().parseFromString(t, "text/html");
    const cur = document.querySelector(".wrap"), next = doc.querySelector(".wrap");
    if (!cur || !next) return;
    const keep = !force && quotesBusy() && cur.querySelector(".quotes");
    const nq = next.querySelector(".quotes");
    if (!keep || !nq) { cur.innerHTML = next.innerHTML; return; }
    // swap everything around the Quotes section, which stays as it is (focus, typed text)
    [...cur.childNodes].forEach(n => { if (n !== keep) n.remove(); });
    while (next.firstChild !== nq) keep.before(next.firstChild);
    while (nq.nextSibling) cur.append(nq.nextSibling);
  } catch (e) {}
}
setInterval(refresh, 60000);

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

// ---- per-job model dropdown (persists server-side, used from the job's next run) ----
document.addEventListener("change", async ev => {
  const sel = ev.target.closest(".modelsel");
  if (!sel) return;
  let ok = false;
  try {
    const r = await fetch("/model", {method: "POST", headers: {"Content-Type": "application/json"},
                                     body: JSON.stringify({name: sel.dataset.name, model: sel.value})});
    ok = r.ok;
  } catch (e) {}
  sel.classList.toggle("err", !ok);
  sel.title = ok ? sel.dataset.title : sel.dataset.err;
});

// ---- per-job pause toggle (persists server-side, run-job.sh skips a paused job) ----
document.addEventListener("click", async ev => {
  const btn = ev.target.closest(".pausebtn");
  if (!btn) return;
  let ok = false;
  try {
    const r = await fetch("/pause", {method: "POST", headers: {"Content-Type": "application/json"},
                                     body: JSON.stringify({name: btn.dataset.name, paused: btn.dataset.paused !== "true"})});
    ok = r.ok;
  } catch (e) {}
  if (ok) return refresh();
  btn.classList.add("err");
  btn.title = btn.dataset.err;
});

// ---- quotes in the rain: add, edit, delete (persists server-side, the rain uses the new list) ----
function quotesBusy() {   // typed but not saved, or being typed: refresh() leaves the section alone
  const s = document.querySelector(".quotes");
  if (!s) return false;
  const a = document.activeElement;
  return (s.contains(a) && a.matches("input, textarea")) || !!s.querySelector(".qrow.editing")
    || [...s.querySelectorAll("input, textarea")].some(i => i.value !== i.defaultValue);
}
async function saveQuotes(s, list) {
  let res = null;
  try {
    const r = await fetch("/quotes", {method: "POST", headers: {"Content-Type": "application/json"},
                                      body: JSON.stringify({quotes: list})});
    if (r.ok) res = await r.json();
  } catch (e) {}
  if (!res || !res.ok) return s.classList.add("err");   // typed text stays where it is
  QUOTES = res.quotes;                                   // the rain picks from the new list
  refresh(true);
}
document.addEventListener("click", ev => {
  const btn = ev.target.closest(".quotes button");
  if (!btn) return;
  const s = btn.closest(".quotes"), rows = [...s.querySelectorAll(".qrow")];
  const row = btn.closest(".qrow"), i = rows.indexOf(row), ta = row && row.querySelector(".qinput");
  const saved = rows.map(r => r.dataset.q);
  if (btn.classList.contains("qedit")) {
    row.classList.add("editing");
    ta.focus();
  } else if (btn.classList.contains("qcancel")) {
    ta.value = ta.defaultValue;
    row.classList.remove("editing");
    s.classList.remove("err");
  } else if (btn.classList.contains("qsave")) {
    saved[i] = ta.value;
    saveQuotes(s, saved);
  } else if (btn.classList.contains("qdel")) {
    saved.splice(i, 1);
    saveQuotes(s, saved);
  } else if (btn.classList.contains("qaddbtn")) {
    saveQuotes(s, [...saved, s.querySelector(".qnew").value]);
  }
});

// ---- language toggle (a cookie the server renders from, so refreshes and reloads keep it) ----
document.addEventListener("click", ev => {
  const btn = ev.target.closest(".langbtn");
  if (!btn) return;
  const lang = btn.dataset.lang;
  document.cookie = `lang=${lang}; path=/; max-age=31536000; SameSite=Lax`;
  document.documentElement.lang = lang;
  refresh();
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
  let prev = -1;
  await sleep(2000);
  for (;;) {
    if (!QUOTES.length) { await sleep(1000); continue; }   // until a quote is added on the page
    let i = (Math.random() * QUOTES.length) | 0;
    if (QUOTES.length > 1 && i === prev) i = (i + 1) % QUOTES.length;
    prev = i;
    await showQuote(QUOTES[i]);
    await sleep(3000);                                   // pause between quotes
  }
})();
"""


def render_workflow(f: Workflow, models: dict, paused: set, lang: str = "en") -> str:
    last = f.runs[0] if f.runs else None
    if last and last.exit == 0:
        dot, last_txt = "ok", f'<span class="ok">✓</span> {e(last.ts)}'
    elif last and last.exit not in (0, None):
        dot, last_txt = "err", f'<span class="err">✗</span> {e(last.ts)} ({e(tr(lang, "exit", code=last.exit))})'
    else:
        dot, last_txt = ("ok" if f.loaded else "off"), e(tr(lang, "no_runs"))
    live = " live" if f.loaded else ""
    nxt = f" · {e(tr(lang, 'next', when=f.next_run))}" if f.next_run else ""
    schedule = e(f.schedule)
    is_paused = f.default_model is not None and f.name in paused
    if is_paused:
        dot, live, nxt, schedule = "warn", "", "", e(tr(lang, "paused", schedule=f.schedule))
    loaded_txt = e(tr(lang, "loaded")) if f.loaded else f'<span class="err">{e(tr(lang, "not_loaded"))}</span>'

    ticks = ""
    for r in f.runs[:12][::-1]:
        cls = "ok" if r.ok else ("err" if r.exit is not None else "none")
        ticks += f'<span class="tick {cls}" title="{e(r.ts)} — {e(tr(lang, "exit", code=r.exit))}"></span>'
    if ticks:
        costs = [r.cost for r in f.runs[:12] if r.cost is not None]
        spent = f' · {e(tr(lang, "spent", cost=sum(costs)))}' if costs else ""
        ticks = (f'<div class="ticks">{ticks}<span class="lbl">'
                 f'{e(tr(lang, "last_runs", n=min(len(f.runs), 12)))}{spent}</span></div>')

    hist = ""
    for r in f.runs[:8]:
        if r.ok:
            rc = f'<span class="rc-ok">{e(tr(lang, "exit", code=0))}</span>'
        else:
            wd = f' · {e(tr(lang, "watchdog"))}' if r.watchdog else ""
            rc = f'<span class="rc-err">{e(tr(lang, "exit", code=r.exit))}{wd}</span>'
        meta = ""
        if r.cost is not None:
            meta = f'<span class="rmeta">${r.cost:.2f} · {e(tr(lang, "turns", n=r.turns))} · {r.dur}s</span>'
        hist += f'<div class="run"><span class="ts">{e(r.ts)}</span>{rc}{meta}<p>{e(r.summary or tr(lang, "no_output"))}</p></div>'
    if hist:
        hist = f'<details><summary>{e(tr(lang, "run_history"))}</summary>{hist}</details>'

    model_sel = ""
    if f.default_model is not None:
        picked = models.get(f.name, "")
        choices = MODEL_CHOICES if picked in ("", *MODEL_CHOICES) else (*MODEL_CHOICES, picked)  # hand-edited
        default = tr(lang, "model_default", model=f.default_model or tr(lang, "claude_code"))
        opts = f'<option value="">{e(default)}</option>' + "".join(
            f'<option value="{e(m)}"{" selected" if m == picked else ""}>{e(m)}</option>' for m in choices)
        title = e(tr(lang, "model_title"))
        model_sel = (f'<select class="modelsel" data-name="{e(f.name)}" title="{title}" '
                     f'data-title="{title}" data-err="{e(tr(lang, "model_err"))}">{opts}</select>')

    pause_btn = ""
    if f.default_model is not None:
        state, label, tip = (("true", "resume", "resume_tip") if is_paused else ("false", "pause", "pause_tip"))
        pause_btn = (f'<button class="pausebtn" data-name="{e(f.name)}" data-paused="{state}" '
                     f'data-err="{e(tr(lang, "pause_err"))}" title="{e(tr(lang, tip))}">{e(tr(lang, label))}</button>')

    return f"""
    <div class="card">
      <div class="row">
        <span class="dot {dot}{live}"></span>
        <span class="name">{e(DISPLAY_NAMES.get(f.name, f.name))}</span>
        <span class="chip">{schedule}</span>
        {model_sel}
        {pause_btn}
        <span class="right">{e(tr(lang, "last"))} {last_txt}</span>
      </div>
      <p class="desc">{e(f.description) or "&mdash;"}</p>
      {ticks}
      {hist}
      <div class="kv">{loaded_txt}{nxt} · {e(f.plist.name)} · {e(tr(lang, "log"))} {e(f.log_path.name) if f.log_path else "—"}</div>
    </div>"""


def build_html(lang: str = "en") -> str:
    commands = load_commands()
    flows = scan_workflows(commands, lang)
    models = load_models()
    paused = load_paused()
    hooks = scan_hooks()
    fails = recent_failures(flows, lang)
    scheduled_names = {f.name for f in flows}
    manual = {n: d for n, d in commands.items() if n not in scheduled_names}

    banner = ""
    if fails:
        lines = "".join(
            f'<div class="banner-line"><span>{e(txt)}</span>'
            f'<button class="dismiss" data-key="{e(key)}" title="{e(tr(lang, "dismiss"))}">×</button></div>'
            for key, txt in fails)
        banner = f'<div class="banner">{lines}</div>'

    manual_html = "".join(
        f'<div class="card"><div class="row"><span class="dot off"></span>'
        f'<span class="name">/{e(n)}</span><span class="right">{e(tr(lang, "manual"))}</span></div>'
        f'<p class="desc">{e(d) or "&mdash;"}</p></div>'
        for n, d in sorted(manual.items()))

    hooks_html = ""
    for ev, scripts in hooks:
        for i, (nm, blurb) in enumerate(scripts):
            hooks_html += (f"<tr><td>{e(ev) if i == 0 else ''}</td>"
                           f"<td>{e(nm)}</td><td>{e(blurb) or '&mdash;'}</td></tr>")

    quotes = load_quotes()

    def qbtn(cls, label, tip):
        return f'<button class="qbtn {cls}" title="{e(tr(lang, tip))}">{e(tr(lang, label))}</button>'
    quotes_html = "".join(
        f'<div class="qrow" data-q="{e(q)}"><span class="qtext">{e(q)}</span>'
        f'<textarea class="qinput" rows="2" aria-label="{e(tr(lang, "quote_edit_tip"))}">{e(q)}</textarea>'
        f'{qbtn("qedit", "quote_edit", "quote_edit_tip")}{qbtn("qdel", "quote_delete", "quote_delete_tip")}'
        f'{qbtn("qsave", "quote_save", "quote_save_tip")}{qbtn("qcancel", "quote_cancel", "quote_cancel_tip")}</div>'
        for q in quotes)
    quote_new = e(tr(lang, "quote_new"))
    quotes_js = json.dumps(quotes, ensure_ascii=False).replace("</", "<\\/")  # a quote can't end the <script>

    now = datetime.now()
    today = f"{weekday(lang, now)} {now:%d} {STRINGS[lang]['months'][now.month - 1]}"
    scanned = tr(lang, "scanned", time=f"{now:%H:%M:%S}")
    other = "sv" if lang == "en" else "en"
    switch = e(tr(lang, "lang_switch"))
    globe = ('<svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" '
             'stroke-width="1.3" aria-hidden="true"><circle cx="8" cy="8" r="6.5"/>'
             '<ellipse cx="8" cy="8" rx="3" ry="6.5"/><path d="M1.5 8h13"/></svg>')
    footer = tr(lang, "footer", config=CONFIG.get("CCYCLOPS_CONFIG") or tr(lang, "footer_config"))
    no_agents = f'<p class="desc">{e(tr(lang, "no_agents"))}</p>'
    none = e(tr(lang, "none"))
    return f"""<!doctype html><html lang="{lang}"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>CCyclops</title>
<link rel="icon" href="{favicon_href()}">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=Instrument+Serif:ital@0;1&display=swap" rel="stylesheet">
<style>{CSS}</style></head><body>
<canvas id="rain"></canvas>
<div id="quote" aria-hidden="true"></div>
<div class="wrap">
  <header>
    <h1>CCyclops<span class="tld">.</span></h1>
    <div class="meta"><button class="langbtn" data-lang="{other}" title="{switch}" aria-label="{switch}">{globe}{other.upper()}</button>
    <b id="clock">{now:%H:%M:%S}</b> · {e(today)}<br>
    {e(scanned)}</div>
  </header>
  {banner}
  <section><h2>{e(tr(lang, "scheduled"))}</h2>
    <p class="sub">{e(tr(lang, "scheduled_sub"))}</p>
    {"".join(render_workflow(f, models, paused, lang) for f in flows) or no_agents}</section>
  <section class="manual"><h2>{e(tr(lang, "manual_h"))}</h2>
    <p class="sub">{e(tr(lang, "manual_sub"))}</p>
    {manual_html or f'<p class="desc">{none}</p>'}</section>
  <section><h2>{e(tr(lang, "hooks_h"))}</h2>
    <p class="sub">{e(tr(lang, "hooks_sub"))}</p>
    <table class="hooks">{hooks_html or f'<tr><td colspan="3">{none}</td></tr>'}</table></section>
  <section class="quotes"><h2>{e(tr(lang, "quotes_h"))}</h2>
    <p class="sub">{e(tr(lang, "quotes_sub"))}</p>
    <div class="card">{quotes_html or f'<p class="desc">{none}</p>'}
      <div class="qadd"><input class="qnew" type="text" placeholder="{quote_new}" aria-label="{quote_new}">{qbtn("qaddbtn", "quote_add", "quote_add_tip")}</div>
      <p class="qerr" role="alert">{e(tr(lang, "quotes_err"))}</p></div></section>
  <footer>{e(footer)}</footer>
</div>
<script>let QUOTES = {quotes_js};</script>
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
            body = build_html(request_lang(self.headers.get("Cookie", ""))).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            if self.path == "/model":
                # JSON only: forces a CORS preflight (never answered), so another
                # web page can't change a job's model through this localhost server
                try:
                    assert self.headers.get("Content-Type", "").startswith("application/json")
                    req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
                    res = set_job_model(str(req.get("name", "")), str(req.get("model", "")))
                except Exception:
                    res = {"ok": False, "error": "bad request"}
                body = json.dumps(res).encode()
                self.send_response(200 if res["ok"] else 400)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if self.path == "/pause":
                # JSON only, for the same reason as /model
                try:
                    assert self.headers.get("Content-Type", "").startswith("application/json")
                    req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
                    res = set_job_paused(str(req.get("name", "")), req.get("paused"))
                except Exception:
                    res = {"ok": False, "error": "bad request"}
                body = json.dumps(res).encode()
                self.send_response(200 if res["ok"] else 400)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if self.path == "/quotes":
                # JSON only, for the same reason as /model
                try:
                    assert self.headers.get("Content-Type", "").startswith("application/json")
                    req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
                    res = set_quotes(req.get("quotes"))
                except Exception:
                    res = {"ok": False, "error": "bad request"}
                body = json.dumps(res).encode()
                self.send_response(200 if res["ok"] else 400)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
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
    print(f"CCyclops dashboard → {url}  (Ctrl-C to stop)")
    if open_browser and sys.platform == "darwin":
        threading.Timer(0.3, lambda: subprocess.run(["open", url], check=False)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--no-open", action="store_true")
    ap.add_argument("--dump", action="store_true", help="print HTML to stdout and exit")
    ap.add_argument("--lang", choices=tuple(STRINGS), default="en", help="language of --dump")
    args = ap.parse_args()
    if args.dump:
        print(build_html(args.lang))
    else:
        serve(args.port, not args.no_open)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Install-time helper for install.sh — the parts bash is bad at. Stdlib only.

install.sh sources config.example.sh and then config.sh with `set -a`, so every
config value arrives here as an environment variable.

  check <commands-dir> <hooks-dir>     validate the config; errors exit 1
  render <src> <dst>                   copy a template, replacing {{KEY}} with config values
  plist <job> <schedule> <dst>         launchd agent for a scheduled job
  dashboard-plist <dst>                launchd agent for the always-on dashboard
  resolved <dst>                       the installed config sourced by scripts and hooks
  write-config <base> <dst> KEY...     put the setup answers into config.sh, keeping comments
"""

import os
import plistlib
import re
import shlex
import shutil
import sys
from pathlib import Path

ASSIGN = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
TOKEN = re.compile(r"\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}")
# Resolved by install.sh rather than written in config.sh.
DERIVED = ["CLAUDE_BIN", "PYTHON3", "CCYCLOPS_REPO", "CCYCLOPS_CONFIG"]
DAYS = {"sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6}
DAY_GROUPS = {"daily": [], "weekdays": [1, 2, 3, 4, 5], "weekends": [6, 0]}
# Values pasted into the !`shell` lines of commands/*.md must stay inside "...".
UNSAFE = re.compile(r'["`$\\\n]')


def env(key: str, default: str = "") -> str:
    return os.environ.get(key, default)


def assignments(path) -> dict:
    """KEY -> raw right-hand side, in file order."""
    out = {}
    if path and Path(path).is_file():
        for line in Path(path).read_text().splitlines():
            m = ASSIGN.match(line)
            if m:
                out[m[1]] = m[2]
    return out


def config_keys() -> list:
    keys = dict.fromkeys(assignments(env("CCYCLOPS_EXAMPLE")))
    keys.update(dict.fromkeys(assignments(env("CCYCLOPS_CONFIG"))))
    keys.update(dict.fromkeys(DERIVED))
    return list(keys)


def example_types() -> dict:
    """Unquoted true/false in config.example.sh marks a boolean, unquoted digits a number."""
    types = {}
    for key, raw in assignments(env("CCYCLOPS_EXAMPLE")).items():
        value = raw.split("#", 1)[0].strip()
        if value in ("true", "false"):
            types[key] = "bool"
        elif value.isdigit():
            types[key] = "int"
    return types


def flag_key(prefix: str, name: str) -> str:
    """pr-queue -> JOB_PR_QUEUE (install.sh's key_for does the same)."""
    return f"{prefix}_" + re.sub(r"[^A-Za-z0-9]", "_", name).upper()


def job_mode(name: str) -> str:
    value = env(flag_key("JOB", name), "manual").strip()
    return value.lower() if value.lower() in ("manual", "off") else value


# --------------------------------------------------------------------- schedules

def parse_schedule(text: str) -> dict:
    """'weekdays 09:00' -> launchd keys. Raises ValueError with a readable reason."""
    parts = text.lower().split()
    if not parts:
        raise ValueError("empty schedule")
    if parts[0] == "every":
        m = re.fullmatch(r"(\d+)\s*(m|h)", " ".join(parts[1:]))
        if not m or int(m[1]) == 0:
            raise ValueError(f'"{text}": write it like "every 30m" or "every 2h"')
        return {"StartInterval": int(m[1]) * (60 if m[2] == "m" else 3600)}

    spec, times = parts[0], parts[1:]
    if spec in DAY_GROUPS:
        days = DAY_GROUPS[spec]
    else:
        days = []
        for day in spec.split(","):
            if day[:3] not in DAYS:
                raise ValueError(f'"{text}": unknown day "{day}" '
                                 "(use daily, weekdays, weekends, or mon,tue,... )")
            days.append(DAYS[day[:3]])
    if not times:
        raise ValueError(f'"{text}": add a time, e.g. "{spec} 09:00"')

    entries = []
    for t in times:
        m = re.fullmatch(r"([01]?\d|2[0-3]):([0-5]\d)", t)
        if not m:
            raise ValueError(f'"{text}": "{t}" is not a 24h HH:MM time')
        hm = {"Hour": int(m[1]), "Minute": int(m[2])}
        entries += [{"Weekday": d, **hm} for d in days] if days else [hm]
    return {"StartCalendarInterval": entries}


# ------------------------------------------------------------------------ check

def check(commands_dir: str, hooks_dir: str) -> int:
    errors, warnings = [], []
    keys = config_keys()
    commands = sorted(p.stem for p in Path(commands_dir).glob("*.md"))
    hooks = sorted(p.stem for p in Path(hooks_dir).glob("*.sh"))

    for name in commands:
        mode = job_mode(name)
        if mode not in ("manual", "off"):
            try:
                parse_schedule(mode)
            except ValueError as e:
                errors.append(f"{flag_key('JOB', name)}: {e}")
    for prefix, names, folder in (("JOB", commands, "commands/"), ("HOOK", hooks, "hooks/")):
        known = {flag_key(prefix, n) for n in names}
        for key in keys:
            if key.startswith(prefix + "_") and key not in known:
                warnings.append(f"{key} doesn't match a file in {folder} — typo? "
                                f"(known: {', '.join(sorted(known))})")

    for key, kind in example_types().items():
        value = env(key)
        if kind == "bool" and value not in ("true", "false"):
            errors.append(f'{key}="{value}": use true or false')
        if kind == "int" and not value.isdigit():
            errors.append(f'{key}="{value}": must be a whole number')

    if not env("VAULT"):
        errors.append("VAULT is empty — set it to the folder your notes should go in")
    repo = env("MAIN_REPO")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo):
        errors.append(f'MAIN_REPO="{repo}": use owner/name, e.g. "acme/webapp"')
    elif repo.startswith("your-org/"):
        warnings.append("MAIN_REPO is still the placeholder your-org/your-repo")
    for key in ("PROJECTS_DIR", "MAIN_REPO_DIR"):
        if not Path(env(key)).is_dir():
            warnings.append(f"{key}={env(key)} doesn't exist — jobs fail their pre-flight check until it does")
    if env("CALENDAR") == "true" and not shutil.which("icalBuddy"):
        warnings.append("CALENDAR=true but icalBuddy isn't installed — standup/wrapdown will refuse "
                        "to write (FEED FAILURE). brew install ical-buddy, or set CALENDAR=false")

    used = set()
    for p in Path(commands_dir).glob("*.md"):
        used |= set(TOKEN.findall(p.read_text()))
    for key in sorted(used - {"HOME"}):
        if key not in keys:
            errors.append(f"commands use {{{{{key}}}}} but the config has no {key}")
        elif UNSAFE.search(env(key)):
            errors.append(f'{key} can\'t contain ", `, $ or \\ — it is pasted into shell commands in commands/*.md')

    claude = env("CLAUDE_BIN")
    if not (claude and os.access(claude, os.X_OK)):
        errors.append(f'CLAUDE_BIN="{claude}": claude not found — install Claude Code, '
                      "or set CLAUDE_BIN to its full path")

    for w in warnings:
        print(f"  \033[33mwarn:\033[0m {w}")
    for e in errors:
        print(f"  \033[31merror:\033[0m {e}")
    return 1 if errors else 0


# --------------------------------------------------------------------- outputs

def render(src: str, dst: str):
    text = Path(src).read_text()
    allowed = set(config_keys()) | {"HOME"}
    missing = sorted({k for k in TOKEN.findall(text) if k not in allowed})
    if missing:
        sys.exit(f"{src}: no config value for {', '.join('{{%s}}' % k for k in missing)}")
    Path(dst).write_text(TOKEN.sub(lambda m: env(m[1]), text))


def label(name: str) -> str:
    return f"{env('LAUNCHD_PREFIX')}.claude-{name}"


def write_plist(dst: str, name: str, program: list, extra: dict):
    log = f"{env('HOME')}/.claude/logs/{name}-launchd.log"
    data = {"Label": label(name), "ProgramArguments": program, **extra,
            "StandardOutPath": log, "StandardErrorPath": log}
    Path(dst).write_bytes(plistlib.dumps(data, sort_keys=False))


def job_plist(name: str, schedule: str, dst: str):
    runner = f"{env('HOME')}/.claude/scripts/run-job.sh"
    write_plist(dst, name, ["/bin/bash", runner, name], {**parse_schedule(schedule), "RunAtLoad": False})


def dashboard_plist(dst: str):
    script = f"{env('HOME')}/.claude/scripts/workflows-dashboard.py"
    write_plist(dst, "workflows", [env("PYTHON3"), script, "--no-open", "--port", env("DASHBOARD_PORT")],
                {"RunAtLoad": True, "KeepAlive": True})


def resolved(dst: str):
    lines = [f"# Generated by install.sh from {env('CCYCLOPS_CONFIG')}",
             "# Don't edit this copy: change that file, then run install.sh again.", ""]
    lines += [f"{k}={shlex.quote(env(k))}" for k in config_keys()]
    Path(dst).write_text("\n".join(lines) + "\n")


def sh_value(value: str) -> str:
    """A value as it reads best in config.sh: true/42 bare, paths under $HOME as "$HOME/..."."""
    if re.fullmatch(r"true|false|\d+", value):
        return value
    home, prefix = env("HOME"), ""
    if value == home or value.startswith(home + "/"):
        prefix, value = "$HOME", value[len(home):]
    return '"' + prefix + re.sub(r'(["\\$`])', r"\\\1", value) + '"'


def write_config(base: str, dst: str, keys: list):
    line_re = re.compile(r"""^(\s*(?:export\s+)?([A-Za-z_]\w*)=)("(?:[^"\\]|\\.)*"|'[^']*'|[^\s#]*)(\s*#.*)?$""")
    lines, todo = Path(base).read_text().splitlines(), list(keys)
    for i, line in enumerate(lines):
        m = line_re.match(line)
        if m and m[2] in todo:
            new = m[1] + sh_value(env(m[2]))
            if m[4]:  # keep the comment, in its column when there's room
                col = len(m[1] + m[3]) + len(m[4]) - len(m[4].lstrip())
                new += " " * max(1, col - len(new)) + m[4].lstrip()
            lines[i] = new
            todo.remove(m[2])
    lines += [f"{k}={sh_value(env(k))}" for k in todo]
    Path(dst).write_text("\n".join(lines) + "\n")


def main():
    cmd, args = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ("", [])
    try:
        if cmd == "check":
            sys.exit(check(*args))
        elif cmd == "render":
            render(*args)
        elif cmd == "plist":
            job_plist(*args)
        elif cmd == "dashboard-plist":
            dashboard_plist(*args)
        elif cmd == "resolved":
            resolved(*args)
        elif cmd == "write-config":
            write_config(args[0], args[1], args[2:])
        else:
            sys.exit(__doc__)
    except ValueError as e:  # a schedule that check() would have caught
        sys.exit(f"error: {e}")


if __name__ == "__main__":
    main()

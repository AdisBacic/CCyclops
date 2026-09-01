---
description: Evening wrap-up — enrich today's daily note with what actually got done, ticket state changes, and tomorrow's starting point
allowed-tools: Bash(date:*), Bash(find:*), Bash(ls:*), Bash(icalBuddy:*), Bash(git -C:*), Bash(gh pr list:*), Bash(gh pr view:*), Bash(gh issue view:*), Bash(__HOME__/.claude/scripts/standup-git.sh:*), Bash(__HOME__/.claude/scripts/standup-calendar.sh:*), Read, Write, Edit, Glob, Grep
---

## Injected context

Today: !`date '+%Y-%m-%d (%A)'`

My commits today across all repos:
!`__HOME__/.claude/scripts/standup-git.sh today`

Ticket notes touched today (auto-logged by the SessionEnd hook):
!`find "__VAULT__/Workflows/Tickets" -maxdepth 1 -name '*.md' -mtime -1 2>/dev/null`

Meetings today (the recurring daily standup filtered out; falls back to the pre-fetched cache in headless runs):
!`__HOME__/.claude/scripts/standup-calendar.sh today`

My open PRs and their state:
!`gh pr list -R __MAIN_REPO__ --author "@me" --state open --json number,title,isDraft,reviewDecision --jq '.[] | "#\(.number) \(.title) [\(if .isDraft then "draft" else (.reviewDecision // "no review") end)]"' 2>/dev/null`

## Task

**Feed check — do this first.** Inspect the injected context above. If any source shows an *error* rather than data — the git script printing errors, `gh` output showing authentication/API failures, the calendar script reporting "(calendar unavailable — no live access and no cache)" — do NOT write or modify the daily note. Reply with a single line starting `FEED FAILURE:` naming the broken source and the error text, then stop. An empty-but-successful feed (no commits today, no meetings) is normal and NOT a failure.

Enrich today's daily note at `__VAULT__/Workflows/Daily/<today>.md`:

1. **Read the sources**: today's daily note (written by the morning standup — if it doesn't exist, create it with just the frontmatter, the `# <Weekday> <today>` header, and the Wrap-up section), and each ticket note touched today (their `## Work log` sections describe what happened).
2. **Check ticket state**: for each ticket with activity today, verify PR state with `gh pr list --repo <repo> --head <branch> --state all --json number,state,title` in `__MAIN_REPO_DIR__`. Update the ticket note's `status:` frontmatter (active → review → merged) and `updated:` field if changed.
3. **Write or replace the `## 🌙 Wrap-up` section** at the END of the daily note (replace an existing Wrap-up section wholesale — it's machine-owned; everything above it is preserved untouched):

````markdown
## 🌙 Wrap-up

**Done today**
- [[<ticket note name>]] — one short sentence on what actually happened, incl. PR state
- (non-ticket work: commits, reviews, support, meetings that produced outcomes — one bullet each)

**Didn't happen**
- items from this morning's "Today" plan that saw no activity, one line each; "–" if everything moved

**Tomorrow's starting point**
- the most obvious next step per active ticket, from work-log state and PR status
- carried-over items still open
````

Rules:
- Compare against the morning plan in this note's `## 🔧 Technical` → **Today** list — that's what "Didn't happen" is measured against. No guilt-tripping language, just facts.
- Wikilink ticket notes by exact filename without `.md`. Lead bullets with issue numbers where they exist. One line per item, under ~100 chars, no sub-bullets.
- Everything in English (domain-specific terms may stay as-is).
- Do not invent work — only report what ticket logs, commits, and PR states show.
- Never touch the `## 📋 Standup (copy)` fence or any hand-written content above the Wrap-up section.
- Finish by printing the path of the note you updated and a 3-line summary in the chat.

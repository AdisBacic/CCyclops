---
description: Write today's daily note in the vault — what I did yesterday, today's plan, blockers
allowed-tools: Bash(date:*), Bash(find:*), Bash(ls:*), Bash(icalBuddy:*), Bash(git -C:*), Bash(gh pr list:*), Bash(gh pr view:*), Bash(gh issue view:*), Bash(__HOME__/.claude/scripts/standup-git.sh), Bash(__HOME__/.claude/scripts/standup-calendar.sh:*), Read, Write, Edit, Glob, Grep
---

## Injected context

Today: !`date '+%Y-%m-%d (%A)'`

My commits across all repos since yesterday midnight (since Friday if today is Monday — the script handles it):
!`__HOME__/.claude/scripts/standup-git.sh`

Ticket notes touched in the last 3 days (auto-logged by the SessionEnd hook):
!`find "__VAULT__/Workflows/Tickets" -maxdepth 1 -name '*.md' -mtime -3 2>/dev/null`

Most recent daily notes:
!`ls -t "__VAULT__/Workflows/Daily/" 2>/dev/null | head -3`

Meetings yesterday (Friday if today is Monday; the recurring daily standup is filtered out — it's every day; falls back to a pre-fetched cache in headless runs):
!`__HOME__/.claude/scripts/standup-calendar.sh yesterday`

Meetings today (same filtering/fallback):
!`__HOME__/.claude/scripts/standup-calendar.sh today`

PRs awaiting MY review:
!`gh pr list -R __MAIN_REPO__ --search "review-requested:@me" --state open --json number,title --jq '.[] | "#\(.number) \(.title)"' 2>/dev/null`

## Task

**Feed check — do this first.** Inspect the injected context above. If any source shows an *error* rather than data — the git script printing errors, `gh` output showing authentication/API failures, the calendar script reporting "(calendar unavailable — no live access and no cache)" — do NOT write or modify the daily note. Reply with a single line starting `FEED FAILURE:` naming the broken source and the error text, then stop. A better note tomorrow beats a silently thinner note today. An empty-but-successful feed (no commits, no meetings, no PRs) is normal and NOT a failure.

Write today's daily note at `__VAULT__/Workflows/Daily/<today>.md`. If it already exists, update it in place (preserve anything hand-written).

1. **Read the sources**: each recently-touched ticket note listed above (their `## Work log` sections describe what happened), and the most recent previous daily note (to carry over open items).
2. **Check ticket state**: for each ticket that had activity, run `gh pr list --repo <repo> --head <branch> --state all --json number,state,title` (or `gh issue view <number>`) in `__MAIN_REPO_DIR__` to find whether its PR is open, merged, or closed. Update that ticket note's `status:` frontmatter field if it changed (active → review → merged), and refresh `updated:`.
3. **Write the daily note** in this exact shape (the ```text fence around the standup is essential — Obsidian renders a one-click copy button on code blocks):

````markdown
---
type: daily
date: <today>
---

# <Weekday> <today>

## 📋 Standup (copy)

```text
Yesterday:

<plain lines, no bullets — see Team standup rules below>

Today:

<plain lines, no bullets>
```

---

## 🔧 Technical

**Yesterday**
- [[<ticket note name>]] — one short sentence on what actually happened, incl. PR state
- (non-ticket work: commits on master, reviews, support — one bullet each)

**Today**
- carried-over open items from the previous daily note that are still open
- obvious next steps from the ticket work logs (e.g. "#1234 awaiting review")
- PRs awaiting my review (from the list above), one bullet each; if a pre-review note exists in `__VAULT__/Workflows/Reviews/` for that PR number (written by the 08:40 pr-queue automation), wikilink it on the same bullet

## 📅 Meetings
- <HH:MM — meeting title (names)>, one per line from the calendar list; "–" if none

## ⛔ Blockers
–
````

Team standup rules (this section is copy-pasted to the team — non-technical):
- **Always in English.** Domain-specific product terms may stay in their original language.
- Plain lines, no bullets, no bold, no wikilinks, no branch names, no "PR #" prefixes. Issue numbers are OK ("Fixed issue #1234").
- Outcome-oriented and human: name the feature and the people, not the mechanics. Use first names from the calendar attendees ("Sync with Alex", "Reports feature with Sam"), and any nicknames you know your team uses.
- Meetings become lines like "Sync with <names>" / "<topic> with <name>"; solo work becomes "Deployment of <feature>", "PR check - <feature>", "Fixed issue #<n> - <short what>".
- If yesterday was a weekend day, label the first block `Friday:` instead of `Yesterday:` and report Friday's work (the git and calendar scripts already return Friday's data on Mondays; widen `gh` queries yourself).
- 3-6 lines per block. Skip social breaks, skip the recurring daily standup itself.

Rules:
- Wikilink ticket notes by their exact filename without `.md` (in Technical only — never inside the standup fence).
- Keep it scannable: one line per item, no sub-bullets, no extra headers. In Technical, lead with the issue number (`#1234 draft — ...`), skip branch names, keep each line under ~100 chars.
- Meetings attended yesterday go in the standup block, not in Technical.
- **Everything is written in English.** Domain-specific terms may stay as-is.
- Do not invent work — only report what the ticket logs, commits, and PR states show. If a session log's topic is unclear, say what the commits say instead.
- Attendees: first names only (from name or email local-part, e.g. `alexander.smith@example.com` → Alexander), drop yourself and room resources. Skip the attendee list entirely when it's longer than ~6 people.
- Finish by printing the path of the note you wrote and a 3-line summary in the chat.

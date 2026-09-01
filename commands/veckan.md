---
description: Weekly rollup — fold this week's daily notes into one summary (monthly-review / 1:1 material)
allowed-tools: Bash(date:*), Bash(ls:*), Bash(find:*), Bash(git -C:*), Bash(gh pr list:*), Bash(__HOME__/.claude/scripts/veckan-prs.sh), Read, Write, Glob, Grep
---

## Injected context

Today: !`date '+%Y-%m-%d (%A), week %V'`

This week's daily notes:
!`find "__VAULT__/Workflows/Daily" -name '*.md' -mtime -7 2>/dev/null | sort`

My merged PRs this week:
!`__HOME__/.claude/scripts/veckan-prs.sh`

## Task

Read every daily note listed above and write a weekly summary to `__VAULT__/Workflows/Weekly/<year>-W<week>.md` (create the `Weekly/` folder if needed; if the note exists, update in place and preserve hand-written content).

```markdown
---
type: weekly
week: <year>-W<week>
---

# Week <week> (<first weekday date> – <today>)

## Shipped
- merged PRs and completed tickets, one line each with [[ticket wikilinks]] where notes exist

## In progress
- open PRs / active tickets and their current state

## Meetings & other
- notable meetings and non-code work from the dailies (skip recurring standups/social breaks)

## Next week
- open items carried forward
```

Rules:
- Aggregate, don't repeat — one line per item for the whole week, not per day.
- Always write in English (domain-specific terms may stay as-is).
- Only report what the dailies, PR list, and ticket notes show — don't invent.
- Finish by printing the note path and a 3-line summary in the chat.

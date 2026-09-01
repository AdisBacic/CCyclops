---
description: Pre-review PRs awaiting my review — read-only, severity-filtered review notes into the vault before I open GitHub
allowed-tools: Bash(date:*), Bash(ls:*), Bash(find:*), Bash(gh search:*), Bash(gh pr list:*), Bash(gh pr view:*), Bash(gh pr diff:*), Bash(git -C:*), Read, Write, Edit, Glob, Grep
---

## Injected context

Today: !`date '+%Y-%m-%d (%A)'`

PRs awaiting MY review across the org:
!`gh search prs --review-requested=@me --state=open --owner=__GITHUB_ORG__ --json repository,number,title --jq '.[] | "\(.repository.nameWithOwner)#\(.number) \(.title)"' 2>&1`

Existing pre-review notes:
!`ls __VAULT__/Workflows/Reviews/ 2>/dev/null`

## Task

**Feed check — do this first.** If the `gh search` output above shows an authentication or API error rather than a (possibly empty) list, do NOT write anything. Reply with a single line starting `FEED FAILURE:` naming the error, then stop. An empty PR list is normal — reply "No PRs awaiting review." and stop.

For each PR in the list, write a pre-review note at `__VAULT__/Workflows/Reviews/<repo>-PR<number>.md` (create the folder if needed):

1. **Skip unchanged PRs**: fetch `gh pr view <number> -R <owner/repo> --json headRefOid,title,body,additions,deletions,files`. If a note for this PR already exists AND its `head_sha` frontmatter matches the current `headRefOid`, skip it — say so in one line.
2. **Read the change**: `gh pr diff <number> -R <owner/repo>`. If the diff exceeds ~1500 lines, review only the highest-risk files (migrations, auth, money/business-critical calculations, deletions of validation) and state in the note that the review is partial.
3. **Cross-check locally where possible**: the repos live under `__PROJECTS_DIR__/` — use Read/Grep there to check how changed methods are used elsewhere (callers, overrides) instead of guessing from the diff alone.
4. **Write the note** in this exact shape:

````markdown
---
type: pr-review
repo: <owner/repo>
pr: <number>
head_sha: <headRefOid>
reviewed: <today>
---

# <repo>#<number> — <title>

**What it does:** 2-3 sentences, plain language — the thing to know before opening the diff.

**Verdict:** ✅ looks mergeable / ⚠️ has findings / ⛔ blocking issue

## Findings

### 🔴 Critical
- <file:line> — issue and concrete failure scenario; "–" if none

### 🟠 High
- ...; "–" if none

### 🟡 Medium
- ...; "–" if none

## Review focus
- 2-4 bullets: where to spend human attention (the risky hunk, the migration, the test that's missing)
````

Severity rules (this is the contract — an ignored review note is a useless one):
- Report ONLY findings you are confident in after checking context. A finding needs a concrete failure scenario ("nil when X, crashes Y"), not a vibe.
- **Critical**: data loss, security, money/business-critical miscalculation, crash on a mainline path. **High**: incorrect behavior on a real path, missing migration safety, N+1 on a hot page. **Medium**: correctness edge cases, missing test for changed behavior.
- NO style nitpicks, NO naming opinions, NO "consider refactoring", NO praise padding. If there is nothing above Medium, the sections say "–" and the verdict is ✅ — that is a good outcome, not a failed review.
- NEVER post anything to GitHub — no comments, no reviews, no approvals. Notes in the vault only. (The tool allowlist enforces this; don't try.)
- Do not modify any repo files — repos are read-only context for this task.

Finish by printing one line per PR: `<repo>#<number> — <verdict> (<note path> | skipped, unchanged)`.

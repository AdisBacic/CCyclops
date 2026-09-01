---
description: Re-orient on the current feature branch - fetch, diff against up-to-date origin/master, check PR base/CI/review state, and summarize what the feature does and the single most likely next step. Use when the user runs /catchup, resumes work on a branch, or asks "where were we" / "what is this branch" / "what's the state of this feature".
---

# Catchup

Goal: a short, accurate picture of the active feature and where it stands. Read-only — never modify, stash, or reset anything.

1. `git fetch origin` first. All comparisons are against `origin/master`, never the local `master` ref — it is frequently stale here and has produced wrong conclusions about rebase state before.
2. `git branch --show-current`. If on master/main: say there is no active feature branch and stop. If HEAD is inside `.claude/worktrees/`, say which worktree and branch — the user's main checkout may be elsewhere.
3. `git status --porcelain`. If there are uncommitted or staged changes, the user is often mid-edit: list them, treat them as work-in-progress to PRESERVE, and fold them into the summary as "in progress, not committed". Never suggest discarding them.
4. `git diff --stat origin/master...HEAD` (three-dot) first. Then read full diffs only for the files that carry the feature — skip `db/schema.rb`, lockfiles, `app/assets/builds/**`, `public/packs**`. If more than ~50 meaningful files, summarize by area instead of reading everything.
5. `gh pr view --json title,url,baseRefName,isDraft,mergeable,statusCheckRollup,reviews 2>/dev/null`. If a PR exists, report:
   - **Base branch** — flag loudly if it is anything other than `master` (a PR silently based on another feature branch has bitten us).
   - **CI** — failing check names, and whether the failures touch files in this diff or look unrelated to the feature.
   - Behind/ahead of `origin/master` (`git rev-list --count HEAD..origin/master`) — i.e. does it need a rebase.
   - Unresolved review feedback, draft status.
   If `gh` is unauthenticated or there is no PR, say so in one line and move on.
6. Summarize in a few sentences, in this order: what the feature does (from the diff, not the branch name), what is committed vs. uncommitted, PR/CI/rebase state, then ONE recommended next step (fix CI, rebase onto master, continue X, open PR). Do not list a menu of options and do not start doing the next step — wait for the user.

Edge cases:
- Branch has no upstream yet → note it is local-only/unpushed.
- `origin/master` missing → fall back to `origin/HEAD`.
- Detached HEAD → report the situation instead of guessing a branch.

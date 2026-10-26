---
description: Re-orient on the current feature branch - fetch, diff against the up-to-date default branch, check PR base/CI/review state, and summarize what the feature does and the single most likely next step. Use when the user runs /catchup, resumes work on a branch, or asks "where were we" / "what is this branch" / "what's the state of this feature".
---

# Catchup

Goal: a short, accurate picture of the active feature and where it stands. Read-only — never modify, stash, or reset anything.

1. `git fetch origin` first. Then find the default branch with `git symbolic-ref --short refs/remotes/origin/HEAD` (e.g. `origin/main`); if that fails, use whichever of `origin/main` / `origin/master` exists. Call it `<base>` below. All comparisons are against `<base>`, never the local branch of the same name — it is often stale and gives wrong conclusions about rebase state.
2. `git branch --show-current`. If on the default branch: say there is no active feature branch and stop. If HEAD is inside `.claude/worktrees/`, say which worktree and branch — the user's main checkout may be elsewhere.
3. `git status --porcelain`. If there are uncommitted or staged changes, the user is often mid-edit: list them, treat them as work-in-progress to PRESERVE, and fold them into the summary as "in progress, not committed". Never suggest discarding them.
4. `git diff --stat <base>...HEAD` (three-dot) first. Then read full diffs only for the files that carry the feature — skip generated and vendored files (lockfiles, schema dumps, build output, compiled assets). If more than ~50 meaningful files, summarize by area instead of reading everything.
5. `gh pr view --json title,url,baseRefName,isDraft,mergeable,statusCheckRollup,reviews 2>/dev/null`. If a PR exists, report:
   - **Base branch** — flag loudly if it is anything other than the default branch (a PR silently based on another feature branch is easy to miss).
   - **CI** — failing check names, and whether the failures touch files in this diff or look unrelated to the feature.
   - Behind/ahead of `<base>` (`git rev-list --count HEAD..<base>`) — i.e. does it need a rebase.
   - Unresolved review feedback, draft status.
   If `gh` is unauthenticated or there is no PR, say so in one line and move on.
6. Summarize in a few sentences, in this order: what the feature does (from the diff, not the branch name), what is committed vs. uncommitted, PR/CI/rebase state, then ONE recommended next step (fix CI, rebase onto the default branch, continue X, open PR). Do not list a menu of options and do not start doing the next step — wait for the user.

Edge cases:
- Branch has no upstream yet → note it is local-only/unpushed.
- Detached HEAD → report the situation instead of guessing a branch.

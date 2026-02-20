---
name: branch-out
description: Isolate a subset of changes from a dirty local worktree (usually on main) into a clean feature branch, then commit, push, and open a PR. Use when the user asks to "branch out", "isolate my changes", "move this work to a new branch", or create a clean PR from only selected files/hunks.
---

# Branch Out

## Goal
Take only the requested changes from a dirty tree, land them on a new branch, and produce a clean PR without sweeping unrelated local work.

## Workflow

### 1) Inspect local state and gather candidates
Run:

```bash
git rev-parse --abbrev-ref HEAD
git status -sb
git status --short
git fetch --prune origin
git status -sb
git rev-list --left-right --count HEAD...origin/main
```

If `MERGE_HEAD`, `REBASE_HEAD`, or cherry-pick state exists, stop and ask user whether to finish that operation first.
Default assumption is a dirty `main` branch. If current branch is not `main`, ask whether to continue from the current branch or switch strategy.

### 2) Decide which changes belong in the new branch
Use this rule:

- If session context clearly identifies the exact files/hunks the agent worked on, propose that scoped list and ask for confirmation.
- If scope is ambiguous, ask the user to choose exact files (and hunks for mixed files).

Always print the selected scope before staging.
Capture the original session prompt now; it must be included in the PR description later.

### 3) Create and validate the branch
If user did not provide a branch name, propose one and confirm.
Before creating it, ensure the name does not collide:

```bash
git show-ref --verify --quiet refs/heads/<branch-name>
git ls-remote --exit-code --heads origin <branch-name>
```

If either exists, propose `<branch-name>-2` (or another clear suffix) and confirm.

Then run:

```bash
git switch -c <branch-name>
```

This keeps all current working-tree changes present so only selected changes can be committed.

### 4) Stage only selected changes
Use:

- Whole file: `git add -- <path>`
- Partial file: `git add -p -- <path>`
- Deletions: `git add -u -- <path>`

Then verify:

```bash
git diff --cached --name-status
git diff --cached
```

If unrelated changes are staged, unstage them surgically (`git restore --staged <path>`), then re-check.

### 5) Commit only the staged scope
Commit message:
- Use user-provided message if given.
- Otherwise generate a scoped, platform-prefixed message.

If only whole-file staging was used, prefer:

```bash
scripts/committer "<message>" <file1> <file2> ...
```

If partial hunk staging was used, preserve the curated index and commit directly:

```bash
git commit -m "<message>"
```

Before committing, ensure staged files are exactly intended:

```bash
git diff --cached --name-only
```

If nothing is staged, stop and ask the user to re-select scope.

### 6) Sync strategy with remote `main` (safe in dirty trees)
First inspect post-commit working tree:

```bash
git status --short
```

Then choose path:
- If working tree is clean, rebase onto latest `origin/main`.
- If working tree is still dirty (unrelated local edits remain), do not rebase automatically. Ask user to choose:
  - Skip rebase and continue to checks/push.
  - Explicitly allow temporary stash + rebase + stash pop.
  - Manually isolate remaining edits first, then rebase.

If rebase path is chosen, run:

```bash
git fetch origin
git rebase origin/main
```

If conflicts appear during rebase:

```bash
git status -sb
git diff --name-only --diff-filter=U
```

Resolve file-by-file, stage, then continue:

```bash
git add <resolved-file>
git rebase --continue
```

If user explicitly approves temporary stash flow, use:

```bash
git stash push -u -m "branch-out-temporary"
git rebase origin/main
git stash pop
```

If `stash pop` conflicts, resolve conflicts before continuing.

### 7) Run focused checks for touched areas
Use committed diff as scope:

```bash
git diff --name-only origin/main...HEAD
```

Run targeted checks mapped to touched paths (typecheck/tests/build checks for impacted packages only). Do not push on red checks.

### 8) Push and open PR
Push the new branch:

```bash
git push -u origin <branch-name>
```

If the branch was already pushed and then rebased, use:

```bash
git push --force-with-lease
```

Create PR (preferred with `gh`) and include a structured description that always has:
- `Original Prompt`: the user's original request in this session (quote or paraphrase faithfully).
- `Summary of Changes`: concise bullet list of what was changed.

```bash
gh pr create --base main --head <branch-name> --title "<title>" --body "<body>"
```

Suggested body format:

```md
## Original Prompt
<original user request from this session>

## Summary of Changes
- <change 1>
- <change 2>

## Validation
- <focused checks run and result>
```

If the original prompt is unclear or missing from context, ask the user before opening the PR.

### 9) Final report
Always report:
- Selected files/hunks included in commit.
- Commit hash and message.
- Whether rebase was run, skipped, or deferred (and why).
- Checks run and result.
- Push result and PR URL.
- Remaining unstaged/uncommitted local changes (if any).

## Guardrails

- Never include unrelated files "just to make it compile"; keep PR scope tight.
- Never stash/apply/drop stash unless the user explicitly asks.
- Never run destructive cleanup (`git reset --hard`, broad restore, `rm`) unless user explicitly approves.
- If unsure whether a change belongs in the branch, ask the user before staging it.

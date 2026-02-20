---
name: sync-rebase-and-push
description: Safely sync local commits with remote by rebasing onto origin/main and then push, following a GitHub Desktop-style flow. Use when asked to push/sync a branch, reconcile local and remote state, resolve rebase conflicts, run targeted tests or typechecks, and push only if checks pass.
---

# Sync Rebase And Push

## Goal
Follow a safe, repeatable push flow:
1. Check local and remote state.
2. Print status and divergence.
3. Rebase on `origin/main`.
4. Detect and resolve conflicts.
5. Run targeted tests/typechecks for touched areas.
6. Push only when checks are green.

## Workflow

### 1) Snapshot local and remote state
Run these commands in order:

```bash
git rev-parse --abbrev-ref HEAD
git status -sb
git fetch --prune origin
git status -sb
git for-each-ref --format='%(upstream:short)' "$(git symbolic-ref -q HEAD)"
```

Then print divergence:

- Current branch vs upstream (if upstream exists):
```bash
git rev-list --left-right --count HEAD...@{upstream}
```
- Current branch vs `origin/main`:
```bash
git rev-list --left-right --count HEAD...origin/main
```

If there are uncommitted changes, stop and ask the user before proceeding. Do not auto-stash.

### 2) Rebase onto `origin/main`
Run:

```bash
git rebase origin/main
```

If rebase succeeds, continue to checks.
If rebase stops, continue to conflict handling.

### 3) Show conflict state
When rebase conflicts occur, run:

```bash
git status -sb
git diff --name-only --diff-filter=U
```

For each conflicted file:
- Summarize what each side changed.
- Offer exactly 3 options: keep ours, keep theirs, or merge both surgically.
- Mark one option as recommended.
- Ask for user confirmation before applying non-trivial resolutions.

After each resolved file:

```bash
git add <file>
```

Continue rebase:

```bash
git rebase --continue
```

Repeat until rebase completes or another blocker appears.

### 4) Run targeted validation on modified areas
Determine touched scope after rebase:

```bash
git diff --name-only origin/main...HEAD
```

Map touched files to checks:

- `server/`: `cd server && bun run typecheck`, then targeted `bun test` for touched modules.
- `web/`: `cd web && bun run typecheck`.
- `admin/`: `cd admin && bun run typecheck`.
- `cli/`: `cd cli && cargo check` (or `cargo test` when behavior changed).
- `apple/InlineKit`: `cd apple/InlineKit && swift build` (and `swift test` if tests changed).
- `apple/InlineUI`: `cd apple/InlineUI && swift build`.
- `proto/`: `bun run generate:proto`, then run checks for all impacted consumers.

Prefer focused checks over full-suite runs unless user explicitly asks for full validation.
If any check fails, do not push. Fix first, then re-run affected checks.

### 5) Push strategy
Decide push mode from branch/upstream state:

- No upstream branch:
```bash
git push -u origin <current-branch>
```
- Upstream exists and history was rewritten by rebase:
```bash
git push --force-with-lease
```
- Upstream exists and no rewrite needed:
```bash
git push
```

Never force-push `main` unless the user explicitly asks.

### 6) Final report
Always report:
- Branch name.
- Ahead/behind counts before and after rebase.
- Whether conflicts occurred and how they were resolved.
- Checks run and results.
- Push command used and result.

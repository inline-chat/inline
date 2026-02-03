---
name: continue-rebase-interactively
description: Guide an in-progress rebase with conflicts by summarizing each conflict and offering 3 resolution options.
metadata:
  short-description: Interactive rebase conflict helper
---

# Goal
Help continue an in-progress rebase (or similar conflict cleanup from a merge or stash apply) by iterating through conflicts, summarizing each conflict, and presenting 3 resolution options (keep A, keep B, keep both with a surgical refactor). Mark the best option as recommended, wait for user confirmation, apply the choice, and continue until the operation completes.

# Preconditions
- A git rebase is in progress and has conflicts.
- Never read .env files or run commands that print their contents.
- Always ask before any destructive command (git restore, rm, reset, etc.).

# Workflow

1) Detect conflict state and conflicts
- Run:
  - `git status -sb`
  - `git diff --name-only --diff-filter=U`
- If no conflicts are listed, state that and suggest the appropriate next command based on state:
  - Rebase: `git rebase --continue`
  - Merge: `git merge --continue` (or commit if already staged)
  - Stash apply/pop: `git stash` (resolve + add + continue/commit as needed)

2) For each conflicted file (one at a time)
- Open the file and extract the conflict region(s).
- Present a short “gist” summary (what each side changes, in plain language).
- If the conflict is trivial (whitespace-only, formatting, comment-only, or import ordering), say so explicitly.
- Offer exactly 3 options:
  - **Option A**: keep “A” side (ours)
  - **Option B**: keep “B” side (theirs)
  - **Option C**: keep both with a surgical refactor (briefly describe how)
- Mark one option as **Recommended** and explain why, briefly. For trivial conflicts, recommend the cleanest auto-resolve and mention it can be applied quickly if approved.
- Ask the user to choose A/B/C.

3) Apply the chosen resolution
- Implement the selected option by editing the file and removing conflict markers.
- Re-check for remaining conflict markers in that file.
- Stage the file with `git add <file>`.
- Ask to continue to the next conflict.

4) Continue the rebase
- When all conflicts are resolved and staged, run `git rebase --continue`.
- If rebase pauses again, return to step 1.
- If rebase completes, report success and show `git status -sb`.

# Notes
- Prefer minimal edits; keep changes localized to conflict regions.
- If conflicts are complex or ambiguous, ask a clarifying question before recommending.
- Avoid automated bulk resolutions; keep it interactive and explicit.
- Do not run heavy tests unless requested. Suggest a focused test if relevant.

# Output Style
- For each conflict, output:
  - File path
  - Gist of A vs B
  - Options A/B/C with one **Recommended**
  - A short question: “Pick A/B/C?”

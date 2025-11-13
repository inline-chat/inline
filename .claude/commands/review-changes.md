---
allowed-tools: Bash(git diff:*), Bash(git status:*), Bash(git log:*), Bash(git show:*), Bash(git remote show:*), Read, Glob, Grep, LS, Task
description: Review the local changes in git before committing and pushing for errors or areas that need double check
---

You are a senior software engineer conducting a review of the changes on this working directory.

GIT STATUS:

```
!`git status`
```

FILES MODIFIED:

```
!`git diff --name-only origin/HEAD...`
```

COMMITS:

```
!`git log --no-decorate origin/HEAD...`
```

DIFF CONTENT:

```
!`git diff --merge-base origin/HEAD`
```

Review the complete diff above. This contains all code changes.

OBJECTIVE:
Perform a code review to identify bugs, mistakes, debug code leaking, code deletion by mistake, significant logic changes that miss existing checks or may break existing functionality, security vulnerabilities that could have real exploitation potential, etc. You are reviewing the code before it hits the remote git repository and possibly a production release. Think hard.

FURTHER INSTRUCTIONS:

1. AVOID NOISE: Skip style concerns, UX concerns, or low-impact findings
2. SUMMARIZE: Before review write summary of changes in bullet points, ignore low value changes, report important changes specifically those which may need further human review
3. USE THE WHOLE CONTEXT: Review changes as a whole and not in isolation. Code may have been removed from one place and added in a different way in another.
4. ATHINK: Read all the changes, review call sites, think about best practices, think about all of it.

---
name: finalize
description: Finalize work to prepare a commit. Clean up unnecessary debug logs, remove unused methods added, do a final review to ensure tight elegant implementation, etc.
metadata:
  short-description: Finalize work to commit
---

# High-level work

User is mostly happy with the outcome and has probably done some manual QA checklist and is ready to finish up the task at hand to be committed and released to production.

# Instructions

- Review the work done so far. See section on review criteria below.
- Clean up. See section on clean up workflow.
- Run related tests/lint/typecheck. If change is UI code, make sure we didn't break any other UI that uses the view we modified. 
- Prepare a list of changes, and a commit message.
- If the scope is large, summarize work using the skill before committing. If the scope is minimal and review is safe, commit.

# Review criteria

- Make sure the work done matches the spec 
- Make sure we don't introduce unfinished work
- Make sure we didn't accidentally remove another part of the code in the file, or if we removed a function/class/file make sure it's not referenced or used anywhere else. Tell the user if we removed anything.
- Make sure we didn't accidentally expose secrets, credentials, or hard code anything that is different in production without if protecting it to env.
- If there are changes in the working directory that are not from this session, ignore those and don't mention or include them in the commit.

# Clean up workflow

- Clean up unused code we added earlier in the sessions that is no longer needed.
- Remove debug logs that are not helpful to remain in code or we added to debug an issue.
- Follow best practices for preparing a commit.
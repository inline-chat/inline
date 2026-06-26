---
name: finalize-work
description: Final engineering pass before committing a feature, fix, refactor, or investigation result. Use when the user asks to finalize, clean up, tighten, simplify, prepare for commit, do a second-pass review, or make a completed piece of work production-ready by checking correctness, tests, typing, complexity, architecture, performance, compatibility, error handling, logging, UX/design risk, and commit readiness.
---

# Finalize Work

## Overview

Use this as the last step after implementation. Act like a lead engineer and QA reviewer: inspect the actual local change, fix low-risk issues directly, surface behavior-changing decisions, and leave the work ready for a clean commit when possible.

This skill is not mainly about running every automated check. It is about tightening the change: reducing accidental scope, complexity, risk, and maintenance cost while preserving the intended behavior.

## Workflow

1. Establish the scope.
   - Read the user's current goal and any relevant notes, plans, or `.wip` entries.
   - Inspect `git status --short`, `git diff --stat`, and targeted diffs for changed files.
   - Separate the work being finalized from unrelated dirty files. Do not review or modify unrelated work unless it interacts with the requested change.
   - If the scope is ambiguous, infer from recent user context and touched files. Ask only when a reasonable assumption risks changing user-visible behavior or ownership.

2. Build a technical map.
   - Identify the source of truth, data flow, state ownership, public API or protocol changes, migrations, generated files, and UI surfaces affected.
   - Note hot paths such as scrolling, message rendering, send/open-chat latency, app launch, realtime handlers, DB writes, and main-thread UI work.
   - Check whether tests, fixtures, generated artifacts, docs, and package/public repo boundaries match the implementation.

3. Review with finalization criteria.
   - Correctness: does the code satisfy the intended behavior, edge cases, and invariants? Are compiler checks, runtime guards, and validation placed where they matter?
   - Tests and typing: are there focused regression tests or a clear reason none are needed? Are types precise enough to prevent misuse? Avoid unsafe casts, force unwraps, `Any`/`any`, and untyped data shapes where better options exist.
   - Simplicity: is the change over-engineered, too broad, or split into unnecessary concepts? Can logic be shorter, clearer, or more local without losing safety?
   - Architecture: does the solution follow the codebase's established patterns and platform idioms? Is it a durable design rather than a short-term workaround?
   - Duplication: does duplicated logic create a consistency risk? Extract shared behavior only when the abstraction removes real maintenance cost.
   - Performance: check scroll/fps responsiveness, synchronous work on UI hot paths, DB or network calls during rendering/menu presentation, repeated layout work, unbounded memory growth, and avoidable main-thread work.
   - Error handling and observability: ensure failures have appropriate handling, user fallback, logging, or capture. Remove temporary debug logs/traces unless they are intentional diagnostics.
   - Compatibility and rendering: check OS availability gates, existing behavior on supported platforms, light/dark theming, layout stability, accessibility basics, and visual regressions.
   - Scope hygiene: remove unused code, stale TODOs introduced by this work, accidental file churn, placeholder comments, dead branches, and unrelated formatting.
   - Naming and readability: prefer simple reusable names that describe stable behavior, not setup history or implementation accidents.
   - Security and privacy: check sensitive data handling, auth boundaries, secrets, logging, encryption expectations, and migration safety.

4. Fix what is safely auto-fixable.
   - Patch clear issues directly: simplify local control flow, remove unused code, tighten names, add small tests, improve typing, add necessary guards, move repeated logic into an existing local pattern, and clean temporary diagnostics added during the work.
   - Add comments only where the code is tricky and the comment prevents future misuse or preserves an important invariant.
   - Keep edits scoped. Do not start unrelated refactors or design migrations just because they are nearby.
   - Never discard, restore, delete, or overwrite user work without explicit confirmation.

5. Escalate material decisions.
   - Ask the user before changes that significantly alter behavior, UX, API contracts, database shape, migration strategy, rollout risk, compatibility, or public package boundaries.
   - If a better long-term design exists but it is larger than the current scope, describe the tradeoff and either implement the minimal safe version or ask for direction.
   - If a blocker remains, state the exact blocking question and the safest interim state.

6. Verify commit readiness.
   - Run focused checks that match the touched area when practical. Prefer targeted tests/typechecks/builds over broad expensive validation unless release risk justifies it.
   - Re-run code generation when contracts changed, and verify generated files are included or intentionally absent.
   - Inspect final `git diff --stat`, targeted diffs, and `git status --short`.
   - Confirm no accidental `.env` access, destructive cleanup, unrelated file churn, stale debug output, or untracked required files are left behind.
   - Do not commit unless the user explicitly asked for a commit.

## Output

Use this shape for the final handoff:

1. `Ready for commit` or `Not ready yet`, with the reason.
2. What was tightened or fixed during the finalization pass.
3. Remaining risks, tradeoffs, or user decisions, especially security, performance, compatibility, migrations, and UX.
4. Validation run and what was not run.
5. Suggested commit scope or exact files to include, only when useful.

When no blocking issues remain, be explicit about confidence and why. When checks are skipped, explain why the residual risk is acceptable or what should be run before merging.

---
name: review-change-impact
description: Review local app/code changes after implementation and produce a concise technical handoff. Use when the user asks for a review, risk assessment, tradeoff check, "what should I review", "give me snippets", or a high-level impact summary after changes that affect multiple app areas, UX, behavior, complexity, tech debt, or bug risk.
---

# Review Change Impact

## Workflow

1. Inspect the relevant local diffs first. Use `git diff --stat`, targeted `git diff -- <files>`, and line-numbered reads for changed files the user cares about. Do not review unrelated dirty files unless their changes interact with the requested work.
2. Lead with findings. If there are bugs, regressions, security issues, missing tests, performance risks, or unclear ownership boundaries, list them first by severity with file/line references.
3. If no blocking issues are found, say that clearly, then summarize residual risks and verification gaps.
4. Give a high-level technical map of the change: what changed, where the source of truth is, what new shared helpers or state flows exist, and what behavior moved.
5. Include short snippets only when they clarify important mechanics, not as a full diff replay.
6. Call out tradeoffs explicitly: what was intentionally deferred, what relies on cached/local data, what adds complexity, what avoids heavier abstractions, and what the user should confirm visually or behaviorally.
7. Mention validation run and whether it is enough for production. If checks were not run, say why.

## Output Shape

Use this order unless the user asks for another format:

1. **Findings**: bugs or risks first, with severity and file/line references. If none, write `No blocking issues found`.
2. **Technical Summary**: concise bullets describing the main implementation mechanics.
3. **Snippets**: 1-3 small code excerpts or pseudo-snippets for the important ideas.
4. **Tradeoffs To Confirm**: choices the user should review.
5. **Risks And Validation**: security, performance, UX, compatibility, test/build status, and production readiness.

Keep the response short enough to act on. Prefer file links with exact lines over broad explanations.

## Review Heuristics

- Multi-area changes need extra attention to shared helper boundaries, cache invalidation, stale state, and accidental synchronous work on UI hot paths.
- UX changes need explicit visual review notes, especially menus, toolbar behavior, windowing, hover/hold affordances, and platform-version differences.
- Menu or toolbar code should avoid network and database reads during presentation unless intentionally designed and measured.
- Cached-image or cached-data paths should define fallback behavior and cache invalidation signals.
- Script changes that launch/debug apps should be verified twice when the bug involves stale previous runs.
- If the worktree has unrelated dirty files, state that the review is scoped and do not imply the whole tree is production-ready.

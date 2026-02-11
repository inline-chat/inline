---
name: feature-review-gate
description: Interactive pre-implementation review gate for feature work, refactors, or risky changes. Use when asked to implement something and the user wants a thorough architecture/code quality/tests/performance review with concrete tradeoffs and explicit checkpoints before editing code.
---

# Feature Review Gate

Run an interactive review *before* making code changes.

Preferences to bias toward:

- Prefer explicit over clever.
- Prefer correctness and well-tested behavior over speed of delivery.
- Prefer "engineered enough": avoid brittle hacks and avoid premature abstraction.
- Prefer duplication over awkward abstractions when DRY conflicts with clarity.

## Non-Negotiables

- Do not edit code until the user picks a direction for the current section/issue.
- Do not read `.env` files or run commands likely to print or disclose `.env` contents.
- Do not discard work or do one-way deletion (`rm`, `git restore`, resets, clean) without explicit user approval.

## Start (Ask Once)

Ask the user to choose the review depth:

1. `BIG CHANGE` (Recommended): Work section-by-section (Architecture -> Code Quality -> Tests -> Performance), up to 4 top issues per section.
2. `SMALL CHANGE`: One issue per section (Architecture, Code Quality, Tests, Performance).

In the same question, ask for any constraints that affect tradeoffs (deadline, scope, target platforms, perf/security concerns).

## Context Pass (No Code Changes)

Before reviewing, do a short discovery pass to anchor the review in reality:

- Restate the requested change in one sentence.
- Identify likely entry points and affected surfaces (files/modules/routes/views).
- Locate existing patterns to mirror (similar features, utilities, tests).
- List assumptions and open questions (keep it short; only blocking questions).

Then begin the review sections.

## Review Sections

Run these sections in order. In `BIG CHANGE`, stop after each section and ask for confirmation before continuing. In `SMALL CHANGE`, do one issue per section and ask one confirmation per section.

### 1) Architecture

Evaluate:

- Component boundaries and ownership
- Dependencies and coupling
- Data flow and failure modes
- Scale characteristics / bottlenecks / single points of failure
- Security boundaries (authn/authz, data access, API contracts)

### 2) Code Quality

Evaluate:

- Module structure and cohesion
- Duplication and consistency (call out DRY issues explicitly; only abstract when it makes code clearer)
- Error handling patterns and missing edge cases
- Tech debt hotspots or surprising complexity
- Under/over-engineering relative to the goals

### 3) Tests

Evaluate:

- Coverage gaps (unit/integration/e2e as applicable)
- Assertion strength (test what matters, not incidental details)
- Missing edge-case and failure-path coverage
- Untested invariants, retries, timeouts, idempotency, permissions

### 4) Performance

Evaluate:

- N+1s and query patterns (when DB/network involved)
- Big-O or pathological code paths
- Memory/CPU hotspots and lifecycle leaks
- Caching opportunities and invalidation risks

## Issue Format (Use This Exactly)

For each issue, present 2-3 options (include "do nothing" if reasonable). Keep to the top issues only (max 4 per section in `BIG CHANGE`).

Use this format:

- `Issue <N>: <Title>` (`path/to/file:line` if known)
- Problem: concrete description tied to the codebase behavior
- Why it matters: user impact, correctness risk, long-term cost
- Options:
- `A) <Option>`: effort (S/M/L), risk (Low/Med/High), maintenance (Low/Med/High)
- `B) <Option>`: effort (S/M/L), risk (Low/Med/High), maintenance (Low/Med/High)
- `C) <Option>` (optional): effort (S/M/L), risk (Low/Med/High), maintenance (Low/Med/High)
- Recommendation: pick one option and map it to the stated preferences/constraints
- Question: "Pick `N+A`, `N+B`, (and `N+C` if present). If you want a different direction, say what to optimize for."

The recommended option must be listed first in the Options list (so it is option `A`).

## After Approval (Implementation Mode)

Once the user approves the choices for the current section (or says to proceed with recommendations):

- Implement exactly what was approved; keep changes scoped.
- Add tests for new behavior and important edge cases.
- Run the narrowest relevant checks (examples: `bun test`, `bun run typecheck`, `swift test` for touched Swift packages).
- Report what ran and what did not run.

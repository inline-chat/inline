---
name: run-checks
description: Run static checks and high-level validation before a production push in the Inline repo. Use when asked to run checks, verify correctness, or do pre-push/pre-release validation across server/web/admin/apple/cli/proto changes.
---

# Run Checks

## Overview
Run the minimal set of static checks and targeted builds/tests based on what changed. Prefer fast, focused checks and confirm with the user before long-running steps.

## Workflow Decision Tree

### 1) Identify Scope
Run `git status -sb` and `git diff --name-only`. Group changes by top-level area:

- `server/`
- `web/`
- `admin/`
- `apple/InlineKit`
- `apple/InlineUI`
- `apple/InlineIOS`
- `apple/InlineMac`
- `cli/`
- `proto/`

If only docs or comments changed, report that checks are optional and ask whether to skip.

### 2) Run Pre-Checks
If `proto/` changed, run `bun run generate:proto` from repo root and include generated diffs.

If dependencies changed, run the relevant install/build for that stack:

- JS/TS: `bun install`
- Rust: `cargo fetch` (or rely on `cargo test/check`)
- Swift: `swift build` in the affected package directory

### 3) Run Component Checks
Run only what maps to the touched areas.

Backend (`server/`):
- `cd server && bun run typecheck`
- `cd server && bun run lint`
- `cd server && bun test` (prefer targeted tests when possible)

Web (`web/`):
- `cd web && bun run typecheck`
- Run `cd web && bun run build` only when explicitly requested or required for release validation

Admin (`admin/`):
- `cd admin && bun run typecheck`

CLI (`cli/` or protocol changes):
- `cd cli && cargo test` for full validation
- Use `cd cli && cargo check` if a fast static check is sufficient

Swift packages:
- `cd apple/InlineKit && swift build` (run `swift test` if tests were modified)
- `cd apple/InlineUI && swift build`

Apps:
- If changes are in `apple/InlineIOS` or `apple/InlineMac`, do not run full app builds. Ask the user to run `xcodebuild` locally if needed.

### 4) Report Results
Summarize what ran, what passed/failed, and what was skipped with reasons. For failures, include the first actionable error and the next recommended step.

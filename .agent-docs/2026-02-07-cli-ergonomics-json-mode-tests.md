# CLI Ergonomics: JSON Mode + Tests + Shortcuts (2026-02-07)

From notes (Feb 6-7, 2026): "work the cli ergo", "consistent json mode", "write tests for cli actions", "login/whoami shortcuts", "Adding structured hints/examples is a real UX improvement".

## Goals

- `--json` behaves consistently for all commands (including auth/login/logout and confirmations).
- Action commands have a test harness (not just clap parsing tests).
- Add small shortcuts that reduce typing.

## Current State (Findings)

- CLI entrypoint and routing: `cli/src/main.rs`.
- JSON output helpers: `cli/src/output.rs`.
- `--json` exists, but several commands still print plain text and prompt interactively (notably `auth login`, `auth logout`, and confirmations via `dialoguer`).
- Tests today are mostly parsing-level in `cli/src/main.rs` and do not cover execution/output.

Note: `-m` alias for `--text` is already implemented for message send/edit. No work needed there.

## Spec: What "Consistent JSON Mode" Means

When `--json` is set:
- No interactive prompts.
- No plain-text success messages.
- Errors are structured (`code`, `message`, optional `hint` and `examples`).
- Success returns a stable JSON object (even if minimal).

When stdin/stdout are non-TTY:
- Confirmation must require `--yes` or fail with a structured error telling the user what to do.

## Plan (Implementation)

### 1. Centralize output mode and printing

- Create an `OutputMode` in the parsed CLI context (already implied by global flags).
- Ensure all code paths route through a single printing layer.

Touchpoints:
- `cli/src/main.rs`
- `cli/src/output.rs`

### 2. Make login/logout JSON-compatible

`auth login`:
If interactive, allow prompts (current behavior). If `--json` or non-TTY, require explicit flags for required inputs, or return a structured `CliError` (example: `code = requires_input`, `hint = Use --email/--code or run without --json in a TTY`).

`auth logout`:
- In JSON mode, output `{ "status": "logged_out" }`.

### 3. Standardize user-facing validation errors

- Replace raw `Err("...")` strings for user errors with `CliError` including hints/examples.
- Prefer tight error codes so scripts can match reliably.

### 4. Add login shortcut

- Add top-level `inline login` alias to `inline auth login`.
- `inline whoami` already exists via `inline me` alias; confirm outputs match JSON mode rules.

### 5. Add action-level tests

Recommended approach:
- Add dev-dependencies: `assert_cmd`, `predicates`, `tempfile`.
- Add integration tests under `cli/tests/` that run the binary with state paths redirected to a temp dir, then run in `--json` mode and assert on JSON payload.

If network dependencies make tests flaky:
- Add a `run_with(deps, cli)` entry point and inject fake clients in tests.

Touchpoints:
- `cli/Cargo.toml`
- `cli/tests/*`

## Acceptance Criteria

1. `inline auth logout --json` prints JSON, no plain text.
2. `inline auth login --json` never prompts; it either succeeds with JSON or fails with structured error + hint/examples.
3. Commands that require confirmation fail in JSON/non-TTY unless `--yes` is provided.
4. At least one integration test covers a JSON success path and a JSON error path.
5. `inline login` parses and routes to login flow.

## Risks / Tradeoffs

- Introducing dependency injection for network clients is extra work but pays off quickly in tests.
- Strict JSON mode can break existing scripts that relied on prompts; but that is a feature, not a bug.

# CLI Release Checklist (2026-02-07)

From notes (Feb 5-6, 2026): "release cli", "new cli version with faster, ergo improvements", "make sure cli updates version in session on open/login or something".

This is a checklist to reduce “release anxiety” and keep releases repeatable.

## Goals

1. Release CLI reliably with minimal manual steps.
2. Ensure `--json` mode and non-interactive flows are stable for scripts.
3. Avoid “version mismatch” confusion after login/open.

## References

Release flow described in repo docs:
1. `cd scripts && bun run release:cli -- release`
2. Creates tag `cli-v<version>` and GitHub release artifacts.

## Pre-Release Checklist

1. Ensure `inline --version` matches intended version bump.
2. Run tests:
3. `cd cli && cargo test`
4. Smoke the most important commands:
5. `inline login` (or `inline auth login`)
6. `inline whoami` / `inline me`
7. `inline message send --json` (or equivalent)

8. Validate JSON contract:
9. No prompts in `--json`.
10. Errors are structured and stable.

Spec tie-in:
- `/.agent-docs/2026-02-07-cli-ergonomics-json-mode-tests.md`

## Release Checklist (Automation)

1. Ensure `gh` is authenticated (release script depends on it).
2. Ensure required release env vars exist for artifact upload (R2, etc).
3. Run:
4. `cd scripts && bun run release:cli -- release`

5. Verify GitHub release exists and assets are attached.
6. Verify Homebrew cask pulls from the new release if applicable.

## “Version In Session” Spec

Problem:
1. Users can end up with stale session metadata after updating the binary.

Plan:
1. On `login` and `whoami`, return server version info (if available) and show it in JSON.
2. If CLI stores session metadata locally, include `cliVersion` and update it on command start.

## Acceptance Criteria

1. A release can be cut without manual artifact copying.
2. CLI JSON mode works in CI without hanging.
3. Users can tell what version they’re running and whether the session is valid.


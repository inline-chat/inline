# Inline Plugin Standardization Plan

Date: 2026-02-13
Owner: Codex

## Goal

Bring `packages/openclaw-inline` closer to the quality and capability baseline used by OpenClaw's mature channel plugins (Slack/WhatsApp/Telegram), while preserving Inline-specific behavior and compatibility.

## Tasks

1. Completed: add action gating and action config schema (`channels.inline.actions.*`) with sensible defaults.
2. Completed: expand Inline action adapter to cover more standard message actions supported by Inline RPC.
3. Completed: add `outbound.sendPayload` parity behavior (multi-media payloads, reply behavior).
4. Completed: add directory + resolver adapters for Inline chats/users.
5. Completed: improve status/security ergonomics with `groupPolicy=open` warning.
6. Completed: update docs/config examples and tests for new behavior.
7. Completed: run full package checks (`typecheck`, `test`, `build`) and finalize notes.

## Notes

- Keep compatibility with current OpenClaw peer dependency range.
- Follow existing OpenClaw patterns before inventing new ones.
- Added `pretest` coverage cleanup (`rm -rf coverage`) and a `check` script in `packages/openclaw-inline/package.json`.

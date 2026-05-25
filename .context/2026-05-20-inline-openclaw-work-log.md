# Inline OpenClaw Work Log

Date: 2026-05-20

Purpose: compact state log for the ongoing Inline OpenClaw native-channel parity work. Use this before re-reading the full review ledger.

## Working Protocol

- Read this file before repeating discovery commands.
- Append meaningful new file changes, test commands, install artifacts, and runtime verification here as work proceeds.
- Use the long review ledger for detailed findings, but use this file for turn-to-turn continuity.
- Keep this file concise; do not paste full command output unless a short exact result matters.
- If the next action changes, update `Next Candidate Gap` instead of re-deriving it next turn.
- Run focused tests and `bun run typecheck` every turn where code changes.
- Do not build, pack, install, or update tarball shasums every turn. Do that only after several meaningful runtime changes, before a release checkpoint, or when specifically needed to verify installed behavior.

## Current Goal

Update local OpenClaw and `~/dev/openclaw` to `2026.5.18`, then do a ground-up comparison/review of Inline's OpenClaw plugin against native Telegram and Slack channel plugins. Find and fix/capture inconsistencies, bugs, behavior drift, prompt/copy issues, and release-polish gaps for a production-quality Inline plugin update.

## Current Baseline

- Repo: `/Users/mo/dev/inline-chat/inline`
- OpenClaw CLI: `OpenClaw 2026.5.18 (50a2481)`
- OpenClaw clone: `/Users/mo/dev/openclaw`, tag `v2026.5.18`, short SHA `50a2481652`
- Main review ledger: `.context/2026-05-19-inline-openclaw-native-channel-review.md`
- Latest installed local Inline plugin tarball: `/tmp/inline-openclaw-inline-0.0.36.tgz`
- Latest installed tarball shasum: `f5a2cd1a290ff0535ce66d53c380c7ff2261fd7b`

## Local Runtime State

Last verified after installing the latest tarball:

- `openclaw gateway health` -> OK; Telegram configured; Inline configured.
- `openclaw channels status` -> Inline default enabled/configured/running/connected (`token:config`, `url:[set]`); Telegram enabled/configured/running/connected polling.
- `openclaw plugins doctor` -> no plugin issues detected.
- Installed `/Users/mo/.openclaw/extensions/inline/dist/channel-plugin-api.js` reports `allowlist.resolveNames`, lifecycle, approval capability, message adapter, and `messaging.targetPrefixes=["inline"]` present.
- Installed `/Users/mo/.openclaw/extensions/inline/dist/channel-plugin-api.js` contains the final mention-context code (`ExplicitlyMentionedBot`, `ImplicitMentionKinds`, `MentionSource`, `stripInlineBotMentionEntityText`).
- Installed `/Users/mo/.openclaw/extensions/inline/openclaw.plugin.json` root and channel descriptions both read: `Use OpenClaw from Inline DMs and chats with an Inline bot token.`
- Note: `openclaw plugins inspect inline --json` still reports an older persisted npm shasum even after installing the latest tarball. Use direct tarball shasum plus installed-file probes as artifact evidence for this checkpoint.
- Live smoke test passed from local Inline CLI as Mo (user id 1600):
  - DM to Kevin bot user `36100`: sent `OpenClaw live smoke DM 2026-05-21: please reply OK.`; Kevin replied `OK` (messages 714 -> 715).
  - Group `1022` (`Random / AI bots`): sent `@Kevin OpenClaw live smoke group 2026-05-21: please reply OK.` with mention entity for user `36100`; Kevin replied `OK` (messages 410 -> 412).
  - Group native command: sent `/whoami@mo_openclaw_bot`; Kevin replied with Inline identity metadata including user id `1600` and chat reference (messages 414 -> 415).
  - The same shared group also produced unrelated `Severus` agent OAuth failures, matching earlier history in that room; Kevin/Inline plugin smoke path still passed.

## Major Fixes Already Implemented

- OpenClaw baseline raised to `2026.5.18` across package peer/dev/build/compat metadata and local clone/CLI.
- Metadata/setup parity: shared Inline metadata, setup entry, configured-state sidecar, setup-only plugin, account inspection, secret contract, UI hints, docs.
- Runtime split parity: lightweight `dist/index.js` with sidecars for setup, channel plugin API, runtime registration, account inspection, secret contract, runtime setter, and approval handler.
- Security/credential parity: SecretRef-shaped tokens, env aliases, token-file symlink rejection, unavailable token inspection, duplicate-token detection, logout copy.
- Access policy parity: DM/group allowlist separation, group route normalization, access-group expansion, doctor/security audit warnings, numeric allowlist entries.
- Command parity: Inline provider identity, dynamic native command registry, route-scoped skill commands, plugin command specs with active config, startup sync skips when disabled and uses `setMyCommands` directly.
- Prompt/copy parity: Inline-specific command/menu copy, centralized fallback copy, reduced formatting prompt duplication, less Telegram/native leakage.
- Messaging parity: current-conversation bindings, outbound session routing, session/delivery/inbound conversation normalization, heartbeat typing, defaultTo, message adapter, reply-thread hints, target prefixes.
- Interactive/media parity: Inline visible fallback text for interactive-only replies, button/action limits, payload thread routing, media access policy, no unsafe local file retry.
- Events/reactions parity: edit/delete system events, passive reaction system events with configurable modes and allowlist.
- Native approval parity: Inline `execApprovals`, approver normalization, native approval capability/runtime, origin/DM delivery, plugin approvals, approval buttons, resolution/expiry button clearing.

## Recent Changes This Turn

Current latest:

- `packages/openclaw/src/inline/monitor.ts`: added native-style group mention facts (`ExplicitlyMentionedBot`, `MentionedUserIds`, `ImplicitMentionKinds`, `MentionSource`) to finalized context and the Inline current-message metadata block.
- `packages/openclaw/src/inline/monitor.ts`: also strips the active bot mention from current entity helper text, so the agent prompt does not keep `mention "@inlinebot" -> user:<id>` after stripping the message body.
- `packages/openclaw/src/inline/monitor.test.ts`: extended the bot-mention prompt regression to cover structured mention metadata and mentioned user IDs.
- `packages/openclaw/src/index.test.ts`: raised the split-loader entry test timeout to 30s after the full coverage run crossed the old 15s limit under parallel package-artifact load; the test passes quickly in isolation and now passes in the full suite.
- `.context/2026-05-19-inline-openclaw-native-channel-review.md`: added finding 106 for missing native-style Inline mention facts.
- Verification for this change: `./node_modules/.bin/vitest run src/inline/monitor.test.ts` -> 93 tests; `./node_modules/.bin/vitest run src/index.test.ts` -> 3 tests; `bun run test` -> 20 files, 289 tests; `bun run typecheck`; `bun run lint`; targeted `git diff --check`.
- Final-pass source/copy scan: production-facing hits for `native channel`, `slash command`, `realtime bot`, `moltbot`, and `Telegram/Slack/Discord` are clean; remaining hits are tests or intentional compatibility adapters/sanitizer fixtures. Debug/secrets scan found only placeholders/env-var documentation and a package-artifact test child-process `console.log` used to return JSON.
- Final runtime checkpoint: `bun run build`; `npm pack --ignore-scripts --pack-destination /tmp`; shasum `2ffc45058cfa5b75ff5ad322229872e3659c9fa0`; `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`; `openclaw gateway restart`; `openclaw gateway health`; `openclaw channels status`; `openclaw plugins doctor`; installed channel API probe; installed manifest probe; `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`.

Previous recent changes:

- `packages/openclaw/src/inline/monitor.ts`: strips the active Inline bot username mention from agent-facing group prompt bodies after native mention routing, while preserving `RawBody`, `CommandBody`, and command gating behavior.
- `packages/openclaw/src/inline/monitor.test.ts`: added regression coverage that `@inlinebot` remains in raw/command context but is removed from `Body` and `BodyForAgent`.
- `.context/2026-05-19-inline-openclaw-native-channel-review.md`: added finding 105 for native-mentioned Inline prompts preserving the bot address token.
- Verification for this change: `./node_modules/.bin/vitest run src/inline/monitor.test.ts` -> 93 tests; `bun run typecheck`; targeted `git diff --check`.
- Packaging/install/shasum intentionally deferred for this checkpoint per cadence.

- `packages/openclaw/src/inline/shared.ts`, `monitor.ts`, `setup-surface.ts`: made Inline user allowlist parsing explicit for `inline:user:<id>` while still rejecting chat targets for sender allowlists.
- `packages/openclaw/src/inline/channel.test.ts`, `monitor.test.ts`: added setup parsing, allowlist name resolution, and runtime DM authorization coverage for `inline:user:<id>`.
- `packages/openclaw/README.md`: documented `inline:user:<id>` as an accepted Inline user-id form.
- `.context/2026-05-19-inline-openclaw-native-channel-review.md`: added finding 104 for allowlist user-target copy/coverage drift.
- Verification for this change: `./node_modules/.bin/vitest run src/inline/channel.test.ts src/inline/monitor.test.ts` -> 149 tests; `bun run typecheck`; targeted `git diff --check`.

- `packages/openclaw/src/inline/channel.ts`: gated the Inline reactions message-tool hint on `actions.reactions`, matching the already-gated reaction guidance.
- `packages/openclaw/src/inline/channel.test.ts`: added regression coverage that disabled reactions remove the reaction hint.
- `.context/2026-05-19-inline-openclaw-native-channel-review.md`: added finding 103 for disabled reactions still being suggested in prompts.
- Verification for this change: `./node_modules/.bin/vitest run src/inline/channel.test.ts` -> 57 tests; `bun run typecheck`; targeted `git diff --check`.

- `packages/openclaw/src/inline/channel.ts`: added Inline lifecycle hooks to clear the realtime SDK cursor state file when the effective account credential/base URL identity changes or an account is removed.
- `packages/openclaw/src/inline/channel.test.ts`: added regression coverage for changed credentials deleting state, unchanged credentials preserving state, and account removal deleting state.
- `.context/2026-05-19-inline-openclaw-native-channel-review.md`: added finding 102 for stale Inline SDK cursor state across credential changes/removal.
- Verification for this change: `./node_modules/.bin/vitest run src/inline/channel.test.ts` -> 57 tests; `bun run typecheck`; targeted `git diff --check`.
- Packaging/install/shasum intentionally deferred for this checkpoint per the current cadence.

- `packages/openclaw/src/inline/config-schema.ts`, `openclaw.plugin.json`: added `groups.<chat>.allowFrom` as a per-group Inline sender allowlist.
- `packages/openclaw/src/inline/policy.ts`, `monitor.ts`, `channel.ts`: per-group sender allowlists now override account-level `groupAllowFrom` for group gating and are surfaced as allowlist group overrides.
- `packages/openclaw/src/inline/doctor.ts`, `security.ts`: doctor/audit warnings now recognize per-group sender allowlists and include them in invalid/wildcard checks.
- `packages/openclaw/src/inline/channel.test.ts`, `monitor.test.ts`, `config-schema.test.ts`, `src/manifest.test.ts`: added regression coverage for per-group allowlist display, runtime allow/deny behavior, schema acceptance, and manifest schema validation.
- `packages/openclaw/README.md`, `docs/openclaw-setup.md`: documented account-wide vs per-group group sender allowlists.
- `.context/2026-05-19-inline-openclaw-native-channel-review.md`: added finding 101 for missing Inline per-group sender allowlist override.
- Verification for this change: `./node_modules/.bin/vitest run src/inline/channel.test.ts` -> 56 tests; `./node_modules/.bin/vitest run src/inline/monitor.test.ts` -> 92 tests; `./node_modules/.bin/vitest run src/inline/config-schema.test.ts src/manifest.test.ts` -> 19 tests; `bun run typecheck`; targeted `git diff --check`.

- `packages/openclaw/src/inline/channel.ts`: added `allowlist.resolveNames` using Inline `getChats` snapshots, matching native Slack allowlist-name polish.
- `packages/openclaw/src/inline/channel.test.ts`: added DM and group sender allowlist name resolution coverage.
- `.context/2026-05-19-inline-openclaw-native-channel-review.md`: added finding 100 for Inline allowlist summaries staying numeric.
- Verification for this change: `./node_modules/.bin/vitest run src/inline/channel.test.ts` -> 54 tests; `bun run typecheck`; targeted `git diff --check`.
- One checkpoint install was completed because packaging had already started before the updated cadence request: `npm pack` shasum `f5a2cd1a290ff0535ce66d53c380c7ff2261fd7b`; install, gateway restart, health/status/doctor all passed; installed channel plugin reports `hasResolveNames: true`.

- `packages/openclaw/openclaw.plugin.json`: root `description` aligned with package/runtime/channel description.
- `packages/openclaw/src/manifest.test.ts`: regression added for root manifest description.
- `.context/2026-05-19-inline-openclaw-native-channel-review.md`: early high-priority findings updated with fixed statuses and latest verification.
- `.context/2026-05-20-inline-openclaw-work-log.md`: this compact log added to avoid repeated rediscovery.

## Commands Already Run Recently

- `openclaw --version`
- `git -C /Users/mo/dev/openclaw describe --tags --exact-match HEAD`
- `git -C /Users/mo/dev/openclaw rev-parse --short HEAD`
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `cd packages/openclaw && bun run test` -> latest full package run 20 files, 289 tests
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts` -> latest focused run 93 tests
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts src/inline/monitor.test.ts` -> 149 tests
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/index.test.ts`
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/package-artifact.test.ts`
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/manifest.test.ts` -> 3 tests
- `cd packages/openclaw && bun run build` -> latest build passed.
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp` -> latest shasum `2ffc45058cfa5b75ff5ad322229872e3659c9fa0`.
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz` -> installed plugin `inline`.
- `openclaw gateway restart` -> restarted LaunchAgent.
- `openclaw gateway health` -> OK.
- `openclaw channels status` -> Inline default enabled/configured/running/connected.
- `openclaw plugins doctor` -> no plugin issues detected.
- targeted `git diff --check` for touched OpenClaw files and the review ledger

## Files Touched In Scope

Modified tracked files under `packages/openclaw`:

- `README.md`
- `docs/create-inline-bot.md`
- `docs/openclaw-setup.md`
- `openclaw.plugin.json`
- `package.json`
- `src/index.ts`
- `src/index.test.ts`
- `src/manifest.test.ts`
- `src/runtime.ts`
- `src/runtime.test.ts`
- `src/sdk-runtime-compat.ts`
- `src/inline/accounts.ts`
- `src/inline/accounts.test.ts`
- `src/inline/actions.ts`
- `src/inline/actions.test.ts`
- `src/inline/bot-commands-sync.ts`
- `src/inline/bot-commands-sync.test.ts`
- `src/inline/bot-commands-tool.ts`
- `src/inline/bot-commands-tool.test.ts`
- `src/inline/channel.ts`
- `src/inline/channel.test.ts`
- `src/inline/config-schema.ts`
- `src/inline/config-schema.test.ts`
- `src/inline/media.ts`
- `src/inline/message-formatting.ts`
- `src/inline/message-formatting.test.ts`
- `src/inline/message-tools.ts`
- `src/inline/message-tools.test.ts`
- `src/inline/monitor.ts`
- `src/inline/monitor.test.ts`
- `src/inline/outbound-sanitize.ts`
- `src/inline/outbound-sanitize.test.ts`
- `src/inline/package-artifact.test.ts`
- `src/inline/policy.ts`
- `src/inline/profile-tool.ts`
- `src/inline/setup-core.ts`
- `src/inline/setup-surface.ts`
- `src/inline/status-issues.ts`

New/untracked files under `packages/openclaw`:

- `src/account-inspect-api.ts`
- `src/channel-plugin-api.ts`
- `src/configured-state.ts`
- `src/runtime-register-api.ts`
- `src/runtime-setter-api.ts`
- `src/secret-contract-api.ts`
- `src/setup-entry.ts`
- `src/setup-plugin-api.ts`
- `src/inline/approval-handler.runtime.ts`
- `src/inline/approval-native.ts`
- `src/inline/approval-native.test.ts`
- `src/inline/command-ui.ts`
- `src/inline/doctor.ts`
- `src/inline/exec-approvals.ts`
- `src/inline/interactive-fallback.ts`
- `src/inline/secret-contract.ts`
- `src/inline/secret-contract.test.ts`
- `src/inline/security.ts`
- `src/inline/setup-plugin.ts`
- `src/inline/shared.ts`

## Do Not Repeat Unless Needed

- Do not re-check the OpenClaw version unless code/installer state changes.
- Do not reinstall the plugin after ledger-only edits.
- Do not build/pack/install/update shasum every turn; batch that work every several code-review turns.
- Do not run full `bun run test` for copy-only or manifest-only changes; use focused tests plus `git diff --check`.
- Do not rerun package artifact tests unless package entrypoints, build script, or dist sidecar expectations change.
- Do not read `.env` files.

## Next Candidate Gap

Allowlist `resolveNames`, per-group sender allowlist overrides, lifecycle cursor cleanup, disabled-reaction prompt gating, `inline:user:<id>` allowlist copy/coverage, active bot mention stripping, and native-style Inline mention facts are now implemented in the working tree and recorded as findings 100-106. Final package/install/runtime checkpoint passed. Live Inline DM/group smoke passed.

## Remaining Release Work

- Optional release hardening: decide whether to set a stricter `plugins.allow` list before release. `openclaw plugins doctor` reports no plugin issues, so this is an operator policy decision rather than a failing check.
- Keep the goal active until every claimed requirement in the original objective is verified against current files/runtime state.

## 2026-05-21 Release Attempt

- npm registry check: `@inline-openclaw/inline` latest is `0.0.35`; `0.0.36` is not published and is the prepared release version.
- Local npm auth check: `npm whoami` returned `E401 Unauthorized`, so actual `npm publish` is blocked until npm auth/OTP is available in this shell.
- ClawHub check: OpenClaw has `scripts/plugin-clawhub-publish.sh`, but it expects packages under `extensions/*` in the OpenClaw repo and the local `clawhub` CLI is not on `PATH`, so ClawHub publish is also blocked locally.
- Final checks run from `packages/openclaw`: `bun run check` passed (`typecheck`, `lint`, `test`, `build`).
- npm release dry run: `npm publish --dry-run --access public` passed for `@inline-openclaw/inline@0.0.36`.
- Release artifact: `/tmp/inline-openclaw-inline-0.0.36.tgz`, size `2144191`, shasum `2ffc45058cfa5b75ff5ad322229872e3659c9fa0`.
- Package contents from dry run: 113 files, package size 2.1 MB, unpacked size 16.6 MB.
- `git diff --check -- packages/openclaw package.json bun.lock` passed.

Exact npm publish command once authenticated:

```sh
cd /Users/mo/dev/inline-chat/inline/packages/openclaw
npm publish --access public --otp=<YOUR_OTP_CODE>
```

## 2026-05-21 Release Verified

- npm registry now reports `@inline-openclaw/inline@0.0.36` as `latest`.
- Published npm shasum matches the prepared tarball: `2ffc45058cfa5b75ff5ad322229872e3659c9fa0`.
- Published npm integrity: `sha512-KIILgHI9a/0w5NBIMeN/ORc4+lLf3cB1eInp/FMrk8VKLcViM75ZEo40W7FfGWKBt3PpAMSSPnV5fXzJg1bZ3g==`.

## 2026-05-23 Slash Command Patch Review

- Reviewed the post-`0.0.37` `/` command regression patch against native Slack/Telegram behavior.
- Found and fixed one remaining parity gap: Inline now treats every synced bot command as native when `commands.text=false`, including skill commands and plugin commands, not just built-in native registry commands.
- Added monitor coverage for built-in `/status`, synced skill `/deploy`, synced plugin `/plugin_cmd`, and native-disabled text slash fallback.
- Version bumped to `0.0.38` because this is a published runtime behavior fix.
- Focused checks: `vitest run src/inline/monitor.test.ts src/inline/bot-commands-sync.test.ts src/inline/bot-commands-tool.test.ts` passed (113 tests).
- Full package check: `bun run check` passed (typecheck, lint, 296 tests, build).
- `npm view @inline-openclaw/inline@0.0.38 version --json` returned 404, so `0.0.38` is available.
- `npm publish --dry-run --access public` passed for `@inline-openclaw/inline@0.0.38`.
- Sequential release artifact: `/tmp/inline-openclaw-inline-0.0.38.tgz`, shasum `9734c1125cc2098349fda09573ef87fd5cb3a036`, 113 files.
- Local npm auth remains unavailable: `npm whoami` returned `E401 Unauthorized`.

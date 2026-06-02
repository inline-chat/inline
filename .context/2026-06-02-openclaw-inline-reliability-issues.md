# OpenClaw Inline Reliability Issues

## Scope

Close current gaps in Inline OpenClaw command handling, buttons/actions, and reply-thread routing.

## Confirmed Issues

- `/threadreply` is synced into the Inline bot command list, but the monitor treats it as normal group text before mention gating because registered plugin commands are not included in the control-command boolean.
- Gateway logs after local install show Inline dropped group chat `1115` for `no mention`, matching the failed `/threadreply` behavior.
- Local config has `channels.inline.replyThreadMode = "thread"`, but parent-chat replies are still delivered to the parent chat. The monitor was not consistently using top-level Inline defaults as the fallback for account/group reply-thread policy.
- `/threadreply` button callbacks use raw slash payloads such as `/threadreply min 0`; those must be recognized as registered native/plugin commands before mention gating.
- When a parent-chat message is routed into a newly created reply thread, typing was only visible in the child thread after creation. Users in the parent chat needed a typing signal while OpenClaw was creating/looking up the reply thread.

## Findings So Far

- Local installed plugin is `@inline-openclaw/inline@0.0.42`.
- Gateway startup synced Inline bot commands: 65 commands after installing `0.0.42`, up from 63 before release.
- `openclaw plugins inspect inline --json` reports `commands: []`; runtime logs show command sync still happens, so inspect output is not reliable proof of native command registration for this package.
- Built-in command menu button conversion uses `channelData.inline.buttons -> MessageActions` and appears structurally correct.
- Existing tests already cover prefixed native callback payloads such as `icmd:/verbose on` becoming `CommandBody: "/verbose on"`.
- `replyThreadMode: "thread"` should make parent-chat turns eligible for per-message reply threads, but `replyThreadAutoCreateMinMessages` must remain the guard that prevents thread creation for small/new chats unless explicitly set lower, including `0`.
- Existing reply-thread route lookup keys include `parentChatId + parentMessageId + agentId`; tests cover that a new parent message creates a new subthread even when an older active route exists.
- Parent-chat typing should only be mirrored for parent-chat turns that are delivered into an auto-created reply thread. Existing child-thread sessions must stay isolated and should not mirror typing back to their parent chat.
- Mirrored parent typing should not make reply-thread delivery brittle. If parent typing fails but child-thread typing succeeds, delivery should continue and only log the partial typing failure.

## Fix Plan

- Include registered Inline plugin command specs in the command recognition path before mention gating.
- Add a regression test for an authorized group `/threadreply` command with `requireMention: true` and no bot mention.
- Add a regression test for raw slash `/threadreply` button callbacks in require-mention groups.
- Keep `replyThreadAutoCreateMinMessages` as the default guard; expose it through `/threadreply min <n>|inherit`.
- Add a regression test proving top-level `channels.inline.replyThreadMode` is used for parent-chat delivery.
- Add parent-chat typing during reply-thread lookup/create and mirror typing to both parent and child during the auto-created thread dispatch.
- Treat multi-chat typing as failed only when every typing target fails.
- Rebuild, reinstall locally, restart gateway, and verify health/log behavior.

## Current Verification

- Focused Vitest without coverage passed: `threadreply-command.test.ts`, `monitor.test.ts`, `thread-routes.test.ts` (132 tests).
- Typecheck passed: `bun run typecheck`.
- Lint passed: `bun run lint`.
- Build passed: `bun run build`.
- Installed rebuilt `dist` into local OpenClaw package path.
- Restarted gateway; gateway probe is OK and Inline default channel is connected.
- Installed bundle verification found `/threadreply min` command UI and `sendInlineTypingToChats` in the local OpenClaw package.
- Current local config has `channels.inline.replyThreadMode = "thread"` and no explicit `replyThreadAutoCreateMinMessages`, so the default threshold remains `50`.

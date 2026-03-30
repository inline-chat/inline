# OpenClaw Release Restore Plan

## Release-Scope Working Tree

Only these files remain modified in the main worktree for the release:

- `packages/protocol/package.json`
- `packages/sdk/package.json`
- `packages/openclaw-inline/package.json`

These package version/dependency updates are needed so the release chain stays aligned:

- `@inline-chat/protocol` -> `0.0.4`
- `@inline-chat/realtime-sdk` -> `0.0.9` and depends on `@inline-chat/protocol:^0.0.4`
- `@inline-openclaw/inline` -> `0.0.15` and depends on `@inline-chat/realtime-sdk:^0.0.9`

Relevant committed release work already on `main`:

- `d0fd2f54` `openclaw: expose inline entities and formatting guidance`
- `4b0e97ff` `openclaw: support markdown parsing for inline edits`
- `282440d7` `openclaw: harden inline edit-message streaming`

Older committed OpenClaw release work also included in the branch history:

- `06d39680` `openclaw: harden inline media handling`
- `c2d44769` `openclaw: add inline members tool and action aliases`
- `0d7da747` `openclaw: surface inline attachment content`

## Stashes To Restore After Release

Current temporary stashes created for release isolation:

1. `stash@{0}` `temp-post-release-apple-untracked-2026-03-15`
2. `stash@{1}` `temp-release-hold-2026-03-15`

`stash@{0}` contains only these unrelated untracked Apple files:

- `apple/InlineKit/Sources/InlineKit/RichTextHelpers/SlashCommandDetector.swift`
- `apple/InlineKit/Sources/InlineKit/ViewModels/PeerBotCommandsViewModel.swift`
- `apple/InlineKit/Tests/InlineKitTests/PeerBotCommandsViewModelTests.swift`
- `apple/InlineKit/Tests/InlineKitTests/SlashCommandDetectorTests.swift`

`stash@{1}` contains the broader in-progress local work that was present before release isolation, including reply threads, bot commands, protocol/server changes, tests, docs, and other untracked files.

## Restore Order

After publish/deploy is done, restore in this order:

```sh
cd /Users/mo/dev/inline
git stash pop stash@{0}
git stash pop stash@{1}
```

If `stash@{0}` index changes after `stash@{1}` is popped first, the references will shift. Using the order above avoids that.

## Release Validation Already Run

- `cd packages/protocol && bun run build && bun run typecheck`
- `cd packages/sdk && bun run build && bun run typecheck`
- `cd packages/openclaw-inline && bun run typecheck`
- `cd packages/openclaw-inline && bunx vitest run src/index.test.ts src/inline/actions.test.ts src/inline/channel.test.ts src/inline/members-tool.test.ts src/inline/monitor.test.ts src/inline/config-schema.test.ts --coverage --testTimeout=60000`
- `cd packages/openclaw-inline && bun run build`
- `cd server && bun run typecheck`
- `npm pack --dry-run` for `packages/protocol`, `packages/sdk`, and `packages/openclaw-inline`

## Publish Order

```sh
cd /Users/mo/dev/inline/packages/protocol
npm publish --access public --otp=<YOUR_OTP_CODE>

cd /Users/mo/dev/inline/packages/sdk
npm publish --access public --otp=<YOUR_OTP_CODE>

cd /Users/mo/dev/inline/packages/openclaw-inline
npm publish --access public --otp=<YOUR_OTP_CODE>
```

# Inline Bot Commands Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add server-backed bot commands plus peer-scoped `/` command discovery and insertion on Apple clients, while keeping v1 delivery text-only.

**Architecture:** Extend the protocol and database with bot-command metadata, expose both owner RPCs and bot-token API methods on the server, and fetch peer-scoped command groups on demand from compose. Reuse existing bot ownership checks, bot API routing, and Apple mention-completion architecture instead of introducing a new message entity or realtime command updates in v1.

**Tech Stack:** Bun/TypeScript, Drizzle ORM, protobuf-ts, Elysia, Swift, AppKit, UIKit, InlineKit, InlineProtocol.

---

## Inputs

- Spec/design source: `.agent-docs/2026-03-12-inline-bot-commands-plan.md`
- Do not add web/admin work in this pass.
- Do not add a `MessageEntity` bot-command type in v1.
- Ship order remains backend -> macOS -> iOS.

## File Structure

### Protocol and generated outputs

- Modify: `proto/core.proto`
- Regenerate: `packages/protocol/src/core.ts`
- Regenerate: `packages/protocol/src/client.ts`
- Regenerate: `packages/protocol/src/server.ts`
- Regenerate: `apple/InlineKit/Sources/InlineProtocol/core.pb.swift`
- Regenerate: `apple/InlineKit/Sources/InlineProtocol/client.pb.swift`

### Server storage and RPCs

- Create: `server/src/db/schema/botCommands.ts`
- Create: `server/src/db/models/botCommands.ts`
- Create: `server/src/functions/bot.getCommands.ts`
- Create: `server/src/functions/bot.setCommands.ts`
- Create: `server/src/functions/bot.getPeerCommands.ts`
- Create: `server/src/realtime/handlers/getBotCommands.ts`
- Create: `server/src/realtime/handlers/setBotCommands.ts`
- Create: `server/src/realtime/handlers/getPeerBotCommands.ts`
- Modify: `server/src/db/schema/index.ts`
- Modify: `server/src/functions/_functions.ts`
- Modify: `server/src/realtime/handlers/_rpc.ts`
- Generate: `server/drizzle/<next>_bot_commands.sql`

### Public bot API and SDKs

- Modify: `server/src/controllers/bot/bot.ts`
- Modify: `server/src/controllers/bot/types.ts`
- Modify: `packages/bot-api-types/src/index.ts`
- Modify: `packages/bot-api/src/index.ts`
- Modify: `packages/bot-api/src/types.ts`
- Modify: `packages/bot-api/src/inline-bot-api-client.ts`

### Apple shared slash-command support

- Create: `apple/InlineKit/Sources/InlineKit/RichTextHelpers/SlashCommandDetector.swift`
- Create: `apple/InlineKit/Sources/InlineKit/ViewModels/PeerBotCommandsViewModel.swift`
- Create: `apple/InlineKit/Tests/InlineKitTests/SlashCommandDetectorTests.swift`
- Create: `apple/InlineKit/Tests/InlineKitTests/PeerBotCommandsViewModelTests.swift`

### macOS compose

- Create: `apple/InlineMac/Views/Compose/CommandCompletionMenu.swift`
- Create: `apple/InlineMac/Views/Compose/CommandCompletionMenuItem.swift`
- Modify: `apple/InlineMac/Views/Compose/ComposeAppKit.swift`

### iOS compose

- Create: `apple/InlineIOS/Features/Compose/SlashCommandManager.swift`
- Create: `apple/InlineIOS/Features/Compose/SlashCommandCompletionView.swift`
- Create: `apple/InlineIOS/Features/Compose/SlashCommandManagerDelegate.swift`
- Modify: `apple/InlineIOS/Features/Compose/ComposeView.swift`
- Modify: `apple/InlineIOS/Features/Compose/UITextViewDelegate.swift`
- Modify: `apple/InlineIOS/Features/Compose/KeyboardManagement.swift`

### Tests

- Create: `server/src/__tests__/functions/botCommands.test.ts`
- Create: `server/src/__tests__/handlers/botCommands.test.ts`
- Modify: `server/src/__tests__/bot-api.test.ts`
- Modify: `packages/bot-api/src/inline-bot-api-client.test.ts`
- Modify: `packages/openclaw-inline/src/inline/channel.ts`
- Modify: `packages/openclaw-inline/src/inline/monitor.ts`
- Modify: `packages/openclaw-inline/src/inline/monitor.test.ts`

## Chunk 1: Protocol and Persistence Foundation

### Task 1: Add failing backend contract and validation tests

**Files:**
- Create: `server/src/__tests__/functions/botCommands.test.ts`
- Modify: `server/src/__tests__/bot-api.test.ts`

- [ ] **Step 1: Add failing function tests for command storage and peer resolution**

Cover these cases explicitly:
- owner can replace a bot command list
- non-owner is rejected
- deleted/non-bot user is rejected
- invalid command names are rejected
- command length outside `1...32` is rejected
- invalid descriptions are rejected
- description length outside `1...256` is rejected
- more than `100` commands is rejected
- replace-all semantics delete removed commands
- round-trip ordering stays stable after `setCommands`
- `getPeerBotCommands` returns only relevant bots for:
  private DM with bot, non-space thread, public space thread, private space thread
- duplicate command names across relevant bots stay grouped by bot
- returned bot payloads include usernames

- [ ] **Step 2: Add failing bot API tests for `getMyCommands`, `setMyCommands`, `deleteMyCommands`**

Assert concrete HTTP behavior in `server/src/__tests__/bot-api.test.ts`:
- `getMyCommands` returns `{ ok: true, result: { commands: [] } }` for a bot with no commands
- `setMyCommands` returns `{ ok: true, result: {} }`
- `setMyCommands` followed by `getMyCommands` round-trips the exact list and order
- invalid payloads return a bot API error envelope
- `deleteMyCommands` returns `{ ok: true, result: {} }`
- `deleteMyCommands` followed by `getMyCommands` returns an empty list

- [ ] **Step 3: Run the new tests to confirm they fail for missing functionality**

Run: `cd server && bun test src/__tests__/functions/botCommands.test.ts src/__tests__/bot-api.test.ts`

Expected:
- `botCommands.test.ts` fails because storage/RPCs do not exist yet
- bot API tests fail because methods are not registered yet

- [ ] **Step 4: Commit the red tests**

```bash
git add server/src/__tests__/functions/botCommands.test.ts server/src/__tests__/bot-api.test.ts
git commit -m "server: add failing bot commands tests"
```

### Task 2: Add bot command schema, model, and migration

**Files:**
- Create: `server/src/db/schema/botCommands.ts`
- Create: `server/src/db/models/botCommands.ts`
- Modify: `server/src/db/schema/index.ts`
- Generate: `server/drizzle/<next>_bot_commands.sql`

- [ ] **Step 1: Add the schema table**

Use these columns and constraints:
- `id`
- `bot_user_id`
- `command`
- `description`
- `sort_order`
- `created_at`
- `updated_at`
- unique index on `(bot_user_id, command)`

Use `users.id` as the foreign key and follow the style used in `server/src/db/schema/botTokens.ts` and `server/src/db/schema/users.ts`.

- [ ] **Step 2: Add a focused `BotCommandsModel`**

Model responsibilities:
- fetch one bot’s commands ordered by `sort_order`, then `command`
- replace all commands for one bot inside a transaction
- fetch grouped commands for a list of bot ids
- keep persistence concerns here, not auth/rpc concerns

- [ ] **Step 3: Generate the migration instead of hand-writing it**

Run: `cd server && bun run db:generate bot_commands`

Expected:
- a new SQL migration appears under `server/drizzle/`

- [ ] **Step 4: Re-run the function tests after schema/model wiring**

Run: `cd server && bun test src/__tests__/functions/botCommands.test.ts`

Expected:
- storage-related failures are gone
- remaining failures point at missing protocol/rpc/public API work

- [ ] **Step 5: Commit the persistence layer**

```bash
git add server/src/db/schema/botCommands.ts server/src/db/models/botCommands.ts server/src/db/schema/index.ts server/drizzle
git commit -m "server: add bot commands storage"
```

### Task 3: Extend protocol types and regenerate clients

**Files:**
- Modify: `proto/core.proto`
- Regenerate: `packages/protocol/src/core.ts`
- Regenerate: `packages/protocol/src/client.ts`
- Regenerate: `packages/protocol/src/server.ts`
- Regenerate: `apple/InlineKit/Sources/InlineProtocol/core.pb.swift`
- Regenerate: `apple/InlineKit/Sources/InlineProtocol/client.pb.swift`

- [ ] **Step 1: Add protocol messages**

Add:
- `BotCommand`
- `PeerBotCommands`
- `GetBotCommandsInput`
- `GetBotCommandsResult`
- `SetBotCommandsInput`
- `SetBotCommandsResult`
- `GetPeerBotCommandsInput`
- `GetPeerBotCommandsResult`

Add new realtime methods for:
- `GET_BOT_COMMANDS`
- `SET_BOT_COMMANDS`
- `GET_PEER_BOT_COMMANDS`

Keep `PeerBotCommands.bot` as `User` so username rides along in the existing user payload.

- [ ] **Step 2: Regenerate TypeScript and Swift protocol outputs**

Run: `bun run generate:proto`

Expected:
- `packages/protocol/src/core.ts` includes new method enums and message types
- `packages/protocol/src/client.ts` and `packages/protocol/src/server.ts` stay in sync with the regenerated protocol package
- `apple/InlineKit/Sources/InlineProtocol/core.pb.swift` includes the new rpc cases and messages
- `apple/InlineKit/Sources/InlineProtocol/client.pb.swift` stays in sync with the Swift protocol package

- [ ] **Step 3: Typecheck the generated protocol package**

Run: `bun run --cwd packages/protocol typecheck`

Expected:
- the generated protocol package typechecks cleanly

- [ ] **Step 4: Commit protocol changes**

```bash
git add proto/core.proto packages/protocol/src/core.ts packages/protocol/src/client.ts packages/protocol/src/server.ts apple/InlineKit/Sources/InlineProtocol/core.pb.swift apple/InlineKit/Sources/InlineProtocol/client.pb.swift
git commit -m "server: add bot commands protocol types"
```

## Chunk 2: Server RPCs and Peer Resolution

### Task 4: Implement owner RPCs and peer-scoped lookup

**Files:**
- Create: `server/src/functions/bot.getCommands.ts`
- Create: `server/src/functions/bot.setCommands.ts`
- Create: `server/src/functions/bot.getPeerCommands.ts`
- Create: `server/src/realtime/handlers/getBotCommands.ts`
- Create: `server/src/realtime/handlers/setBotCommands.ts`
- Create: `server/src/realtime/handlers/getPeerBotCommands.ts`
- Modify: `server/src/functions/_functions.ts`
- Modify: `server/src/realtime/handlers/_rpc.ts`
- Test: `server/src/__tests__/functions/botCommands.test.ts`
- Test: `server/src/__tests__/handlers/botCommands.test.ts`

- [ ] **Step 1: Implement `bot.getCommands`**

Behavior:
- validate `bot_user_id`
- ensure the target user exists, is a bot, is not deleted, and belongs to `currentUserId`
- return the bot’s commands in protocol form

- [ ] **Step 2: Implement `bot.setCommands` with replace-all semantics**

Behavior:
- owner-only
- validate limits before touching the database:
  lowercase `[a-z0-9_]+`
  length `1...32`
  description length `1...256`
  max `100` commands
- normalize `sort_order` so stable ordering survives round-trips
- replace commands inside one transaction
- make the stable ordering observable in tests

- [ ] **Step 3: Implement `bot.getPeerCommands`**

Peer resolution rules:
- DM with bot: the bot user only
- non-space private/group thread: bot chat participants only
- space public thread: space bot members with `canAccessPublicChats == true`
- space private thread: bot chat participants only

Before bot resolution:
- validate `peer_id`
- reject missing/nonexistent/inaccessible peers using the same access checks used for other chat/member flows

Return grouped results as `PeerBotCommands[]`, not a flattened list.

- [ ] **Step 4: Wire realtime handlers and `_rpc.ts`**

Make these registrations explicit:
- add `getCommands`, `setCommands`, and `getPeerCommands` under the `bot` namespace in `server/src/functions/_functions.ts`
- add handlers for `GET_BOT_COMMANDS`, `SET_BOT_COMMANDS`, and `GET_PEER_BOT_COMMANDS` in `server/src/realtime/handlers/_rpc.ts`
- map each new enum case to the matching request `oneofKind` and response `oneofKind`

- [ ] **Step 5: Run focused backend tests**

Run: `cd server && bun test src/__tests__/functions/botCommands.test.ts src/__tests__/handlers/botCommands.test.ts`

Expected:
- function tests pass
- handler/rpc smoke tests prove the new realtime methods dispatch to the correct handlers

- [ ] **Step 6: Run focused server typecheck**

Run: `cd server && bun run typecheck`

Expected:
- server typecheck passes with the new protocol methods

- [ ] **Step 7: Commit the rpc/function layer**

```bash
git add server/src/functions/bot.getCommands.ts server/src/functions/bot.setCommands.ts server/src/functions/bot.getPeerCommands.ts server/src/realtime/handlers/getBotCommands.ts server/src/realtime/handlers/setBotCommands.ts server/src/realtime/handlers/getPeerBotCommands.ts server/src/functions/_functions.ts server/src/realtime/handlers/_rpc.ts server/src/__tests__/functions/botCommands.test.ts server/src/__tests__/handlers/botCommands.test.ts
git commit -m "server: add bot commands rpc functions"
```

## Chunk 3: Public Bot API, SDKs, and OpenClaw Compatibility

### Task 5: Extend bot-token API and SDK surface

**Files:**
- Modify: `server/src/controllers/bot/bot.ts`
- Modify: `server/src/controllers/bot/types.ts`
- Modify: `packages/bot-api-types/src/index.ts`
- Modify: `packages/bot-api/src/types.ts`
- Modify: `packages/bot-api/src/index.ts`
- Modify: `packages/bot-api/src/inline-bot-api-client.ts`
- Modify: `packages/bot-api/src/inline-bot-api-client.test.ts`
- Modify: `server/src/__tests__/bot-api.test.ts`

- [ ] **Step 1: Add public types for bot commands**

Add to `@inline-chat/bot-api-types`:
- `BotCommand`
- `GetMyCommandsResult`
- `SetMyCommandsParams`
- `DeleteMyCommandsResult`

Extend `BotMethodName`, `BotMethodParamsByName`, and `BotMethodResultByName`.

Use this concrete contract:
- `getMyCommands -> { commands: BotCommand[] }`
- `setMyCommands -> {}`
- `deleteMyCommands -> {}`

- [ ] **Step 2: Add client helpers in `InlineBotApiClient`**

Add:
- `getMyCommands()`
- `setMyCommands(params)`
- `deleteMyCommands()`

Keep `getMethodNames` limited to true GET endpoints; `setMyCommands` and `deleteMyCommands` stay POST.

- [ ] **Step 3: Add bot controller routes**

In `server/src/controllers/bot/bot.ts`:
- `GET /bot/getMyCommands`
- `POST /bot/setMyCommands`
- `POST /bot/deleteMyCommands`

Route behavior:
- authenticate bot via existing middleware
- call the new function layer against `store.currentUserId`
- define request/response schemas in `server/src/controllers/bot/types.ts`
- return Telegram-style `{ ok: true, result: ... }` using the explicit result contracts above

- [ ] **Step 4: Add and run focused SDK/controller tests**

Run:
- `bun test packages/bot-api/src/inline-bot-api-client.test.ts`
- `bun run --cwd packages/bot-api typecheck`
- `cd server && bun test src/__tests__/bot-api.test.ts`

Expected:
- SDK tests cover method paths/query-vs-post behavior for the new methods
- `@inline-chat/bot-api` typechecks after the exported method map changes
- server bot API tests cover auth + replace/delete behavior

- [ ] **Step 5: Commit public API changes**

```bash
git add packages/bot-api-types/src/index.ts packages/bot-api/src/types.ts packages/bot-api/src/index.ts packages/bot-api/src/inline-bot-api-client.ts packages/bot-api/src/inline-bot-api-client.test.ts server/src/controllers/bot/bot.ts server/src/controllers/bot/types.ts server/src/__tests__/bot-api.test.ts
git commit -m "sdk: add bot command api methods"
```

### Task 6: Preserve `/command@botusername` compatibility in OpenClaw

**Files:**
- Modify: `packages/openclaw-inline/src/inline/channel.ts`
- Modify: `packages/openclaw-inline/src/inline/monitor.ts`
- Modify: `packages/openclaw-inline/src/inline/monitor.test.ts`

- [ ] **Step 1: Thread bot username through the concrete inbound path**

Use the actual inbound flow:
- Inline inbound event assembly in `packages/openclaw-inline/src/inline/monitor.ts`
- channel/runtime handoff in `packages/openclaw-inline/src/inline/channel.ts`

Capture the active bot username from the Inline-side message/bot context and carry it into the object consumed by OpenClaw text-command detection.

- [ ] **Step 2: Pass the active bot username into detection**

Requirement:
- `/command` still works in DMs
- `/command@botusername` is recognized in multi-bot/group contexts

- [ ] **Step 3: Add a regression test**

Add a regression in `packages/openclaw-inline/src/inline/monitor.test.ts` that proves the inbound monitor path preserves `@botusername` targeting all the way into command detection.

- [ ] **Step 4: Run the focused package test**

Run:
- `bun test packages/openclaw-inline/src/inline/monitor.test.ts`
- `bun run --cwd packages/openclaw-inline typecheck`

Expected:
- the targeted command regression passes
- the package still typechecks after the new inbound context field is added

- [ ] **Step 5: Commit the compatibility fix**

```bash
git add packages/openclaw-inline/src/inline/channel.ts packages/openclaw-inline/src/inline/monitor.ts packages/openclaw-inline/src/inline/monitor.test.ts
git commit -m "openclaw: support targeted bot commands"
```

## Chunk 4: Shared Apple Slash-Command Infrastructure and macOS UI

### Task 7: Add shared slash detection and peer command fetching in InlineKit

**Files:**
- Create: `apple/InlineKit/Sources/InlineKit/RichTextHelpers/SlashCommandDetector.swift`
- Create: `apple/InlineKit/Sources/InlineKit/ViewModels/PeerBotCommandsViewModel.swift`
- Create: `apple/InlineKit/Tests/InlineKitTests/SlashCommandDetectorTests.swift`
- Create: `apple/InlineKit/Tests/InlineKitTests/PeerBotCommandsViewModelTests.swift`

- [ ] **Step 1: Add failing InlineKit tests for slash detection**

Cover:
- trigger at start of input
- trigger after whitespace
- trigger after newline
- no trigger mid-word
- replacement range includes the active `/query`
- replacement helper inserts trailing space and returns the new cursor

- [ ] **Step 2: Implement `SlashCommandDetector`**

Keep it parallel to `MentionDetector`, not a shared generic parser yet.

Public API should mirror mention detector shape closely:
- detect current slash token
- replace current range with plain text command insertion

- [ ] **Step 3: Implement `PeerBotCommandsViewModel`**

Responsibilities:
- fetch `getPeerBotCommands` once per compose session / peer
- cache grouped results in memory
- expose flattened suggestion data with bot username, description, and ambiguity metadata
- normalize command names case-insensitively when computing ambiguity/collision state
- keep networking/cache logic out of the macOS/iOS view classes

- [ ] **Step 4: Run InlineKit tests**

Run:
- `cd apple/InlineKit && swift test --filter SlashCommandDetectorTests`
- `cd apple/InlineKit && swift test --filter PeerBotCommandsViewModelTests`

Expected:
- slash detector tests pass
- peer command fetch/cache/ambiguity tests pass

- [ ] **Step 5: Commit the shared Apple infrastructure**

```bash
git add apple/InlineKit/Sources/InlineKit/RichTextHelpers/SlashCommandDetector.swift apple/InlineKit/Sources/InlineKit/ViewModels/PeerBotCommandsViewModel.swift apple/InlineKit/Tests/InlineKitTests/SlashCommandDetectorTests.swift apple/InlineKit/Tests/InlineKitTests/PeerBotCommandsViewModelTests.swift
git commit -m "apple: add shared slash command infrastructure"
```

### Task 8: Add macOS slash-command completion menu

**Files:**
- Create: `apple/InlineMac/Views/Compose/CommandCompletionMenu.swift`
- Create: `apple/InlineMac/Views/Compose/CommandCompletionMenuItem.swift`
- Modify: `apple/InlineMac/Views/Compose/ComposeAppKit.swift`

- [ ] **Step 1: Add a dedicated command menu UI**

Do not force command rows into `MentionCompletionMenu`.

Each row should show:
- `/command`
- description
- bot label when more than one relevant bot is available for the peer

- [ ] **Step 2: Wire detection, fetch, filtering, and keyboard handling into `ComposeAppKit`**

Behavior:
- detect slash token from cursor changes and text edits
- fetch peer commands lazily through `PeerBotCommandsViewModel`
- filter locally as the query changes
- reuse arrow/enter/tab/escape behavior from mention handling
- keep slash-specific state/helpers in a focused extension or helper object so `ComposeAppKit.swift` does not absorb unrelated logic

- [ ] **Step 3: Implement insertion rules**

Selection inserts:
- `/command ` when only one relevant bot exposes that normalized command
- `/command@botusername ` when the selected command name is ambiguous within the current peer

Do not modify send behavior; insertion only changes compose text.

- [ ] **Step 4: Run what can be verified without full app builds**

Run: `cd apple/InlineKit && swift build`

Expected:
- shared Swift packages still compile

If you want actual macOS app-target compile verification, ask the user before running a focused `xcodebuild` for the macOS target. If the user does not approve it, record that macOS app-target compilation is still outstanding.

Manual checks in the macOS app after implementation:
- slash at line start and after whitespace opens the menu
- no trigger for `test/abc`
- keyboard navigation works
- in a multi-bot peer, non-ambiguous commands still insert `/command ` without `@botusername`
- duplicate commands disambiguate with `@botusername`
- rows show the owning bot label when more than one relevant bot is present

- [ ] **Step 5: Commit macOS compose support**

```bash
git add apple/InlineMac/Views/Compose/CommandCompletionMenu.swift apple/InlineMac/Views/Compose/CommandCompletionMenuItem.swift apple/InlineMac/Views/Compose/ComposeAppKit.swift
git commit -m "macos: add bot command compose menu"
```

## Chunk 5: iOS Compose Integration and Final Verification

### Task 9: Add iOS slash-command manager and completion UI

**Files:**
- Create: `apple/InlineIOS/Features/Compose/SlashCommandManager.swift`
- Create: `apple/InlineIOS/Features/Compose/SlashCommandCompletionView.swift`
- Create: `apple/InlineIOS/Features/Compose/SlashCommandManagerDelegate.swift`
- Modify: `apple/InlineIOS/Features/Compose/ComposeView.swift`
- Modify: `apple/InlineIOS/Features/Compose/UITextViewDelegate.swift`
- Modify: `apple/InlineIOS/Features/Compose/KeyboardManagement.swift`

- [ ] **Step 1: Add a slash manager that mirrors mention responsibilities**

Use these concrete references as the model:
- `apple/InlineIOS/Features/Compose/MentionManager.swift`
- `apple/InlineIOS/Features/Compose/MentionCompletionView.swift`
- `apple/InlineIOS/Features/Compose/MentionManagerDelegate.swift`

Manager responsibilities:
- own `SlashCommandDetector`
- subscribe to `PeerBotCommandsViewModel`
- manage current active slash range
- drive completion view visibility/filtering
- insert selected command text back into the `UITextView`

- [ ] **Step 2: Add the completion view**

Row content:
- `/command`
- description
- optional bot label in multi-bot peers

Match the keyboard semantics already handled by `MentionCompletionView` and `KeyboardManagement.swift`.

- [ ] **Step 3: Wire compose delegates**

Update:
- `ComposeView.swift` to create/cleanup the manager
- `UITextViewDelegate.swift` to trigger detection on change/selection, preserve entity-clearing behavior, and avoid fighting mention logic
- `KeyboardManagement.swift` to route arrows/tab/enter/escape to the slash manager before falling back

Clear `originalDraftEntities` after slash insertion, same as mention edits.
Keep slash-specific code out of `ComposeView.swift` where possible; prefer the new manager/delegate files for behavior.

- [ ] **Step 4: Implement ambiguity-aware insertion**

Use the same normalized command-collision rule as macOS:
- unique command in current peer -> `/command `
- colliding command names in current peer -> `/command@botusername `

- [ ] **Step 5: Run focused Swift package verification**

Run: `cd apple/InlineKit && swift build`

Expected:
- shared package changes still compile after the iOS manager uses them

If you want actual iOS app-target compile verification, ask the user before running a focused `xcodebuild` for the iOS target. If the user does not approve it, record that iOS app-target compilation is still outstanding.

- [ ] **Step 6: Perform manual iOS checks**

Manual checks:
- trigger at start/after whitespace/newline
- no trigger mid-word
- live filtering
- keyboard navigation on hardware keyboard
- multi-bot results visibly show the owning bot label
- insert unique commands without username even in multi-bot peer
- insert ambiguous commands with `@botusername`
- sending still emits plain text through existing `sendMessage`

- [ ] **Step 7: Commit iOS compose support**

```bash
git add apple/InlineIOS/Features/Compose/SlashCommandManager.swift apple/InlineIOS/Features/Compose/SlashCommandCompletionView.swift apple/InlineIOS/Features/Compose/SlashCommandManagerDelegate.swift apple/InlineIOS/Features/Compose/ComposeView.swift apple/InlineIOS/Features/Compose/UITextViewDelegate.swift apple/InlineIOS/Features/Compose/KeyboardManagement.swift
git commit -m "ios: add slash command compose suggestions"
```

### Task 10: Final focused verification and readiness check

**Files:**
- Review touched files only

- [ ] **Step 1: Re-run focused backend checks**

Run:
- `cd server && bun test src/__tests__/functions/botCommands.test.ts src/__tests__/handlers/botCommands.test.ts src/__tests__/bot-api.test.ts`
- `cd server && bun run typecheck`

Expected:
- all focused backend checks pass

- [ ] **Step 2: Re-run focused package checks**

Run:
- `bun test packages/bot-api/src/inline-bot-api-client.test.ts`
- `bun run --cwd packages/bot-api typecheck`
- `bun test packages/openclaw-inline/src/inline/monitor.test.ts`
- `bun run --cwd packages/openclaw-inline typecheck`
- `cd apple/InlineKit && swift test --filter SlashCommandDetectorTests`
- `cd apple/InlineKit && swift test --filter PeerBotCommandsViewModelTests`
- `cd apple/InlineKit && swift build`

Expected:
- focused JS/TS/Swift checks pass

- [ ] **Step 3: Record manual verification**

Document the results in `.agent-docs/2026-03-15-inline-bot-commands-verification.md`:
- macOS slash menu behavior
- iOS slash menu behavior
- duplicate command ambiguity behavior
- unique-command behavior in multi-bot peers
- DM/private/public-thread peer resolution cases
- whether focused app-target `xcodebuild` verification was run or remains outstanding

- [ ] **Step 4: Review for production risks before merge**

Call out explicitly:
- Security: only bot owners and authenticated bot tokens can mutate command metadata
- Performance: peer command lookup must stay bounded and avoid repeated fetches while typing
- Production readiness: v1 is ready only after manual Apple verification in both macOS and iOS compose surfaces

- [ ] **Step 5: Final commit if cleanup/fixes were required**

```bash
git add proto/core.proto packages/protocol/src/core.ts packages/protocol/src/client.ts packages/protocol/src/server.ts packages/bot-api-types/src/index.ts packages/bot-api/src server/src apple/InlineKit apple/InlineMac apple/InlineIOS packages/openclaw-inline/src/inline/channel.ts packages/openclaw-inline/src/inline/monitor.ts packages/openclaw-inline/src/inline/monitor.test.ts .agent-docs/2026-03-15-inline-bot-commands-verification.md
git commit -m "chore: finalize bot commands rollout"
```

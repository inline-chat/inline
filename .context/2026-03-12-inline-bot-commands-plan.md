# Inline Bot Commands Plan

## Goal

Allow bots to publish a list of commands with descriptions, and let users discover and insert those commands from the compose `/` menu.

The user-facing v1 outcome:

- Bots can register commands.
- When a user types `/` in compose, Inline shows matching commands for bots relevant to the current peer.
- Each row shows the command and description.
- Selecting a row inserts the command text into compose so the user can send it as a normal message.

## Recommended V1 Scope

Keep v1 intentionally smaller than Telegram:

- One global command list per bot.
- No Telegram-style language or scope variants yet.
- No new `MessageEntity` type for bot commands in v1.
- No realtime update type for command metadata in v1.
- No web/admin work unless explicitly requested.

Why this scope:

- Inline does not currently have any bot command model in protocol or DB.
- Compose already has reusable mention suggestion infrastructure on iOS and macOS.
- Fetch-on-demand is enough for command metadata; commands change rarely.
- A dedicated bot-command entity would increase protocol and text-processing blast radius without improving the core UX.

## Product Decisions

### Command ownership

- Commands belong to a bot user.
- The canonical storage is server-side, not embedded on `User`.
- Public bot API should let an authenticated bot manage its own commands.

### Compose behavior

- Trigger on `/` when it starts a token: start of input, after whitespace, or after newline.
- Filter locally as the user keeps typing.
- Selecting a command inserts `/command `.
- If multiple relevant bots in the current peer expose the same normalized command name, treat that command as ambiguous and insert `/command@botusername `.
- If only one relevant bot exposes that command name, insert `/command ` even if other bots are present in the peer.
- In peers with more than one relevant bot, show a bot label on each command row so duplicates are understandable before selection.

### Peer resolution

Commands shown in compose should be peer-scoped:

- DM with a bot: use that bot’s commands.
- Non-space private/group thread: use commands from bot chat participants.
- Space public thread: use commands from bot space members that can access public chats.
- Space private thread: use commands from bot chat participants.

### Freshness

- Fetch commands when compose first needs them for the current peer.
- Keep an in-memory cache for the compose session.
- Do not add a new updates payload for v1.

### Delivery semantics

- Selection only inserts text.
- Sending remains the existing `sendMessage` flow.
- Bots should parse `/command` and `/command@their_username` from incoming text.

OpenClaw compatibility requirement:

- The Inline OpenClaw plugin should pass the current bot username into OpenClaw text-command detection so `/command@botusername` is recognized in groups, matching the existing Telegram parsing path.
- This is a small channel-plugin compatibility change, not a reason to add native command dispatch in v1.

Important limitation:

- The current public bot API still does not expose inbound message delivery like Telegram webhooks or `getUpdates`.
- This plan makes command discovery and insertion work.
- End-to-end bot responsiveness for external bots remains a separate follow-up if needed.

## Backend Plan

### 1. Add a bot commands table

Add a new schema and model:

- `server/src/db/schema/botCommands.ts`
- export it from `server/src/db/schema/index.ts`
- add a matching model under `server/src/db/models/`

Recommended columns:

- `id`
- `bot_user_id`
- `command`
- `description`
- `sort_order`
- `created_at`
- `updated_at`

Recommended constraints:

- unique on `(bot_user_id, command)`
- foreign key to `users.id`
- reject deleted/non-bot users at write time

Recommended validation:

- command format: lowercase `[a-z0-9_]+`
- command length: 1-32
- description length: 1-256
- max commands per bot: 100

Those limits line up with Telegram and keep future compatibility simple.

### 2. Add protocol types and RPCs

Extend `proto/core.proto` with new types:

- `BotCommand`
- `GetBotCommandsInput`
- `GetBotCommandsResult`
- `SetBotCommandsInput`
- `SetBotCommandsResult`
- `GetPeerBotCommandsInput`
- `GetPeerBotCommandsResult`
- `PeerBotCommands`

Recommended shape:

- `BotCommand { string command; string description; optional int32 sort_order; }`
- `PeerBotCommands { User bot; repeated BotCommand commands; }`
- `GetBotCommandsInput { int64 bot_user_id = 1; }`
- `SetBotCommandsInput { int64 bot_user_id = 1; repeated BotCommand commands = 2; }`
- `GetPeerBotCommandsInput { InputPeer peer_id = 1; }`
- `GetPeerBotCommandsResult { repeated PeerBotCommands bots = 1; }`

Important requirement:

- `PeerBotCommands.bot` must include the bot username. Clients should not have to infer command ownership or insertion format by separately scanning peer participants.

Wire these through:

- `proto/core.proto`
- generated protocol packages
- `server/src/functions/_functions.ts`
- `server/src/realtime/handlers/_rpc.ts`
- Apple generated Swift protos after regeneration

### 3. Add internal server functions

Add new server functions:

- `server/src/functions/bot.getCommands.ts`
- `server/src/functions/bot.setCommands.ts`
- `server/src/functions/bot.getPeerCommands.ts`

Behavior:

- `get/setBotCommands`: owner-only, validated against `users.bot` and `users.botCreatorId`
- `setBotCommands`: replace-all semantics inside a transaction
- `getPeerBotCommands`: resolve relevant bots for the current peer and return grouped command lists

Peer resolution should reuse existing chat/member access patterns already used around:

- `server/src/db/models/chats.ts`
- `server/src/modules/updates/index.ts`
- `server/src/db/schema/chats.ts`
- `server/src/db/schema/members.ts`

### 4. Extend the public bot API

Add bot-token methods so bots can expose commands themselves:

- `getMyCommands`
- `setMyCommands`
- `deleteMyCommands`

Touchpoints:

- `packages/bot-api-types/src/index.ts`
- `packages/bot-api/src/`
- `server/src/controllers/bot/bot.ts`

Behavior:

- `getMyCommands`: returns the authenticated bot’s command list
- `setMyCommands`: replace-all list
- `deleteMyCommands`: clears the list

This keeps the external bot API aligned with Telegram naming, which is useful for adoption and expectation-setting.

### 5. Defer bot-command entities

Do not add a new `MessageEntity.Type` in v1.

Current state:

- `proto/core.proto` only has mention/link/formatting entity types.
- compose send paths already work with plain text plus existing entities.

Follow-up only if needed:

- `TYPE_BOT_COMMAND`
- bot-command parsing in shared text processing
- rendering/styling hooks
- bot API entity encoding/decoding support

## Apple Client Plan

### 1. Shared trigger detection

Add a slash detector in `InlineKit` alongside the mention detector:

- `apple/InlineKit/Sources/InlineKit/RichTextHelpers/SlashCommandDetector.swift`

Keep it parallel to the current mention implementation rather than over-generalizing immediately. If both implementations converge cleanly afterward, they can be unified later.

Responsibilities:

- detect active slash command at cursor
- return command query range
- replace the active range with the chosen command text

### 2. iOS compose

Add a slash command manager and completion UI in:

- `apple/InlineIOS/Features/Compose/`

Likely files:

- `SlashCommandManager.swift`
- `SlashCommandCompletionView.swift`
- `SlashCommandManagerDelegate.swift`

Integrate with the existing compose flow around:

- `apple/InlineIOS/Features/Compose/ComposeView.swift`
- `apple/InlineIOS/Features/Compose/UITextViewDelegate.swift`
- `apple/InlineIOS/Features/Compose/KeyboardManagement.swift`

Recommended behavior:

- fetch `getPeerBotCommands` on first `/` use for the peer
- flatten or filter grouped results locally
- render `/command`, description, and optional bot label
- keyboard handling mirrors mention handling: arrows, enter/tab, escape

Selection behavior:

- normalize command-name matching case-insensitively when deciding ambiguity
- insert `/command ` when only one relevant bot exposes that command name
- insert `/command@botusername ` when more than one relevant bot exposes that command name
- in multi-bot peers, show the owning bot label even for non-ambiguous commands so users can see where the command comes from
- clear `originalDraftEntities` after replacement, same as mention edits

### 3. macOS compose

Reuse the existing AppKit mention-menu architecture in:

- `apple/InlineMac/Views/Compose/ComposeAppKit.swift`
- `apple/InlineMac/Views/Compose/ComposeTextView.swift`
- `apple/InlineMac/Views/Compose/MentionCompletionMenu.swift`

Recommended implementation:

- add a dedicated command completion menu rather than forcing command rows into mention row UI
- share placement and keyboard behavior with the existing mention menu

Likely files:

- `apple/InlineMac/Views/Compose/CommandCompletionMenu.swift`
- `apple/InlineMac/Views/Compose/CommandCompletionMenuItem.swift`

Behavior should match iOS:

- same trigger rules
- same peer fetch rules
- same ambiguity rules
- same insertion/disambiguation rules

### 4. No explicit commands button in v1

Telegram also exposes commands from a dedicated menu button, but that is not required for the requested outcome.

Defer until after slash-trigger discovery works well.

## Suggested Rollout Order

### Phase 1: server model and APIs

- DB table and model
- internal proto RPCs
- public bot API methods
- tests for validation, auth, and peer resolution

### Phase 2: macOS slash menu

- AppKit command menu
- keyboard navigation
- insertion behavior

### Phase 3: iOS slash menu

- detector
- command manager
- completion list
- insertion behavior

### Phase 4: docs and polish

- bot API reference docs
- examples for `setMyCommands`
- optional owner-facing settings UI later

## Testing Plan

### Backend

Add focused tests for:

- set/get/delete commands auth rules
- invalid command names and descriptions
- replace-all semantics
- peer resolution in DM, private thread, and space thread cases
- multi-bot peers
- duplicate command names across bots
- peer command results include bot usernames
- ambiguity detection uses command-name collisions, not only bot count

Likely locations:

- `server/src/__tests__/functions/`
- route/controller tests for public bot API if present in current test setup

### Apple

Validate with focused builds and manual behavior checks:

- slash detection at start of line and after whitespace
- no trigger for mid-word `/`
- filtering as the query changes
- keyboard navigation
- insertion without `@botusername` for unique commands in multi-bot peers
- insertion with `@botusername` only for ambiguous commands
- multi-bot rows visibly identify the owning bot
- compose send still emits normal text

## Final V1 Decisions

- Start with bot-token APIs only; owner-side settings UI follows later.
- In multi-bot peers, insert `@botusername` only when the selected command name is ambiguous within the current peer result set.
- Ship backend + macOS first, then iOS.
- Use Telegram-compatible public bot API names and Inline-native internal RPC names.
- Keep v1 text-only. Do not add native command dispatch yet.

## Concrete File Touchpoints

Primary files/modules to touch:

- `proto/core.proto`
- `packages/bot-api-types/src/index.ts`
- `packages/bot-api/src/`
- `server/src/controllers/bot/bot.ts`
- `server/src/db/schema/index.ts`
- `server/src/db/schema/botCommands.ts`
- `server/src/db/models/`
- `server/src/functions/_functions.ts`
- `server/src/functions/bot.getCommands.ts`
- `server/src/functions/bot.setCommands.ts`
- `server/src/functions/bot.getPeerCommands.ts`
- `server/src/realtime/handlers/_rpc.ts`
- `apple/InlineKit/Sources/InlineKit/RichTextHelpers/`
- `apple/InlineIOS/Features/Compose/`
- `apple/InlineMac/Views/Compose/`

## Production Readiness

This plan is production-sensible for the requested UX if we keep v1 to command metadata + peer lookup + compose insertion.

It is not a full Telegram-equivalent command platform yet because it intentionally defers:

- scoped/language command variants
- dedicated bot-command entities
- native command dispatch / invoke events
- realtime command metadata updates
- external bot inbound delivery improvements

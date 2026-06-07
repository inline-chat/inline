# Bot command rich text entity plan

Date: 2026-06-07

## Goal

Add a new rich-text entity for slash commands such as `/start`, `/deploy`, and `/deploy@buildbot`, matching Telegram's bot command model while fitting Inline's existing `MessageEntity` pipeline.

Recommended protocol/API name: `bot_command`.

Use `/cmds` only as product shorthand if needed. The stored rich-text entity should not be named `cmds`; Telegram, Bot API conventions, and our existing bot-command APIs all point to `bot_command`.

## Telegram reference

Telegram treats bot commands as first-class text entities:

- MTProto schema has `messageEntityBotCommand#6cef8ac7 offset:int length:int = MessageEntity`.
- TDLib schema exposes `textEntityTypeBotCommand`.
- Bot API exposes the entity type string `bot_command`, with examples like `/start@jobs_bot`.
- Bot command definitions use the same command-name constraints Inline already uses: 1-32 chars, lowercase English letters, digits, underscores.

Client behavior:

- Telegram iOS parses locally generated slash command entities in `TextFormat/Sources/GenerateTextEntities.swift`.
- A `/` starts a command only at the beginning of text or after a delimiter/whitespace.
- Command characters are `[A-Za-z0-9_]`; `@` may extend a command to include the target bot username.
- Telegram applies a `TelegramTextAttributes.BotCommand` attributed-string key and link color.
- Tapping the entity calls a bot-command send action, not a normal URL action.

The useful takeaway for Inline: model bot commands as an entity range over the visible command text, not as markdown syntax and not as a URL.

## Current Inline state

Protocol:

- `proto/core.proto` has `MessageEntity.Type` values through `TYPE_THREAD_TITLE = 12`.
- Entity payload oneofs exist only for mention, text_url, pre, thread, and thread_title.
- Bot command definitions already exist separately as `BotCommand`, `PeerBotCommands`, `GetPeerBotCommands`, etc.

Server:

- Message entity storage is already generic protobuf bytes in message rows, so adding an enum value does not need a DB migration.
- `processOutgoingText` is the best server-side normalization point. It already resolves inline links and auto-adds missing mention entities.
- `parseMarkdown` only handles markdown constructs and should not own slash-command parsing.
- Bot API conversion lives in `server/src/controllers/bot/entities.ts` and needs string mapping support for every externally visible entity type.
- Thread title generation excludes mentions, urls, emails, phone numbers, code, and pre from title source text. Bot commands should be excluded too.

Apple:

- `ProcessEntities.toAttributedString` renders protocol entities to attributed strings.
- `ProcessEntities.fromAttributedString` extracts attributed compose text back to protocol entities.
- `SlashCommandDetector` and `PeerBotCommandsViewModel` already support `/` command completion on iOS/macOS.
- iOS and macOS currently insert command suggestions as plain text, then send immediately.
- iOS/macOS message tap handling supports mention, thread link, email, phone, inline code, and URL, but not bot command.

## Design

### Protocol

Add:

```proto
TYPE_BOT_COMMAND = 13;
```

No oneof payload is needed. The command can be recovered from the entity text range. This matches Telegram's `messageEntityBotCommand`, which stores only offset and length.

Regenerate:

- `packages/protocol/src/core.ts`
- `apple/InlineKit/Sources/InlineProtocol/core.pb.swift`

Be careful: both generated files and `proto/core.proto` already have unrelated local changes in the current worktree. The implementation pass should preserve those changes and stage only the bot-command hunks.

### Slash command parsing

Create shared detection rules equivalent to Telegram and Inline's existing detector:

- Start only at text start or after whitespace.
- First char is `/`.
- Command name must be 1-32 chars.
- Command chars: ASCII letters, digits, underscore while parsing text, but stored bot command definitions stay lowercase-only.
- Optional suffix: `@` plus bot username-like identifier, using ASCII letters, digits, underscore.
- Stop at whitespace.
- Do not parse inside existing code/pre entities.
- Do not add if the range overlaps an existing client entity.

Examples:

- `/start` -> bot_command covering `/start`
- `hello /start` -> bot_command covering `/start`
- `/deploy@buildbot` -> bot_command covering full command with bot suffix
- `abc/start` -> no entity
- `/` -> no entity
- `/a-b` -> entity for `/a`, then stop at `-`
- `` `/start` `` -> code entity only, no bot_command

### Server

Add a server-side extractor in `server/src/modules/message/processOutgoingText.ts`, near mention extraction:

- `extractBotCommandCandidates(text)`
- `parseMissingBotCommandEntities({ text, entities })`
- Merge, sort by offset/length, and skip overlapping ranges through existing range helpers.

Run it after markdown processing and after inline link resolution, before returning:

```ts
entities = parseMissingBotCommandEntities({ text, entities })
```

This makes bot commands work for all producers, including Apple clients, bot API clients, SDK clients, CLI, and future web clients. It also avoids relying only on Apple attributed-string attributes.

Update:

- `server/src/controllers/bot/entities.ts`
  - parse input string `bot_command`
  - output `bot_command`
- `packages/bot-api-types/src/index.ts`
  - add `"bot_command"` to `BotMessageEntityType`
- `server/src/modules/threadTitles/index.ts`
  - add `MessageEntity_Type.BOT_COMMAND` to `excludedEntityTypes`

Optional but useful:

- Keep bot_command out of URL preview link detection; current detection already only checks URL/TEXT_URL.
- Notifications can keep formatting all entities generically.

### Apple rendering and extraction

Add an attributed-string key:

```swift
static let botCommand = NSAttributedString.Key("botCommand")
```

Update `ProcessEntities.toAttributedString`:

- For `.botCommand`, extract the visible command text from the entity range.
- Apply `foregroundColor: linkColor`, `.underlineStyle: 0`, and `.botCommand: commandText`.
- On macOS add pointing-hand cursor.

Update `ProcessEntities.fromAttributedString`:

- Enumerate `.botCommand` and emit `.botCommand` entities.
- Skip link extraction for ranges with `.botCommand`.
- Add server-equivalent plain text parsing at the end, after markdown/link/email/phone extraction, so manually typed `/start` is preserved even when the text was never attributed.
- Do not parse inside code/pre or overlapping entities.

Update `SlashCommandDetector.replaceSlashCommand`:

- When replacing with a selected suggestion, apply `.botCommand` to the inserted command range, excluding trailing space.
- Keep trailing space outside the entity.

This lets iOS/macOS command suggestions preserve entity data locally before send. Server parsing remains the fallback/source of truth for non-Apple clients and manually typed commands.

### Apple tap behavior

Add bot-command handling to message tap paths:

- iOS `UIMessageView.handleTextViewTap`: if `.botCommand` exists at the tapped index, send that command in the current chat context or post through the existing message interaction layer if there is one.
- macOS `MessageTextView.entityRanges`: include `.botCommand`.
- macOS `MessageView.handleTextEntityClick` and `MinimalMessageView.handleTextEntityClick`: detect `.botCommand` before `.link`.

Product decision needed before implementing tap:

- Should tapping `/cmd` immediately send it, like Telegram?
- Or should it prefill compose with `/cmd ` and focus, safer for a work chat?

Existing compose selection already sends immediately on macOS and iOS, so immediate send is consistent, but tapping historical messages may be surprising. I would implement tap-to-prefill first unless product explicitly wants Telegram parity.

### Bot command target resolution

Entity payload should stay payload-free. Use text and chat context to resolve the target when executing:

- `/command@botusername`: send to that bot.
- `/command` in a bot DM: send to the DM bot.
- `/command` in a room with one bot offering that command: send to that bot.
- `/command` in a room with multiple bots offering the same command: require the `@botusername` suffix or open a chooser.

The current `PeerBotCommandsViewModel` already computes `isAmbiguous` and inserts `@username` for ambiguous suggestions. Reuse that logic for tap/execute resolution.

## Implementation sequence

1. Protocol
   - Add `TYPE_BOT_COMMAND = 13`.
   - Regenerate TS and Swift protocol outputs.

2. Server entity support
   - Add extractor and merge/sort logic in `processOutgoingText`.
   - Add bot API parse/encode support.
   - Add bot API type support.
   - Exclude bot commands from thread title source text.

3. Apple rich text
   - Add `.botCommand` attributed key.
   - Render `.botCommand` in `ProcessEntities.toAttributedString`.
   - Extract `.botCommand` and plain slash-command ranges in `ProcessEntities.fromAttributedString`.
   - Mark command suggestion insertions as `.botCommand`.

4. Apple interaction
   - Include `.botCommand` in hit testing.
   - Wire iOS/macOS tap behavior based on the product decision.

5. Tests
   - Add server tests in `server/src/modules/message/processOutgoingText.test.ts` for plain commands, bot suffixes, overlap skipping, markdown/code shielding, emoji offset stability, and command after whitespace.
   - Add bot API entity conversion tests in `server/src/controllers/bot/entities.test.ts`.
   - Add thread title exclusion test in `server/src/modules/threadTitles/threadTitles.test.ts`.
   - Add Apple `ProcessEntitiesTests` for render/extract, typed command extraction, command suggestions preserving attributes, code shielding, and UTF-16 offsets.
   - Extend `SlashCommandDetectorTests` for `@bot` suffix and trailing-space attribute range if the replacement method owns attributes.

## Checks

Focused server checks:

```sh
cd server && bun test src/modules/message/processOutgoingText.test.ts src/controllers/bot/entities.test.ts src/modules/threadTitles/threadTitles.test.ts
cd server && bun run typecheck
cd server && bun run lint
```

Protocol/package checks after generation:

```sh
bun run generate:proto
cd packages/bot-api-types && bun run typecheck
cd packages/protocol && bun run typecheck
```

Apple checks:

```sh
cd apple/InlineUI && swift test --filter ProcessEntitiesTests
cd apple/InlineKit && swift test --filter SlashCommandDetectorTests
```

If generated protocol changes affect package builds, run the focused Swift package build/test for the touched packages.

## Risks

- Protocol regeneration can collide with unrelated local changes currently present in generated files.
- Auto-detecting commands server-side changes persisted entities for all clients, but not visible text.
- Immediate tap-to-send can surprise users in historical messages; prefill is safer unless product chooses Telegram parity.
- Bot command parsing should avoid code/pre ranges and existing entities to prevent changing markdown semantics.

## Recommendation

Implement `bot_command` as a payload-free `MessageEntity.Type`, parse it server-side for all senders, and add Apple attributed-string support for local fidelity and interaction. Defer tap-to-send until the product decision is explicit; shipping styled/persisted entities first is low-risk and gives downstream clients the data they need.

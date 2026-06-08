# Translation2 markdown API spec

## Goal

Replace the legacy server translation module with a new implementation that keeps the external translation API transparent, but changes the internal contract from "translate text, then ask AI to convert entity offsets" to "serialize text plus entities as markdown, translate markdown once, then parse markdown back to text plus entities deterministically."

The existing Realtime/API surface, DB shape, and clients should keep receiving `MessageTranslation { text, entities }`. The old `server/src/modules/translation` files should stay in place while the new module lives separately, e.g. `server/src/modules/translation2`.

## Current Problems

- The current module is slow and costly because it performs two AI calls: one for text translation and one for entity offset conversion.
- Entity conversion is brittle because the model has to reason about offsets, UTF-16 units, missing spans, and JSON shape.
- Offset conversion is buggy in practice. The model can return malformed JSON, bad offsets, duplicate message IDs, or entities that no longer match the translated text.
- Returning `null` translated entities is risky for clients that render `translationEntities ?? message.entities`; a translated text with `null` entities can accidentally reuse original-message entity offsets. Translation2 should return an explicit empty `MessageEntities { entities: [] }` when the translated text has no translated entities.

## Design

### API Shape

Keep `server/src/functions/translateMessages.ts` as the public entry point. It should call Translation2 internally once the new module is ready.

The returned translation remains:

```ts
type InputTranslation = {
  messageId: number
  language: string
  translation: string
  entities: MessageEntities | null
  msgRev?: bigint | number | null
}
```

Translation2 should prefer `entities: { entities: [] }` over `null` for newly generated translations. `null` remains valid for old rows and compatibility.

### One AI Call

For each batch:

1. Convert each source message from `text + entities` to markdown.
2. Send markdown to the translation model.
3. Ask the model to return translated markdown only, still keyed by `messageId`.
4. Parse translated markdown locally into `text + entities`.
5. Run deterministic literal detectors for entity types that do not need markdown wrappers.
6. Persist translated text and parsed entities.

The model must never return entity JSON or offsets.

### AI Contract

Use structured output only for batch framing:

```ts
{
  translations: Array<{
    messageId: number
    markdown: string
  }>
}
```

Rules for the model prompt:

- Translate the human-visible text.
- Preserve markdown syntax when it still applies in the translated sentence.
- Preserve links and Inline links as markdown links.
- Preserve inline code and code blocks exactly unless translating surrounding prose.
- If a formatting/entity span is no longer natural after translation, omit the markdown. Translation2 trusts the model output and drops the entity naturally during markdown parsing.
- Do not return JSON for entities, offsets, or explanatory text.

## Entity Markdown Module

Create a dedicated module under Translation2, for example:

```text
server/src/modules/translation2/entities/
  index.ts
  types.ts
  toMarkdown.ts
  fromMarkdown.ts
  registry.ts
  offsets.ts
  escape.ts
  literalDetectors.ts
  bold.ts
  italic.ts
  code.ts
  pre.ts
  textUrl.ts
  mention.ts
  thread.ts
  threadTitle.ts
  url.ts
  email.ts
  phoneNumber.ts
  botCommand.ts
```

Keep one file per entity or close family when that makes the representation/test ownership clear.

### Registry

Every `MessageEntity_Type` must have an explicit policy:

- `markdown`: represented by markdown syntax in `toMd` and parsed by `fromMd`.
- `literalDetected`: left as literal text in `toMd`, then recovered by deterministic detection after parsing.
- `unsupported`: intentionally dropped, with a test documenting the decision.

The registry should be exhaustive. A new protocol entity type must create a TypeScript compile failure or a failing unit test until a policy is added.

Current Inline entity policies:

| Entity type | Policy | Markdown representation |
| --- | --- | --- |
| `MENTION` | `markdown` | `[label](inline://user/<id>)` |
| `URL` | `literalDetected` | leave visible URL text unchanged; detect again |
| `TEXT_URL` | `markdown` | `[label](url)` |
| `EMAIL` | `literalDetected` | leave visible email unchanged; detect again |
| `BOLD` | `markdown` | `**text**` |
| `ITALIC` | `markdown` | `*text*` |
| `USERNAME_MENTION` | `literalDetected` | leave `@username` unchanged; detect again if supported by existing detectors |
| `CODE` | `markdown` | `` `text` `` |
| `PRE` | `markdown` | fenced code block, preserving language |
| `PHONE_NUMBER` | `literalDetected` | leave visible phone unchanged; detect again |
| `THREAD` | `markdown` | `[label](inline://thread?id=<chatId>)` |
| `THREAD_TITLE` | `markdown` | `[label](inline://thread?space_id=<spaceId>&title=<encoded title>)` |
| `BOT_COMMAND` | `literalDetected` | leave `/command` unchanged; detect again after parsing |

`TYPE_UNSPECIFIED` should be ignored/dropped.

### Offset Rules

- Treat protocol offsets as UTF-16 code units.
- Tests must include emoji/surrogate-pair cases.
- Avoid regex-only offset rewriting for serialized markdown. Build markdown by walking sorted entity start/end events over the source text.
- Parse markdown into plain text while maintaining UTF-16 offsets for produced entities.
- Sort output entities and reject/drop malformed or overlapping ranges deterministically.

### Parser Rules

Translation2 should not reuse the existing `server/src/modules/message/parseMarkdown.ts` as-is. That parser is useful prior art, but it was built for outgoing message parsing and is not a complete, strict, round-trippable transport format.

The Translation2 parser should:

- Be deterministic and local.
- Support nested formatting where valid.
- Protect code/pre contents from normal markdown parsing.
- Support escaped markdown characters.
- Parse Inline links into typed entities.
- Run literal detectors after markdown stripping.
- Drop entities whose markdown was not preserved by the model.
- Return plain text plus explicit empty entity arrays when no entities remain.

## Telegram Learnings

Telegram's API model is the same architectural pattern we want: canonical messages are plain text plus `MessageEntity` arrays; MarkdownV2/HTML are parse modes that produce entities, not the persisted representation.

Useful references:

- Official entity docs: https://core.telegram.org/api/entities
- Official `MessageEntity`: https://core.telegram.org/type/MessageEntity
- MarkdownV2 parser: `/Users/mo/dev/telegram/td/td/telegram/MessageEntity.cpp`
- MarkdownV2 tests: `/Users/mo/dev/telegram/td/test/message_entities.cpp`
- Telegram Web K lightweight parser: `/Users/mo/dev/telegram/Telegram-web-k/src/lib/richTextProcessor/parseMarkdown.ts`
- Telegram Desktop entity conversion: `/Users/mo/dev/telegram/tdesktop/Telegram/SourceFiles/api/api_text_entities.cpp`

Concrete takeaways:

- TDLib's `parse_markdown_v2` mutates markdown into plain text and returns entities. That is the right ownership boundary: parser owns text stripping and offsets.
- TDLib tracks UTF-16 offsets while scanning UTF-8. We should explicitly test this because Inline offsets cross server and Apple clients.
- TDLib uses a stack for nested entities. Translation2 should use a scanner/event model, not a chain of independent regex replacements.
- MarkdownV2 is strict about reserved characters and escaping. Translation2 should have an escaping module and parser tests for reserved markdown characters.
- Telegram detects literal entities such as mentions, bot commands, URLs, and emails outside markdown parsing. This supports our `literalDetected` policy for URL/email/phone/bot command where reliable.
- TDLib's `get_markdown_v3` is the best serializer inspiration: it inserts markdown delimiters from entity ranges and then parses the result back to verify the formatted text is preserved. Translation2 should add the same class of round-trip test for every `markdown` policy.
- Telegram Desktop does not make markdown canonical. It converts entity structs to/from API structs directly, which reinforces that Translation2 markdown should stay internal to the AI transport.

## Tests

Add focused tests beside the new module:

- Registry exhaustiveness over all current `MessageEntity_Type` enum values.
- `toMd` for each markdown-backed entity.
- `fromMd` for each markdown-backed entity.
- `text + entities -> markdown -> text + entities` round-trip for every supported markdown entity.
- Nested spans such as bold link, italic inside link, code inside bold where allowed, and overlapping invalid spans.
- UTF-16 offsets with emoji before, inside, and after entities.
- Escaping for literal `*`, `_`, `[`, `]`, `(`, `)`, backticks, and backslashes.
- Literal detectors for URL, email, phone number, username mention, and bot command.
- Drop behavior when AI returns plain translated text without original markdown.
- Batch translation output validation: missing, duplicate, or unexpected `messageId` fails the whole model response.
- Translation module integration test proving one model call translates and parses entities, with no entity-offset model call.
- Client-safety test or server assertion that new translations with no entities return `{ entities: [] }`, not `null`.

## Migration Plan

1. Build `translation2/entities` with tests first.
2. Build Translation2 batch translation using the existing OpenAI dependency pattern, but with the new markdown response schema.
3. Keep legacy `translation` module untouched.
4. Switch `server/src/functions/translateMessages.ts` to import/call Translation2.
5. Leave old persisted translation rows compatible.
6. Remove or deprecate legacy entity-conversion logs/paths later after production confidence.

## Production Risks

- Markdown escaping bugs can change visible text. Mitigate with round-trip tests and source text fixtures.
- Literal detection after translation can create entities that were not present before if the translated text naturally contains a URL/email/phone. This is acceptable only for the declared `literalDetected` types.
- AI can drop markdown around a span. That is intentional; Translation2 trusts the output and drops the entity instead of attempting fuzzy recovery.
- Inline entity links expose metadata to the model in markdown URLs. Keep them minimal and internal, and avoid adding user-sensitive fields beyond stable IDs already required to reconstruct entities.

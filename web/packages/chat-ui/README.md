# @inline/chat-ui

Message content rendering for the web app and, later, server-rendered public pages. The core is framework-free TypeScript; a thin React view lives in `@inline/chat-ui/react`.

## Invariants

- Never reads a store, never touches the network, never imports the core. Input is plain data (`text`, `entities`, rows from `@inline/core-protocol`); output is plain data or DOM.
- Pure and total: malformed input never throws. It degrades to plain text.
- Text renders as text nodes. No HTML strings, no `innerHTML`, no `dangerouslySetInnerHTML`.
- Every link passes through `safeLink`. A link it refuses renders as plain text.
- Offsets are UTF-16 code units, as in `Entity` and `proto/core.proto` (`MessageEntity`).
- Rendering matches the Mac app where the Mac app decides (`apple/InlineUI/Sources/TextProcessing/ProcessEntities.swift`, `apple/InlineKit/Sources/InlineKit/ProtocolHelpers/ProtocolBlockContent.swift`, `BlockContentDirection.swift`, `InlineDeepLink.swift`).

## Public API

From `@inline/chat-ui`:

| Export | What it does |
| --- | --- |
| `buildTextDocument(text, entities, options?)` | Text and entities to a `TextDocument` |
| `updateTextDocument(prev, text, entities, options?)` | Same, reusing every unchanged node of `prev`; returns `prev` for the same input. Use it for every message update |
| `reuseUnchanged(prev, next)`, `changedBlockKeys(prev, next)` | Structural sharing helper; which blocks changed identity |
| `safeLink(input, options?)`, `isSafeLink`, `isPhoneNumberCandidate` | The link allowlist |
| `previewText(text, { maxGraphemes, fallback })`, `documentPreview(doc)` | One-line preview for the sidebar and notifications |
| `copyText(doc, { linkTargets })`, `documentText(doc)` | Text for the clipboard |
| `truncateGraphemes`, `firstGrapheme`, `graphemeStartAtOrBefore`, `graphemeEndAtOrAfter` | Grapheme helpers (`Intl.Segmenter`) |
| `detectDirection(text)`, `dirAttribute(text)`, `tallyDirection`, `leafDirection` | Writing direction by word majority |
| `createTimeFormatter({ locale, timeZone, now, hour12 })` | `time`, `tooltip`, `dayLabel`, `dayNumber` |
| `userDisplayName`, `userShortName`, `userAvatarSeed`, `userInitials`, `avatarPaletteIndex` | Names, initials and avatar color for a user row |
| Types | `TextDocument`, `BlockNode`, `InlineNode`, `TextRun`, `Mark`, `SafeLink`, `AppLink`, `EntityInput`, ... |

From `@inline/chat-ui/react`: `MessageText` with props `document`, `classNames`, `inline`, `highlightRanges`, `onMention`, `onThreadRef`, `onBotCommand`, `onAppLink`, `onExternalLink`. With `inline`, it renders phrasing content only (for `summary`, `label`, table cells): a `span` root and `span` paragraphs, line breaks as `<br>`, one `<br data-kind="blockBreak">` between blocks, code blocks and display math as `code`, quotes as a `span` of paragraphs. The default output is unchanged (a test pins it byte for byte).

## The render model

```
TextDocument { text, dir, blocks }
  BlockNode
    paragraph   { dir, children: InlineNode[] }
    codeBlock   { language, text }            from `pre`; literal, entities inside ignored
    quote       { dir, children: paragraph[] } from `blockquote` owning whole lines
    mathBlock   { source }                     display math on its own line; inert
  InlineNode
    text        { text, marks }                marks: bold italic underline strikethrough highlight code
    link        { source, link: SafeLink, children: text[] }
    mention     { target: user | username | group, children: text[] }
    threadRef   { target: chat | title, children: text[] }
    botCommand  { command, botUserId?, children: text[] }
    math        { source }                     inline TeX; inert
```

Every node has `key`, `start` and `end` (UTF-16, end exclusive). Blocks have `blankLinesBefore`.

Lines and blocks: text between blocks splits into paragraphs at blank lines (whitespace-only lines count as blank). A single line break stays inside a run's text; render paragraphs with `white-space: pre-wrap`. Leading and trailing line breaks of each stretch are dropped, so a message streaming `"One.\n"` and `"One.\n\nTwo"` keeps the same first paragraph.

Entity rules (Mac parity unless noted):

- Dropped: unknown type, non-integer or negative offset, non-positive length, a range past the text, or an edge that splits a surrogate pair.
- Edges inside another grapheme cluster (combining mark, ZWJ sequence, flag, CR LF) widen to the cluster. (The Mac styles the partial cluster; in the DOM that detaches the mark, so the web widens.)
- Containers (link, mention, thread reference, bot command, inline math) never overlap or nest. Sorted by start, then longest, then input order; one that overlaps an accepted one is dropped and its text stays. Inline math goes first. Marks overlap freely, inside and outside containers.
- `textUrl` to `inline://user/<id>` is a mention and to `inline://chat/<id>` or `inline://thread?...` a thread reference. A URL entity whose text is a phone number is a phone link.
- A `blockquote` that does not own whole lines, is blank or touches a `pre` stays plain text. Overlapping quotes: earliest, then shortest.
- `pre` language must match `[A-Za-z0-9_+#.-]{1,32}` or is dropped.
- Math inside `code` or `pre` is code text.

Direction: the Mac rule. A text is right to left when it has more right-to-left words than left-to-right ones; a tie goes to the first strong letter; no letters means no direction (`dir="auto"`). A paragraph that leads by fewer than 3 words follows the whole message. A quote takes the majority of its paragraphs. Code blocks are always `ltr`.

## Streaming

Keys are the node kind plus its start offset (`p0`, `t12`, `l40`). Appending text never changes an earlier node's start, so earlier keys are stable. `updateTextDocument` also returns the previous object for every structurally equal node, so only the growing paragraph (and its last run) changes identity. The React view memoizes blocks and inline nodes by identity (the bail-out holds when the handler props are stable, which the React Compiler gives the app); React reuses the DOM for unchanged keys either way. Measured: a 63K-character message with 800 entities builds in about 3 ms in Node; a streaming update averages about 1 ms.

## Link safety (`links.ts`)

`safeLink` returns a normalized link or `undefined`:

- `web`: `http:` or `https:` with `//`, a non-empty host and no credentials (no `@` in the authority). Returns `URL.href`: scheme and host lowercased, IDN hosts in punycode.
- `mail`: `mailto:` with exactly one address; any query (subject, body, headers) dropped.
- `phone`: `tel:` with the Mac's phone rule (7 to 15 digits, one leading `+`, balanced parentheses); `href` keeps only `+` and digits.
- `app`: `inline://` or `in://` with host `user`, `chat`, `thread` or `join`; `https://inline.chat/{c,s,invite}/...`; any URL on `appOrigins` (default `https://app.inline.chat`). Returned as parsed parts (`form`, `host`, `path`, `query`, `href`). The app maps them to a destination with `@inline/view`'s `parseLink(link.href)`; this package does not import the view.
- Bare domains (`example.com/x`) get `https://` only with `bareDomain: true`, which the render model passes for `url` and `textUrl` entities.

Refused: every other scheme (`javascript:`, `data:`, `vbscript:`, `file:`, `blob:`, `about:`, `ftp:`, ...), in any case; scheme-relative (`//host`) and path-relative links; `https:host` and `https:/host`; and any input containing C0 or C1 controls, DEL, interior whitespace of any kind, soft hyphen, zero-width or bidirectional formatting characters, variation selectors, the BOM, or a backslash. These are refused rather than stripped because the URL parser strips or rewrites them silently (`java\tscript:`). Only leading and trailing ASCII spaces are trimmed.

The view renders web links with `target="_blank" rel="noopener noreferrer"`, mail and phone links with `rel` only, and app links with `rel` and an `onAppLink` handler that prevents navigation. `onExternalLink` runs before the browser follows a link (Electron calls `preventDefault` and opens the system browser).

## Find highlights (`text/highlight.ts`)

`MessageText`'s `highlightRanges` (and `highlightTextDocument(doc, ranges)`, `applyHighlights`, `BlockTreeOptions.highlightRanges`) mark find-in-chat matches. Ranges are UTF-16 `[start, end)` into the message's original text, as `{ start, end }` or `[start, end]`.

- Normalized like entities: dropped unless two safe integers with `0 <= start < end <= text.length` and no edge splitting a surrogate pair; edges inside a grapheme cluster widen to it; overlaps merge; at most 1000.
- Applied to the built document's leaves: text runs, at the top level and inside links, mentions, thread references and bot commands, split at range edges together with entity runs. The pieces inside a range get the `find` mark, which renders outermost as `<mark data-kind="find">` (class key `find`), distinct from the `highlight` entity (`<mark data-mark="highlight">`). Ranges may cross entity edges, line breaks and paragraphs.
- **Code blocks are highlighted** (`CodeBlockNode.find`, offsets into the code text, rendered as `<mark data-kind="find">` inside `<code>`): a match in code is still a match. Inline and display math stay inert and are not highlighted.
- Identity: nodes no range touches are the document's own objects; the same document and ranges give the same result object; when only the ranges change, touched paragraphs that come out equal keep last time's objects. `MessageText` keeps its context stable while its handlers are, so only paragraphs whose highlights changed re-render.
- Blocks: `buildBlockTree` applies the ranges (absolute, normalized on the whole text) to every block whose text comes from a range, and to code blocks (`CodeBlock.find`); not to math, diff lines or monospace values. `updateBlockTree` compares ranges as part of its options.
- Without ranges (or with only malformed ones) the output is unchanged.

## Previews and copy

`previewText` collapses all whitespace to single spaces, removes control and bidi embedding/override/isolate characters (joiners and LRM/RLM stay), and cuts to `maxGraphemes` (default 160, ellipsis included) on a grapheme boundary. Mentions and link labels are already the visible text. It looks at a bounded head of very long texts.

`copyText` is the visible text, blocks separated by their original line breaks, which is the message text for messages without whitespace-only lines (the Mac copies the text). `linkTargets: true` appends ` (url)` after links whose label is not their URL.

## Time and names

`createTimeFormatter` binds a locale, time zone and clock (milliseconds). `time` is the locale's hour and minutes (Mac `jmm`), `tooltip` medium date and short time, `dayLabel` "Today", "Yesterday" or the abbreviated date with year ("Nov 17, 2026"), as the Mac's date separator. Days are computed in the given time zone. Invalid locales or zones fall back to the runtime default.

`userDisplayName` is "First Last", else the username, else "User". `userInitials` is one uppercased grapheme of the avatar seed (first and last name, "User" for a missing first name, else the username without `@`), undefined when the user has neither (show a person symbol). `avatarPaletteIndex` is the Apple clients' sum of UTF-8 bytes modulo 12.

## Adding a content type

1. Add the node type in `src/text/types.ts`: a new member of `BlockNode` (media, a rich block, a link preview) or `InlineNode`. Give it `kind`, `key` (kind prefix plus start offset or a stable ID), `start`, `end`, and for blocks `blankLinesBefore`.
2. Produce it in a builder. Entity-backed nodes go in `src/text/build.ts` (`containerSpec` for inline containers, the section pass for blocks). Content that is not text (media, blocks, reactions, widgets) gets its own builder, for example `buildMessageContent(message)`, that returns blocks and concatenates them with `buildTextDocument`'s blocks; keys must stay unique and stable across updates.
3. Render it in `src/react/MessageText.tsx` (`Block` or `Inline`). Views already render an unknown kind as nothing, so older views degrade safely; "unknown block kinds fall back to the message text" is the builder's job (emit the text paragraphs).
4. Add it to `documentText` and `previewText` callers if it has a text form.
5. Tests: the model in `src/text/*.test.ts`, a render test in `src/react/MessageText.test.tsx`, and a streaming identity test when it updates often.

Media, rich blocks, attachments and service rows have their own models (below), built beside the text document rather than as new `BlockNode` kinds, so the text model is unchanged. Widgets render only in a sandboxed frame owned by the app, never through this view.

## Message content beyond text

Framework-free, pure and total like the text model. Input is a `MessageRow` (or the fields named), output is plain data. Every URL passes through `safeLink`; there are no HTML strings; widgets are data only.

### Media (`src/media/`)

| Export | What it does |
| --- | --- |
| `mediaModel(row, { availableWidth, style, locale })` | `photo`, `video`, `gif`, `document`, `voice` or `nudge` model: box, blurred preview JPEG, sticker and no-bubble flags, duration badge, document and voice rows |
| `fitMedia(w, h, options)`, `singleMediaBox(media, options)` | The Mac's `calculatePhotoSize`: aspect-fit into a square `min(320, available)` box, 40 minimum, no upscale unless captioned in bubble style; stickers 120; minimal style 350 x 300 |
| `richImageBox(dims, available)`, `albumLayout(dims[])`, `groupedMediaLayout(rows)` | Rich image (at most 420 x 420, unknown 240 x 180) and the album strip (height 126, items 96 to 220 wide, ratio 0.2 to 5, 4/3 default, 6 apart, 1 to 10 items). Grouped media messages reuse the strip: the Mac has no grouped-message mosaic |
| `bestPhotoSize(photo)`, `photoVariantFor(photo, box, pixelRatio)` | The Mac's best size; the smallest size that covers the box at the pixel ratio, else the best |
| `strippedJpeg(bytes)`, `strippedSize(bytes)` | The `s` size to a JPEG (the Mac's header, height at byte 145, width at 147, `FF D9`); cached per input object |
| `formatFileSize(bytes, locale)`, `formatDuration(s)`, `fileIcon(mime, name)`, `waveformBars(samples)`, `documentRowModel`, `voiceRowModel` | `ByteCountFormatter` `.file` style (decimal; KB 0, MB 1, GB 2 decimals), `m:ss` / `h:mm:ss`, icon category, 48 bars in [0.12, 1] |

### Rich blocks (`src/blocks/`)

`buildBlockTree(row, options)` turns `row.blocks` and `row.text` into a `BlockTree`, or `undefined` when the message should render as its flat text document: no blocks, nesting deeper than 16, more than 1024 blocks or more than 256 table cells (the Mac's limits). `updateBlockTree(prev, row, options)` is the streaming entry point: it returns `prev` for the same row content and structurally equal options (`sameBlockTreeOptions`), and otherwise rebuilds and returns the previous object for every unchanged node (byte arrays compare by content), so an append, or a disclosure toggled through `options.openDisclosures`, touches one block. A disclosure node carries `open` (the toggle, else `initiallyOpen`).

- Every node has `key` (`kind@path`, such as `paragraph@0` or `paragraph@3.1.0`), `start` and `end` (the UTF-16 span it covers). Keys depend only on kind and position, so appending keeps earlier keys.
- Text ranges render through `buildTextDocument` on the range with the message's entities clipped to it (`RichText { start, document }`), so links, mentions and styles work inside blocks. Code, math, diff text and monospace field values are literal.
- A block that cannot be drawn becomes `fallback` with the trimmed text it covers. An unknown kind covers the gap between its nearest siblings that cover text (within its container, after the container's header); a run of unknown kinds shows that text once.
- Kinds: `paragraph`, `heading` (level clamped to 1 to 6), `footer`, `math` (inert), `code`, `separator`, `list` (bullets, numbers from `start`, task boxes; 1 to 1024 items; ordinal up to 999,999,999), `image`, `album`, `disclosure` (closed by default; shimmer for progress or running; a badge only for waiting, failed, cancelled; a timer from `startedAt` or the message date, `formatElapsed`), `quote`, `table` (header row, alignment per column, equal row lengths), `diff` (at most 400 lines, "N more lines" or "Diff shortened by the agent"), `fields`, `steps` (a card at top level), `callout` (info by default), `meter` (fraction clamped), `form`, `widget`, `planProposal`, `approval`, `review`, `taskSuggestion`, `nextStep`, `promptSuggestions`, `fallback`.
- Agent cards: chips and notes in the Mac's words ("Awaiting approval", "Kept planning", "Replaced by a newer request", "Waiting on you", "1 finding", "Looks good"); buttons come from `row.actions` by `actionIds` and show only while pending; `BlockTree.claimedActionIds` lists the IDs drawn by cards that rendered and are not inside a closed disclosure (`options.openDisclosures` overrides by key). Pass them to `buttonRowsModel`. A task suggestion past `expiresAt` reads as expired when `options.now` is given.
- Widgets: `frame: { kind: "sandboxedFrame", origin: "separate", network: "none" }`, height from the hint (240 default) clamped to 80 to 2000, inline cap 720; only the first widget in a message, later ones fall back. Nothing here loads them.
- Forms (`form.ts`): `initialFormSession`, `setFormAnswer`, `beginSubmit` (the one-submit rule: only from editing on an open form; "Answer “Label” first" for a required empty field; empty answers omitted, toggles always sent), `submitSucceeded` (locks, drops secret answers), `submitFailed`, `formButtonLabel` ("Answered", "Sent"). Secret fields never have a default; a session lives in memory only.

### Attachments and buttons (`src/attachments/`)

| Export | What it does |
| --- | --- |
| `attachmentModels(row, { style })` | URL previews and external tasks in order; unknown kinds left out |
| `urlPreviewModel(preview)`, `prefersLargeMedia`, `largePreviewMediaHeight` | The Mac's large-or-compact rule, title and source fallbacks, " • " subtitle, 110 / 420 character description caps, 260 (bubble) or 350 (minimal) wide, X style, author row for YouTube and X. `link` is set only for a safe web link; external streams too; embeds are never framed |
| `externalTaskModel(task)`, `externalTaskHeadline(model, name)` | "Ada created a Linear issue", "Ada will do", "Unassigned"; "Untitled" |
| `buttonRowsModel(actions, claimed)`, `buttonsById(actions, ids)`, `buttonModel`, `grantReason(requirement, names)` | Button behaviors (`callback`, `copy`, `openUrl` with a `SafeLink`, `openLink`, `compose` trimmed to 1 to 4000 characters, `unavailable` with "This action isn’t available"), confirm dialogs, the Mac's grant wording |

`openUrl` buttons are stricter than the Mac: a scheme `safeLink` refuses (including other apps' schemes such as `codex://`, which the Mac opens after a confirmation) makes the button unavailable.

### Service rows and headers (`src/service/`)

| Export | What it does |
| --- | --- |
| `serviceRowModel(row, { sender })` | Segments with tones and links: "Ada linked from [[Title]]", "You linked to this thread", "Someone pinned a message", "Transcript · ..." (left-aligned), transcript status rows with thread links, an unknown event's text. Undefined for a transcript turn by its sender (an ordinary message) |
| `serviceFallbackText(row)`, `isTranscriptSpeech(row)` | Preview text without names ("Linked from X", "Pinned a message") |
| `forwardHeaderModel(forward, { title, me })` | "Forwarded from: Title" or "Forwarded from a private chat", and the click target |
| `viaModel(via, { botName, sender })`, `sameVia(a, b)` | "Sent via Claude Code", the tooltip, the badge; the grouping test |
| `repliesSummaryModel(replies, locale)` | "3 replies", "Subthread · 1 message", up to 3 avatars, unread; hidden for an empty reply thread or an untitled subthread |

Names come from the caller, so these models stay free of app state.

## Tests

`bun run test` (Vitest; view tests use happy-dom), `bun run typecheck`, and from `web/`: `bunx oxlint --ignore-path ../.oxlintignore packages/chat-ui`.

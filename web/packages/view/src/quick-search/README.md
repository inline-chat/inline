# Quick Search

The engine and model behind Quick Search (Cmd/Ctrl+K): one input that finds chats, people, spaces, commands and messages. Framework-free TypeScript, no DOM; everything runs in Node tests. A view is a thin list over `QuickSearchModel`.

The reference is the Mac app: `apple/InlineMac/Features/CommandBar/QuickSearchPopover.swift` (`QuickSearchViewModel`), `QuickSearchUsageStore.swift`, and `apple/InlineKit/Sources/InlineSearch/` (`InlineSearchMatcher`, `InlineSearchUsageHistory`, `InlineSearchChatCatalog`). The behavior is ported; the code is not.

Product rule: local results first and in the same task as the keystroke. Message search and the server add sections below; they never replace or reorder what is shown.

## Files

| File | What |
| --- | --- |
| `match.ts` | The matcher: normalization, tiers, scores, highlight ranges |
| `sources.ts` | Candidate types, the local source over rows, message and remote source interfaces |
| `usage.ts` | Usage store (frecency, per-query affinity) and the ranking comparators |
| `model.ts` | `QuickSearchModel` |
| `testing.ts` | Scripted and fake async sources, a signal-backed local source |

Import from `@inline/view/quick-search` (fakes: `src/quick-search/testing.ts`).

## Matcher (`match.ts`)

- `prepareQuery(text)` and `prepareField(text, priority)` normalize once; `matchField`, `matchFields(query, fields)` and `matchText(query, text)` match. `compareMatches(a, b)` is the Mac order: tier, then field priority, then earlier position, then shorter field. `Match.score` orders the same way as one number.
- Tiers, best first: `exact`, `fieldPrefix`, `tokenPrefix` (every query word starts a field word), `acronym` (new: "pm" finds "Product Meeting"), `substring` (mid-word), `compact` (ignoring spaces), `fuzzy` (letters in order; three letters at least, field at most 24 longer than the query, as on the Mac).
- Normalization: lowercase, NFKD with combining marks dropped, Persian and Arabic variants folded (kaf, yeh, alef maksura, teh marbuta, heh with yeh, alef wasla, tatweel; Arabic-Indic and Persian digits to ASCII), zero-width joiners and non-joiners, bidi controls and emoji skin tones dropped, every run of non-word characters one space. Letters, digits and pictographs are word characters, so emoji titles can be found.
- `Match.ranges` are UTF-16 offsets into the original text, merged and sorted. A combining mark or ZWNJ inside a word is inside its highlight.
- Never throws on any input (fuzzed with lone surrogates, controls and non-strings). 10,000 two-field candidates prepare in about 35 ms and match in about 5 ms per query in Bun on a laptop; the test bound is 1.5 s and 150 ms.

## Sources (`sources.ts`)

- `QuickSearchLocalSource`: signals of `ChatCandidate` (sidebar order, archived included), `UserCandidate` (people without a direct chat) and `SpaceCandidate`. Candidates carry prepared fields. `createRowLocalSource(signal<QuickSearchRows>)` builds them from `DialogRow`, `ChatRow`, `UserRow` and `SpaceRow`, reusing a candidate while its rows keep their identity. Titles follow the Mac sidebar rule (the same rule as `features/helpers.ts`).
- Field priorities are the Mac's (`fieldPriority`): chat title 400, peer username 500, email 200, space name 100; known person name 500, username 600; server person name 500, full name 450, `@username` 600, username 550, email 300; space 500; command title 640, keywords 420.
- Item and usage keys: a direct chat and its person share `user:<id>`; other chats are `chat:<id>`.
- `QuickSearchMessageSource.search(request, signal)` and `QuickSearchRemoteSource.search(request, signal)` are asynchronous and take an `AbortSignal`. `isMessageSearchable` is the Mac's two-letter rule; `messageSnippet` ports its snippet (radius 70).

## Usage and ranking (`usage.ts`)

`new UsageStore({ persistence, now, clock })`, one per account (key the persistence by account; `storageUsagePersistence(localStorage, key)`).

- `recordSwitch(key)`: the app calls it whenever the visible chat changes (Mac `Nav2`/`Nav3`). Frecency is `log2(count + 1)` halved every 45 days; it ranks the empty-query suggestions.
- `recordSelection(key, query)`: the model calls it on activation. Recorded under the normalized query and each compact prefix of 2 to 8 letters, halved every 30 days. An empty query records nothing.
- Records older than 180 days go; at most 500 items, 256 query keys, 12 items per key. Saves 350 ms after the last change. Query keys are hashed (cyrb53), so the snapshot holds no search text verbatim; that is not a privacy guarantee.
- `compareRanked`: tier, query affinity, frecency, field priority, current space, pinned and unread, last activity, sidebar order (`searchResultPrecedes`). `rankScore`: tier × 100,000 + affinity × 1,000 (≤ 90,000) + frecency × 100 (≤ 9,000) + field priority, used to mix chats with people who have no chat. Usage never lifts a result over a better tier.

## Model (`model.ts`)

```ts
const model = new QuickSearchModel({ clock, now, local, commands: registry, messages, remote, usage, context })
model.open(); model.setQuery("de"); model.next(); const outcome = model.activate(undefined, "here")
```

Signals: `isOpen`, `text` (the field), `query` (trimmed), `sections`, `items` (flat, unique IDs), `activeId`, `activeItem`, `messagesState` and `globalState` (`idle | pending | done | error`), `isLoading`, `emptyState` (`results | loading | error | noResults | blank`).

Methods: `open()`, `close()`, `setQuery(text)`, `setActive(id)`, `next()`, `previous()`, `first()`, `last()`, `nextSection()`, `previousSection()`, `activate(item?, intent?)`, `dispose()`.

| Constant | Value | Mac source |
| --- | --- | --- |
| `quickSearchTiming.messageDebounceMs` | 120 ms | `searchMessages`: `Task.sleep(.milliseconds(120))` |
| `quickSearchTiming.remoteDelayMs` | 250 ms | `searchGlobalUsers`: `Task.sleep(.milliseconds(250))`; `InlineSearchLimits.globalDebounceNanoseconds` |
| `quickSearchLimits` | suggestions 5, chats 5 (empty query) or 20, spaces 10, messages 20, global 20 | `runLocalProjection`, `projectSpaces`, `messageSearchOptions`, `rankGlobalUsers` |

Behavior:

- **Sections**, in the Mac order: Suggestions (empty query: top 5 by frecency), Chats (empty query: the sidebar's first 5 not suggested; otherwise chats and known people mixed by `rankScore`, 20), Spaces (query only), Commands (every enabled palette command for an empty query; matches otherwise; never `app.quickSearch`), Messages, Global Search (server people not already shown, then server message hits).
- **Timing**: local sections are computed from the query signal, so they are readable when `setQuery` returns. Message search starts 120 ms after the last change when the query has two letters; the server is asked at 250 ms when the compact query has two. Both show `pending` from the keystroke. A new query aborts in-flight requests and clears timers; a result for an older query is dropped even if its source ignored the abort. A whitespace-only edit does not restart anything.
- **Stability**: async sections append below everything shown, in arrival order, and each has its own computed, so shown items keep their objects. The active item is the one the user moved to while it is in the list, otherwise the first; a new query resets it to the first.
- **Create row**: `Create "<query>"` in Commands when the query is not empty, a space is selected (`context.spaceId`), both async searches finished without error, and nothing matched anywhere (`createThreadResult`). ID `create:<spaceId>:<lowercased query>`.
- **Activate** returns an outcome, records usage for chats, people and messages, and closes the model. Outcomes: `open` (a `chat` or `message` destination with the open intent), `openUser` (open or create the direct chat), `openSpace`, `runCommand`, `createThread`, `none` (no item, or one not in the current list).

## What a view does

- Calls `open()` on Cmd/Ctrl+K and focuses the field; binds the field to `text` and calls `setQuery` on input.
- Renders `sections` with each section `title`, items by `id`, highlights `titleRanges` (and `snippetRanges` for messages), marks `activeId`, and scrolls the active row into view only when the keyboard moved it.
- Keys: Down/Up `next`/`previous`, Home/End or Mod+Up/Down `first`/`last`, Tab/Shift+Tab `nextSection`/`previousSection`, Enter `activate(undefined, "here")`, Mod+Enter `activate(undefined, "otherPane")`, Escape `close()`. Pointer hover calls `setActive(id)`; click calls `activate(item)`.
- Performs the outcome after restoring focus: `workspace.open(destination, { intent })`, `registry.run(commandId, { source: "palette" })`, select a space, open or create a direct chat, start a new thread with the title.
- Shows a row for `emptyState` when there are no items: a loading row, "Failed to load", or "No results found" (Mac wording).
- Calls `usage.recordSwitch(key)` when the visible chat changes, and `usage.clear()` on sign-out.

## What the core must provide for message search

A query `searchMessages(request): Promise<MessageHit[]>` behind the link, served from an FTS5 index:

- Request (`MessageSearchRequest`): `query` (trimmed), `spaceId?`, `limit` (20), `includeArchived` (true), `sort` (`"newest"` for Quick Search; `"relevance"` for later). Every query word matches as a prefix (GRDB's `FTS5Pattern(matchingAllPrefixesIn:)`), case and diacritic insensitive; queries with fewer than two letters return nothing.
- Each hit (`MessageHit`): `chatId`, `messageId`, `chatTitle` (sidebar title), `peerUserId` for a direct chat, `spaceId`, `fromId`, `date` (seconds), `snippet` and `snippetRanges` (as `messageSnippet`).
- Cancellation: honor the abort signal, so a superseded query does not hold the worker.
- The index must be maintained without blocking reads and rebuilt after a bucket repair (package 3C).

## Invariants

- No DOM or framework import; time and storage are injected.
- The matcher never throws; ranges are within the original text.
- Local results for a query are readable in the same task as `setQuery`.
- Nothing shown moves when an async section arrives; IDs in `items` are unique.
- A result for an older query never appears.
- `close()` leaves no timers and no requests in flight.

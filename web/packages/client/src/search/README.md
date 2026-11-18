# search

Local message search: an FTS5 index inside the account replica, kept in step with message rows, and the queries Quick Search and find in chat need. Product rule: local results first, from the device, with no network round trip; remote search only adds to them.

The reference is the Mac client: `apple/InlineKit/Sources/InlineKit/Search/LocalMessageSearch.swift` and `InChatMessageSearch.swift`, the `messageTextFts` table in `Database.swift`, and `InlineSearch/InChatSearchViewModel.swift`.

## Files

| File | What |
| --- | --- |
| `normalize.ts` | Folding and tokenization, shared by the index and the query |
| `query.ts` | The query language: what a user types, compiled to an FTS5 expression that cannot fail |
| `highlight.ts` | Matched ranges (UTF-16 offsets into the original text) and the snippet |
| `index-writer.ts` | Writes index entries inside the store's transaction; the backfill batch |
| `engine.ts` | `MessageSearch`: search, find in chat, count, backfill, status |
| `__tests__/` | Real SQLite, real store and `Db`; `timing.test.ts` is the opt-in 300,000-message measurement |

## Schema (replica version 5, migration `message_search_index`)

- `message_search_doc(id INTEGER PRIMARY KEY, chat_id, message_id, hash)` with `UNIQUE INDEX message_search_doc_message_idx(chat_id, message_id)`: one row per indexed message. `id` is the FTS rowid; `hash` (cyrb53 of date and folded text) lets a message written again with the same text skip the index.
- `message_search`: FTS5, columns `body` (folded text) and `chat` (`c<chatId>`, so find in chat filters inside the index), `content=''`, `contentless_delete=1`, tokenizer `unicode61 remove_diacritics 0 categories 'L* N* M* P* S* C*'`, `prefix='2 3'`.
- Trigger `message_search_doc_ad` (after delete on `message_search_doc`): delete the FTS row.
- Trigger `message_search_message_ad` (after delete on `message`): delete the document, so whatever removes a message row removes its entry.
- `inline_replica_metadata` key `message_search`: `{ version, state: "building" | "ready", after?: [chatId, messageId] }`, the backfill's progress. The migration writes `ready` when there are no messages, else `building`.

## Design choices

**Who writes the index.** The message payload is a msgpack blob and the table is `WITHOUT ROWID`, so SQL cannot read the text and an external-content FTS table is impossible. The store therefore writes entries itself: `SQLitePersistenceStore.writeTransaction` calls `MessageSearchIndexWriter.put` after every message `put`, inside the same transaction (invariants 1 and 6: a message and its entry commit or roll back together; tested by crashing at every checkpoint). Deletes go through triggers instead, so `deleteMessagesByChat` (clear history, access-loss purges), `deleteMessagesInRange` (certified history pages), single deletes and any future eviction in raw SQL all remove entries without code of their own.

**What is indexed.** The text (`message.message`) of messages with a server ID, as on the Mac (it indexes `text` only). Temporary IDs (zero or negative: optimistic sends) are never indexed, so a rejected or cancelled send cannot leave a ghost; the send enters the index in the same write that gives it its server ID (`updateMessageId` deletes the temporary row and inserts the real one). Text past 32,768 UTF-16 units is not indexed.

**Tokenization in TypeScript.** `normalize.ts` folds exactly as the Quick Search matcher (`view/src/quick-search/match.ts`): lowercase, NFKD without combining marks, Persian and Arabic variants (kaf, yeh, alef maksura, teh marbuta, heh, alef wasla), tatweel, ZWJ, ZWNJ, bidi controls and skin tones dropped, Arabic-Indic and Persian digits to ASCII, other non-word characters separate words. It then makes each character of a script written without spaces (Han, Kana, Hangul syllables, Thai, Lao, Khmer, Myanmar, Bopomofo) and each pictograph a token of its own, and keeps Hangul syllables whole. The FTS5 tokenizer is configured so every character except a space is a token character: the index splits exactly where TypeScript put spaces, and the query uses the same function. That gives parity between indexing, matching and highlighting, and lets ranges be computed in TypeScript (`snippet()`/`highlight()` cannot map back through the folding). Bump `SEARCH_NORMALIZER_VERSION` when folding changes: the backfill re-indexes everything, rewriting only entries whose hash changed.

**CJK.** Unigrams with phrase queries: a query `東京タワー` becomes the phrase `"東 京 タ ワ ー"`, so any substring is found. Measured against `trigram` over the same folded text: trigram is 72 MB per 100,000 messages against 28 MB for the chosen index, and cannot match queries shorter than three characters.

**Rowids order the index.** Rowid = `date * 1024 + (messageId mod 1024)`, next free slot on a collision. FTS5 walks rowids in order, so newest-first with a limit stops after one page instead of sorting all matches. That is the Mac's Quick Search order (date, then message ID; within one second IDs compare modulo 1024). Doclists store rowid deltas as varints, so the multiplier is small: `date * 2^31` made the FTS tables 27% larger (42 against 33 MB per 100,000).

**Prefix indexes `2 3`.** Every unquoted word is a prefix (as the Mac's `FTS5Pattern(matchingAllPrefixesIn:)`). Two- and three-letter prefixes read a prefix index; longer ones merge their terms' doclists. A one-letter word matches only itself (a one-letter prefix would read a large share of the index). Sizes, FTS tables only, per 100,000 seeded messages: no prefix index 12.4 MB, `2 3` 27.9 MB, `2 3 4` (Mac) 35.0 MB, `1 2 3` 38.3 MB.

**Reads.** `readSearchIndex` runs on committed state (it waits only while a transaction is open on the connection, never for queued writes). Hits then go through `Db.readThroughAdmission` (invariant 13): a message deleted or edited in memory after the read wins, and its ranges are recomputed on the text the UI shows; a hit that no longer matches is dropped. Writes accepted but not committed when the query runs are not yet findable (milliseconds).

**Work cap.** The scan steps one index match at a time and filters (space, archived) in JavaScript, so the budget (`maxScannedRows`, default 20,000; `maxQueryMs`, default 60 ms) is checked between bounded steps. A capped page says `truncated` and its `nextCursor` continues after the last examined row. Relevance ranks only the newest `RELEVANCE_WINDOW` (1,000) matches with bm25. Count stops at `COUNT_CAP` (10,000). The SQLite progress handler would cap single steps too, but the store's `Database` does not expose the `capi` of the WASM instance that owns it.

**Backfill.** Batches of 250 messages in primary-key order, each its own transaction through the store's ordered write queue (`writeSearchIndex`), with the progress cursor written in the same transaction; resumable after a restart, no batch repeated. Between batches it yields (`pause`, a macrotask by default) so reads, sync writes and paint run. Reads never wait for it: Db reads do not use the write queue, and a search waits at most for one batch's transaction. A batch that fails is retried twice, then the status is `failed`. Searching during the backfill returns what is indexed and `indexComplete: false`.

## Measurements

Node 24 via Vitest, Apple M-series laptop, in-memory SQLite, `writeSeedAccountToStore` with seed 7, 3,000 chats, 300,000 messages (the seed's vocabulary is small, so common words match a large share of all messages: pessimistic). `INLINE_SEARCH_TIMING=1 bunx vitest run src/search/__tests__/timing.test.ts`. Medians of 15 runs, complete pages (hits decoded, ranges and snippet computed):

| Query | Median |
| --- | --- |
| `deploy` (common word, prefix of 6 letters) | 6.9 ms |
| `rev` / `re` (prefix index) | 1.2 / 0.9 ms |
| `deploy t` | 5.8 ms |
| `release notes` (two common prefixes) | 12.6 ms |
| `"review the"` (phrase) | 1.9 ms |
| `确认` / `مرحبا` / `cafe` | 0.7 / 2.5 / 6.1 ms |
| `deploy` in one space | 6.7 ms |
| `deploy`, relevance | 19.4 ms |
| Find in chat, biggest chat (24,873 messages), `the`, 100 hits | 6.9 ms |
| Count in that chat / everywhere (capped) | 2.3 / 5.4 ms |

Words longer than three letters cost most: FTS5 merges the doclists of every term with that prefix (`deploy*` takes 5.5 ms of SQL; the exact word `"deploy"` 0.07 ms).

Size: the index adds 43 MB per 100,000 seeded messages (FTS data 34, document table and its unique index 4.7, FTS docsize 1.9). The seeded messages themselves take 117 MB per 100,000. `optimize` after the seed saved only 2 MB, so incremental writes do not fragment it much. Writing 300,000 messages through the store with live indexing took 14.5 s; the backfill of the same replica took 12.7 s in 1,201 batches of 250, median 9.2 ms per batch (max 46 ms, a garbage collection).

## What is findable

- Words by prefix, case and accent insensitive: `cafe` finds "Café", `RESUME` finds "résumé".
- Persian and Arabic across keyboard variants and diacritics: `کتاب یک` finds "كتاب يك"; `مرحبا` finds "مَرْحَبًا"; a word with a ZWNJ is found with or without it (`میخواهم`, `می‌خواهم`); Persian and Arabic-Indic digits by ASCII digits.
- Any substring of Chinese, Japanese and Korean text; quoted phrases; emoji next to words (`ship 🚀`, `👍` finds "👍🏽").
- Mixed-direction text: each word matches regardless of direction.

Not findable: a word from its middle in spaced scripts (`ploy` does not find "deploy"); `strasse` for "Straße" (ß does not fold); a Persian word written with a space where the message has a ZWNJ or no space (`می خواهم` against "می‌خواهم"); queries with fewer than two letters or digits (the Mac rule, so an emoji alone is not searchable); file names, link titles and other non-text content; text past 32,768 units; messages not on the device.

## API (`search/index.ts`)

```ts
const search = createMessageSearch(db) // undefined unless db's store is the SQLite replica
search.start()                         // background backfill; idempotent
search.status()                        // idle | building {indexed, total} | ready | failed {message} | stopped
search.subscribe(listener)
await search.search({ query, chatId?, spaceId?, includeArchived = true, sort = "newest" | "relevance", limit = 20 (≤ 100), cursor? }, signal?)
  // → { hits, nextCursor?, indexComplete, truncated }
await search.findInChat({ chatId, query, cursor?, direction = "older" | "newer", limit = 100 }, signal?)
  // → { hits (newest first), hasOlder, hasNewer, olderCursor?, newerCursor?, indexComplete, truncated }
await search.count({ query, chatId? }, signal?)
  // → { count, capped, indexComplete }
await search.stop()                    // before closing the store
```

A hit: `chatId`, `messageId`, `fromId`, `date` (seconds), `out`, `text`, `ranges` (UTF-16 in `text`), `snippet` and `snippetRanges` (the Mac's snippet, radius 70), `cursor` (its position, for find in chat). No query text can make these reject; they reject on abort (the signal's reason), after `stop()`, on a cursor they did not produce, or on a storage failure. Also exported: `parseQuery`, `isSearchableQuery`, `tokenize`, `indexText`, `matchRanges`, `messageSnippet`.

## Exposing it to the UI (the host's next step)

Not done here (`host/`, `queries/` and `core-protocol` belong to another package). What the host should add:

1. **Lifecycle.** In the account core, after the `Db` opens on the SQLite replica: `createMessageSearch(db)`. Call `start()` once the core is live and the first paint has happened (not during boot). Call `stop()` before the store closes on sign-out or revocation: a read after close would reopen the replica.
2. **Status.** Add `searchIndex: { state: "building", indexed, total } | { state: "ready" } | { state: "failed" }` to the `core` resource from `subscribe`, so the UI can say "Indexing messages…".
3. **Requests, not subscriptions.** Search results are one-shot answers to a typed query, cancelled when the user types again, so they are request/response commands with an abort, like the remote search:
   - `searchMessages`: request `{ query: string, spaceId?: SpaceID, limit: number, includeArchived: boolean, sort: "newest" | "relevance", cursor?: string }`. Response `{ hits: MessageHit[], nextCursor?: string, indexComplete: boolean, truncated: boolean }`, where `MessageHit` is exactly the Quick Search type in `view/src/quick-search/sources.ts`: `chatId`, `messageId`, `chatTitle` (the sidebar title, which the host computes from its chat, dialog and user rows), `peerUserId` (for a direct chat), `spaceId`, `fromId`, `date`, `snippet`, `snippetRanges`. The core fills `chatId`, `messageId`, `fromId`, `date`, `snippet`, `snippetRanges`; the host adds `chatTitle`, `peerUserId` and `spaceId` from resident rows. Quick Search calls it with `{ query, spaceId: context.spaceId, limit: 20, includeArchived: true, sort: "newest" }`, 120 ms after the last keystroke, only when `isMessageSearchable(query)`; the two-letter rule is the same here.
   - `findInChat`: request `{ chatId, query, cursor?, direction?: "older" | "newer", limit?: number }`. Response `{ hits: Array<{ messageId, fromId, date, out, text, ranges, cursor }>, hasOlder, hasNewer, olderCursor?, newerCursor?, indexComplete, truncated }`. The UI merges server pages by message ID, as the Mac's `InChatSearchViewModel` does; local hits come first.
   - `countMessages`: request `{ chatId?, query }`. Response `{ count, capped, indexComplete }` ("3 of 47", or "10,000+" when capped). The Mac takes the total from the server; the local count is what the device has and can show at once.
4. **Abort.** Pass the link's cancellation through as the `AbortSignal`; a superseded query is then dropped before it reads the disk.

## Merging with the server later

`SEARCH_MESSAGES` (`proto/core.proto`) takes one peer, `queries` (words ANDed in a query, queries ORed), `limit`, `offset_id` (older than this message ID) and `count_only`, and returns `Message`s newest by ID and `total_count`. Its matching is a lowercased substring test on the decrypted text, without the folding here, so the server finds mid-word matches the index does not and the index finds folded variants the server does not. Merge by `(chatId, messageId)`, keep the local hit (it carries ranges), and append server-only hits below, as the Quick Search model already does. Find in chat steps by message ID across both sources, as on the Mac.

## Tests

`bunx vitest run src/search` (63 tests, 1 skipped unless `INLINE_SEARCH_TIMING=1`):

- `atomicity.test.ts`: invariants 1 and 6, a crash at each checkpoint of a message write and of a backfill batch; the next process finds messages and index in agreement and the backfill resumes.
- `engine.test.ts`: every write path (sync new, edit, delete; clear history; `deleteChat` and space purges; certified history pages; optimistic sends confirmed, failed and cancelled; deletes in raw SQL; rewrites with the same text), scripts, hostile query strings, order, rowid collisions, paging while messages arrive, space and archived filters, relevance, the work and time caps, abort, find in chat and count, and invariant 13 with writes held before commit.
- `backfill.test.ts`: upgrade from every earlier schema version, resume after a restart, a read and a partial search while a batch is held open, rebuild on a normalizer change, the bounded failure state.
- `repair.test.ts`: a TOO_LONG chat bucket repaired through the real `SyncEngine` leaves the index matching the rows.
- `normalize.test.ts`: folding, tokens, the query language, ranges and snippets.

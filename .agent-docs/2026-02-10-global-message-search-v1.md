# Global Message Search V1 (Hashed Token Index)

Date: 2026-02-10

## Decisions (From Mo)

- Query shape: `queries[]` (AND within a string, OR across strings).
- Tokenization: `minTokenLen = 2`.
- Matching: whole-token only (no prefix, no substring).
- Typeahead: no (submit/debounce only).
- Scope: dialogs only (`dialogs.user_id = currentUserId`).
- Archived: included by default (no filter).
- Ranking: recency only.
- Index sources: message text + document filenames.
- Write consistency: best-effort async index writes (index may lag).
- Rollout: backfill then enable behind a feature flag.

## Goal

Provide fast “search across all my chats” without storing plaintext in the DB, while keeping the implementation simple and safe against access-control leaks.

## Non-Goals (V1)

- Substring search.
- Prefix/typeahead search.
- Relevance scoring beyond recency.
- Server-side snippet/highlighting.

## API / Protocol

Add a new RPC method:

- `Method.SEARCH_GLOBAL_MESSAGES`

Add messages:

```proto
message SearchGlobalMessagesInput {
  repeated string queries = 1;
  optional int32 limit = 2;
  optional int64 offset_global_id = 3; // pagination cursor; "before this"
  optional SearchMessagesFilter filter = 4; // reuse existing enum
}

message SearchGlobalMessagesResult {
  repeated Message messages = 1;
  optional int64 next_offset_global_id = 2;
}
```

Notes:
- Keep the same `SearchMessagesFilter` enum from `proto/core.proto`.
- Output `Message.peer_id` is already present in protocol, so results can span many chats.
- Cursor is `messages.global_id` (monotonic across all chats).

Server:
- Realtime handler: `server/src/realtime/handlers/messages.searchGlobalMessages.ts`
- Function: `server/src/functions/messages.searchGlobalMessages.ts`

## Storage / Schema

Create a new table in the existing Postgres database.

### `search_message_tokens`

Purpose: inverted index mapping message -> token hashes.

Columns:
- `message_global_id bigint not null` FK -> `messages.global_id` ON DELETE CASCADE
- `chat_id int not null` (denormalized from `messages.chat_id`)
- `token_hash bytea not null` (HMAC-SHA256 output, stored as bytes; can truncate to 16 bytes)
- `source smallint not null` (optional: `1=text`, `2=document_filename` to debug/extend)
- `created_at timestamptz not null default now()` (optional)

Constraints:
- `unique(message_global_id, token_hash, source)` (dedupe)

Indexes:
- `btree(token_hash, message_global_id desc)` for fast recent postings
- `btree(message_global_id)` for cleanup/joins
- (optional) `btree(chat_id, message_global_id desc)` if we add per-chat search later

### `search_index_meta`

Purpose: track backfill progress and operational state.

Columns:
- `id int primary key` (single row = 1)
- `indexed_up_to_global_id bigint not null default 0`
- `updated_at timestamptz not null default now()`

## Cryptography / Secrets

- Add `SEARCH_INDEX_KEY` (HMAC key) as an env var.
- Hash tokens using `HMAC_SHA256(SEARCH_INDEX_KEY, normalized_token)`.
- Do not use plain SHA; must be keyed to prevent dictionary attacks from DB dumps.

V1 leakage accepted:
- Equality + frequency leakage (same token => same hash; counts visible).

## Tokenization

Normalize:
- lowercase
- split on non-letter/digit (keep digits)
- trim

Filters:
- drop tokens shorter than `minTokenLen = 2`
- cap tokens per message: `maxTokensPerMessage = 64`
- cap tokens per query group: `maxQueryTokens = 10` (ignore extras)
- cap token byte length: 64

Index inputs:
- Message plaintext text at send/edit time.
- Document filenames (decrypt and tokenize) for messages with `documentId`.

## Write Path (Best-Effort Async)

### New message send

Current flow encrypts and stores text in `server/src/functions/messages.sendMessage.ts` -> `MessageModel.insertMessage(...)`.

V1 approach:
- After message insert returns `newMessage.globalId`, enqueue an async indexing task:
  - tokenize plaintext message `text` (the same `text` variable used for encryption)
  - if `documentId` exists, load `documents.fileName*`, decrypt filename, tokenize
  - upsert into `search_message_tokens`
- Failures:
  - log warning + include message id/chat id for debugging
  - do not fail the send

### Edit message

After `MessageModel.editMessage(...)` succeeds:
- enqueue reindex for that message:
  - delete existing token rows for `(message_global_id, source in {text, document_filename})`
  - recompute and insert new rows

### Delete message

- rely on FK cascade from `messages.global_id`.

## Query Path (Dialogs-Scoped, Include Archived)

### Inputs

- `queries[]`: OR across groups
- `limit` default 20 (clamp to 50)
- `offset_global_id` optional
- `filter` optional (photos/videos/docs/links)

### Candidate selection strategy

We avoid full set intersections on huge posting lists by bounding candidate work.

Algorithm per query group:
1. tokenize -> token_hashes
2. choose pivot token (v1 heuristic: longest token)
3. fetch candidates from pivot postings, *already scoped to dialogs*:
   - `JOIN dialogs d ON d.chat_id = t.chat_id AND d.user_id = $currentUserId`
   - apply `offset_global_id` to `t.message_global_id`
   - order by `t.message_global_id desc`
   - `LIMIT candidateLimit` (start with 5000)
4. verify remaining tokens using `EXISTS` probes on `search_message_tokens`
5. join to `messages` to apply `filter` on `messages.*` columns and return full messages

Combine OR-groups:
- union the per-group matching `message_global_id`s, then fetch + order by `messages.global_id desc` and `LIMIT limit`.
- Cursor `next_offset_global_id` is the smallest returned `messages.global_id`.

### Filter-only queries

If all query groups tokenize to empty but `filter` is set:
- query `messages JOIN dialogs` directly, ordered by `messages.global_id desc`, `LIMIT limit`.

### Notes

- Access control correctness is guaranteed by scoping candidates via `dialogs` join, not by filtering after the fact.
- Ranking is recency-only: `messages.global_id desc`.

## Backfill Plan (How We Do It)

We cannot backfill in SQL because message text and document filenames are encrypted. Backfill must run in application code that can decrypt.

### Approach (Recommended): resumable incremental backfill job

Implement a Bun script (or server internal job) that:
- Reads `search_index_meta.indexed_up_to_global_id` (watermark).
- Processes messages in ascending `messages.global_id` in small batches (e.g. 1000).
- For each message:
  - decrypt text if present
  - if `documentId` present, decrypt `documents.fileName*`
  - tokenize + HMAC
  - insert token rows with `ON CONFLICT DO NOTHING`
- Updates watermark to the max `global_id` processed after each batch.

Safety knobs:
- batch size
- max runtime per invocation (e.g. 30s)
- sleep between batches (optional)
- ability to stop by config flag

Operational notes:
- Run it as a one-off job against prod DB (preferred) OR as a background worker mode on the server.
- Because indexing writes are best-effort, it is OK if the job is interrupted; it resumes from watermark.
- Track progress: `(max(messages.global_id) - watermark)` lag.

### Rollout sequence

1. Deploy schema + code that can write index rows for new sends/edits (still behind feature flag for query).
2. Start backfill until watermark reaches current max.
3. Enable `SEARCH_GLOBAL_MESSAGES` behind a server-side flag.
4. Keep backfill job available for re-runs if we change tokenization rules later.

## Observability

Log per request:
- user id, token count, query group count
- candidateLimit, candidates selected, matches found
- DB query timings / total latency

Backfill metrics:
- rows indexed per minute
- watermark lag
- error count for decrypt/tokenize

## Testing

- Tokenizer unit tests:
  - punctuation, mixed case, numbers, underscores
  - min token length = 2
  - token caps
- Integration tests (server):
  - dialogs scoping: user only sees messages from chats with `dialogs.userId = user`
  - OR-groups semantics
  - pagination by `offset_global_id`
  - document filename search (encrypted filename)
  - edit reindexes tokens

## Open Questions (Parking Lot)

- Do we want stopwords or frequency caps to handle very common tokens?
- Do we want a `token_stats` table to pick pivot token by rarity (better than “longest”)?
- Should we truncate HMAC to 16 bytes to reduce index size?


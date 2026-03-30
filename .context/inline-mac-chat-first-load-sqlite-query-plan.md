# InlineMac first chat load: SQLite query plan + index fixes

## Symptom

Opening the first chat view (when the chat is already present in the local DB) feels slow and often requires an additional render/layout pass. Instruments shows significant main-thread time during view construction and synchronous message loading.

Key call stack (representative):

- `ContentViewController.switchToRoute(_:)`
  - `NSViewController._loadViewIfRequired`
    - `ChatViewAppKit.loadView()`
      - `ChatViewAppKit.setupChatComponents(chat:)`
        - `MessageListAppKit.init(...)`
          - `MessagesProgressiveViewModel.init(...)`
            - `MessagesProgressiveViewModel.loadMessages(_:)`
              - GRDB `DatabasePool.read { query.fetchAll(...) }`
              - Association prefetch work (`prefetch(_:associations:...)`)

The DB fetch is only part of the total time, but it blocks first paint because it runs during the route-switch / view loading path on the main thread.

## The DB query shape

The initial batch is fetched via `MessagesProgressiveViewModel.baseQuery()` and then ordered by date:

- Filter by peer:
  - thread chat: `WHERE peerThreadId = ?`
  - DM: `WHERE peerUserId = ?`
- Sort: `ORDER BY date DESC`
- Limit: `LIMIT <initialLimit>`

This is the canonical “give me the most recent N messages for this peer” query.

`FullMessage.queryRequest()` then pulls a large graph via GRDB associations:

- sender `UserInfo` + user photos
- message `file`
- reactions (+ reaction user info + user photos)
- replied-to message (+ its sender info, translations, photo/video thumb)
- attachments (+ external task assigned user info, url preview + preview photo sizes)
- photo/video/document (+ sizes / thumbnails)
- translations

## Observed SQLite query plans (before)

### Message list fetch

Both thread and DM variants showed:

```
SCAN message USING INDEX message_date_idx
```

Meaning: SQLite walks the `message(date)` index and applies `peerThreadId = ?` / `peerUserId = ?` as a filter. This can degrade badly as the message table grows across many peers.

### Prefetch fan-out scans

Attachment prefetch:

```
SCAN attachment
LIST SUBQUERY 1
SCAN message USING INDEX message_date_idx
```

Photo sizes prefetch:

```
SCAN photoSize
... (message scanned via message_date_idx)
```

User profile photos prefetch:

```
SCAN file
... (message scanned via message_date_idx)
```

These scans indicate missing supporting indexes on foreign-key-ish columns that are hit by association prefetch queries.

## Current relevant indexes (from sqlite_master)

```
message:     message_date_idx               CREATE INDEX message_date_idx ON message(date)
message:     message_randomid_unique        CREATE UNIQUE INDEX message_randomid_unique ON message(fromId, randomId)
translation: translation_lookup_idx         CREATE UNIQUE INDEX translation_lookup_idx ON translation(chatId, messageId, language)
```

Note: SQLite also creates implicit indexes for `UNIQUE(...)` constraints, but those do not appear in `sqlite_master` with a `CREATE INDEX ...` SQL string.

## Proposed indexes (fix)

These indexes align with the hot-path query patterns:

```sql
-- Message list: match WHERE + ORDER BY (use partial indexes since columns are nullable)
CREATE INDEX IF NOT EXISTS message_peerThread_date_idx
ON message(peerThreadId, date DESC)
WHERE peerThreadId IS NOT NULL;

CREATE INDEX IF NOT EXISTS message_peerUser_date_idx
ON message(peerUserId, date DESC)
WHERE peerUserId IS NOT NULL;

-- Prefetch fan-out: avoid full scans for associations
CREATE INDEX IF NOT EXISTS attachment_messageId_idx
ON attachment(messageId);

CREATE INDEX IF NOT EXISTS photoSize_photoId_idx
ON photoSize(photoId);

CREATE INDEX IF NOT EXISTS file_profileForUserId_idx
ON file(profileForUserId);

-- Update planner stats
ANALYZE;
PRAGMA optimize;
```

## Expected query plan (after)

Re-running `EXPLAIN QUERY PLAN` should show:

- For the message list query:
  - `SEARCH message USING INDEX message_peerThread_date_idx ...` (thread)
  - `SEARCH message USING INDEX message_peerUser_date_idx ...` (DM)
- For prefetch fan-out:
  - `SEARCH attachment USING INDEX attachment_messageId_idx ...`
  - `SEARCH photoSize USING INDEX photoSize_photoId_idx ...`
  - `SEARCH file USING INDEX file_profileForUserId_idx ...`

If you still see `SCAN ...`, confirm the parameters used match the indexes and that `ANALYZE` has been run.

## Follow-ups (non-SQL)

Even with indexes, doing the initial `fetchAll` (including large association graphs) during view loading can still stall first paint. If needed:

- Defer/hydrate heavy associations after first paint (e.g., load messages without replied-to/attachments, then enrich).
- Move initial fetch off the main thread and publish results back on the main actor.


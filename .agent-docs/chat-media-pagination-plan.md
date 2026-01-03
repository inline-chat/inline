# Chat Media/Document Pagination Plan (SearchMessages-based)

## Goal

Extend the existing `searchMessages` RPC (Telegram-style) to support media/document filters + pagination. This lets clients fetch _all_ file/media messages for Chat Info even when local cache is partial.

## API Changes (Proto)

- **Extend** `SearchMessagesInput`:
  - `optional int64 offset_id` (exclusive, same semantics as `GetChatHistory`).
  - `optional SearchMessagesFilter filter` (see below).
- **Add enum** `SearchMessagesFilter`:
  - `FILTER_UNSPECIFIED` → default to **all** messages (current behavior).
  - `FILTER_PHOTOS` → photo only.
  - `FILTER_VIDEOS` → video only.
  - `FILTER_PHOTO_VIDEO` → photo + video.
  - `FILTER_DOCUMENTS` → document only.
  - (optional future) URL/GIF/voice/etc, if we expand the schema.
- **Behavior change**: allow empty `queries` **when** `filter` is provided (to list files/media without text search).

## Server Behavior

1. **Input validation**
   - If `queries` are all empty **and** `filter` is unspecified → keep existing `BadRequest`.
   - If `queries` empty but `filter` set → allow; treat as “no text filter”.
2. **Chat resolution + access**
   - Reuse `getChatWithAccess` from `messages.searchMessages` (auto-create DM when needed).
3. **Query strategy**
   - If `queries` provided:
     - Extend `MessageSearchModule.searchMessagesInChat` to accept:
       - `beforeMessageId` (from `offset_id`).
       - `mediaFilter` (if set) and include it in the batch query where clause.
     - Keep existing batch scan + decrypt matching.
   - If `queries` empty:
     - Use a direct DB query on `messages` with `mediaFilter` + `offset_id` + `limit`, ordered by `message_id desc`.
   - For both paths, load full messages by IDs and encode via `Encoders.fullMessage`.

## Implementation Steps

1. **Proto**
   - `proto/core.proto`: add `SearchMessagesFilter` enum; add `offset_id` + `filter` to `SearchMessagesInput`.
   - Run `bun run generate:proto` to refresh TS/Swift outputs.
2. **Search module**
   - `server/src/modules/search/messagesSearch.ts`:
     - Add optional `beforeMessageId` + `mediaFilter` to input.
     - Apply `messages.photoId/videoId/documentId IS NOT NULL` (or `mediaType`) in `fetchSearchBatch`.
3. **DB model helper**
   - `server/src/db/models/messages.ts`: add `getMessagesWithMedia` (filter + offset + limit) for the no-query path.
4. **Functions**
   - `server/src/functions/messages.searchMessages.ts`:
     - accept `offsetId`, `filter`.
     - allow empty queries when filter present.
     - branch into search module vs direct filtered query.
5. **Handlers**
   - `server/src/realtime/handlers/messages.searchMessages.ts`: pass `offsetId`/`filter`.
6. **Client (iOS initial use)**
   - Add `SearchMessagesTransaction` or extend existing search helper to allow filter + offset.
   - Chat Info files tab: page via searchMessages(filter: documents/media, offset: last message id).
   - Always start fetching from most recent messages regardless of what we have in the cache as the data in cache will have gaps.

## Progress Checklist

- [x] Update proto + regenerate outputs.
- [x] Extend server search module with offset + media filters.
- [x] Add DB helper for filtered media pagination.
- [x] Update searchMessages function + handler to accept filter/offset.
- [x] Add/adjust server tests for filter + pagination.
- [x] Add client transaction + ChatInfo documents paging hook.

## Testing/Verification

- Update/add server test for `searchMessages`:
  - empty queries + filter returns media messages.
  - pagination with `offset_id` works (strictly older).
  - combined query + filter only returns matching media.
- Manual: iOS chat info files list pulls full history (multiple pages).

## Open Questions

1. Is “derive next offset from last `message.id`” acceptable, or do you want `next_offset_id` / `has_more` in the response? acceptable, no need to add useless stuff in the result
2. Should a `filter` with **no queries** return _only_ media/doc messages (proposed), and keep `BadRequest` for empty queries + no filter? proposed.

## Change Summary

- Added `SearchMessagesFilter` + `offset_id`/`filter` fields to `SearchMessagesInput` and regenerated protocol outputs.
- Extended server search path to accept media filters + offset pagination and added a direct media-only query path.
- Added server tests covering filter usage, offset pagination, and empty-queries-with-filter behavior.
- Added `SearchMessagesTransaction` and hooked Chat Info Files to page documents from the server, starting from latest and fetching older pages as needed.

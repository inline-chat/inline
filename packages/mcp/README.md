# @inline-chat/mcp

Inline MCP resource server (Bun runtime) with OAuth routed through the main API server.

## Dev

From repo root:

```sh
cd packages/mcp
bun run dev
```

Production readiness checklist: `PRODUCTION_CHECKLIST.md`.
ChatGPT submission checklist: `SUBMISSION_CHECKLIST.md`.

## Endpoints (v1)

- `GET /health`
- `GET|POST|DELETE /mcp` (MCP Streamable HTTP)
- `GET /.well-known/oauth-authorization-server`
- `GET /.well-known/oauth-protected-resource`
- `POST /oauth/register` (alias: `POST /register`)
- `GET /oauth/authorize`
- `POST /oauth/authorize/send-email-code`
- `POST /oauth/authorize/verify-email-code`
- `POST /oauth/authorize/consent`
- `POST /oauth/token` (alias: `POST /token`)
- `POST /oauth/revoke` (alias: `POST /revoke`)

OAuth routes above are proxied to the API OAuth server configured by `MCP_OAUTH_PROXY_BASE_URL` (defaults to `INLINE_API_BASE_URL`).

## MCP Tools (v2)

- `conversations.list` (read-only): list recent conversations or find by name/title/id.
  - Input: `{ query?, limit?, unreadOnly? }`
  - Output: `{ query, bestMatch, unreadOnly, items[] }`
- `conversations.create` (write): create a new thread/chat in an allowed space or home threads.
  - Input: `{ title, spaceId?, description?, emoji?, isPublic?, participantUserIds? }`
  - Output: `{ chat }`
- `files.upload` (write): secure media upload helper (base64 or HTTPS URL source) that returns Inline media IDs.
  - Input: `{ kind?, base64? | url?, fileName?, contentType?, width?, height?, duration? }`
  - Output: `{ ok, source, sourceRef, sizeBytes, upload: { fileUniqueId, media, uploadKind, fileName, contentType } }`
- `messages.list` (read-only): list messages from a chat or DM with useful filters.
  - Input: `{ chatId? | userId?, direction?, limit?, offsetId?, since?, until?, unreadOnly?, content? }`
  - Output: `{ chat, direction, scannedCount, nextOffsetId, unreadOnly, since, until, content, messages[] }`
- `messages.search` (read-only): query messages in one chat/DM only (no global message search).
  - Input: `{ chatId? | userId?, query?, limit?, since?, until?, content? }`
  - Output: `{ query, mode, content, since, until, chat, messages[] }`
- `messages.unread` (read-only): list unread messages across all approved conversations.
  - Input: `{ limit?, since?, until?, content? }`
  - Output: `{ scannedChats, since, until, content, items[] }`
- `messages.send` (write): send to chat or DM.
  - Input: `{ chatId? | userId?, text, replyToMsgId?, sendMode?, parseMarkdown? }`
  - Output: `{ ok, chatId?|userId?, messageId, metadata }`
- `messages.send_media` (write): send uploaded photo/video/document to chat or DM.
  - Input: `{ chatId? | userId?, mediaKind, mediaId, text?, replyToMsgId?, sendMode?, parseMarkdown? }`
  - Output: `{ ok, chatId?|userId?, media, messageId, metadata }`
- `messages.send_batch` (write): send an ordered list of text/media items to a chat or DM.
  - Input: `{ chatId? | userId?, stopOnError?, items[] }`
  - `items[]` supports:
    - `{ type: "text", text, replyToMsgId?, sendMode?, parseMarkdown? }`
    - `{ type: "media", mediaKind, mediaId, text?, replyToMsgId?, sendMode?, parseMarkdown? }`
  - Output: `{ ok, chatId?|userId?, total, sentCount, failedCount, results[] }`

Common workflows:
1. Find links/media/files in a thread: `messages.search` with `content: "links" | "media" | "files"`.
2. Summarize a thread: `messages.list` with a time window (`since`/`until`) then summarize in the model.
3. Create thread then post: `conversations.create` then `messages.send`.
4. List unread from yesterday: `messages.unread` with `since: "yesterday"` and `until: "yesterday"`.
5. Send a photo/file from external source: `files.upload` then `messages.send_media`.
6. Create a thread and dump content into it:
   - `conversations.create` with `title`, optional `spaceId`, and `participantUserIds`
   - then `messages.send_batch` with mixed text/media items.

Legacy tools `search` and `fetch` are removed.

# @inline-chat/mcp

Inline MCP resource server (Bun runtime) with OAuth routed through the main API server.

## Dev

From repo root:

```sh
cd packages/mcp
bun run dev
```

## Docker

Build from the repository root:

```sh
docker build -f packages/mcp/Dockerfile -t inline-mcp .
docker run --rm -p 8791:8791 -e MCP_INTERNAL_SHARED_SECRET=<shared-secret> inline-mcp
```

The default host is `mcp.inline.chat`. For a direct local health check, pass that host header:

```sh
curl -H "Host: mcp.inline.chat" http://127.0.0.1:8791/health
```

## Configuration

The Docker image does not contain secrets. Provide runtime configuration through your deployment platform's environment variable or secret manager.

- `MCP_INTERNAL_SHARED_SECRET`: shared secret used when the MCP server introspects OAuth access tokens with the Inline API.
- `PORT`: HTTP port, defaults to `8791`.

## Endpoints

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

OAuth routes above are proxied to the API OAuth server (`https://api.inline.chat` in default config).
If embedding the app programmatically, you can override this via `createApp({ oauthProxyBaseUrl })`.

## MCP Tools (v3)

- `account.me` (read-only): inspect current MCP authorization, scopes, and allowed chat context.
  - Input: `{}`
  - Output: `{ user, session, allowed, hints[] }`
- `spaces.list` (read-only): list spaces visible to the current MCP grant.
  - Input: `{ query?, limit? }`
  - Output: `{ query, items[] }`
- `people.search` (read-only): resolve people by name, username, or user ID in allowed contexts.
  - Input: `{ query?, limit? }`
  - Output: `{ query, bestMatch, items[] }`
- `conversations.list` (read-only): list recent conversations or find by name/title/id.
  - Input: `{ query?, limit?, unreadOnly?, sort? }`
  - Output: `{ query, sort, bestMatch, unreadOnly, items[] }`
- `conversations.get` (read-only): inspect one resolved chat/DM, including participants and pinned message IDs.
  - Input: `{ chatId? | userId? }`
  - Output: `{ chat, details, participants[] }`
- `conversations.create` (write): create a new thread/chat in an allowed space or home threads.
  - Input: `{ title, spaceId?, description?, emoji?, isPublic?, participantUserIds? }`
  - Output: `{ chat }`
- `files.upload` (write): secure media upload helper (base64 or HTTPS URL source) that returns Inline media IDs.
  - Input: `{ kind?, base64? | url?, fileName?, contentType?, width?, height?, duration? }`
  - Output: `{ ok, source, sourceRef, sizeBytes, upload: { fileUniqueId, media, uploadKind, fileName, contentType } }`
- `files.get` (read-only): extract file/media metadata from specific message IDs or recent messages.
  - Input: `{ chatId? | userId?, messageId?, messageIds?, limit?, includeUrlPreviews? }`
  - Output: `{ chat, source, messageIds, includeUrlPreviews, items[] }`
- `messages.list` (read-only): list messages from a chat or DM with useful filters.
  - Input: `{ chatId? | userId?, limit?, offsetId?, since?, until?, content? }`
  - Output: `{ chat, nextOffsetId, since, until, content, messages[] }`
- `messages.context` (read-only): fetch a before/after window around a message ID, or latest compact context.
  - Input: `{ chatId? | userId?, anchorMessageId?, before?, after?, includeAnchor?, content? }`
  - Output: `{ chat, anchorMessageId, before, after, includeAnchor, content, messages[] }`
- `messages.search` (read-only): query messages in one chat/DM only (no global message search).
  - Input: `{ chatId? | userId?, query?, limit?, since?, until?, content? }`
  - Output: `{ query, content, since, until, chat, messages[] }`
- `messages.unread` (read-only): list unread messages across all approved conversations.
  - Input: `{ limit?, since?, until?, content? }`
  - Output: `{ scannedChats, since, until, content, items[] }`
- `messages.send` (write): send to chat or DM.
  - Input: `{ chatId? | userId?, text, replyToMsgId?, sendMode? }`
  - Output: `{ ok, chatId?|userId?, messageId, metadata }`
- `messages.send_media` (write): send uploaded photo/video/document to chat or DM.
  - Input: `{ chatId? | userId?, mediaKind, mediaId, text?, replyToMsgId?, sendMode? }`
  - Output: `{ ok, chatId?|userId?, media, messageId, metadata }`
- `messages.send_batch` (write): send an ordered list of text/media items to a chat or DM.
  - Input: `{ chatId? | userId?, stopOnError?, items[] }`
  - `items[]` supports:
    - `{ type: "text", text, replyToMsgId?, sendMode? }`
    - `{ type: "media", mediaKind, mediaId, text?, replyToMsgId?, sendMode? }`
  - Output: `{ ok, chatId?|userId?, total, sentCount, failedCount, results[] }`

Common workflows:
1. Resolve a target clearly: `spaces.list` or `people.search`, then `conversations.list`, then `conversations.get`.
2. Summarize a thread: `messages.list` with a time window (`since`/`until`) then summarize in the model.
3. Read around a found message: `messages.search` or `messages.unread`, then `messages.context`.
4. Find links/media/files in a thread: `messages.search` with `content: "links" | "media" | "files"`, or `files.get` for concrete file metadata.
5. Create thread then post: `conversations.create` then `messages.send`.
6. List unread from yesterday: `messages.unread` with `since: "yesterday"` and `until: "yesterday"`.
7. Send a photo/file from external source: `files.upload` then `messages.send_media`.
8. Create a thread and dump content into it:
   - `conversations.create` with `title`, optional `spaceId`, and `participantUserIds`
   - then `messages.send_batch` with mixed text/media items.

Legacy tools `search` and `fetch` are removed.

All tools return structured content plus a JSON text fallback. Chat, message, and person entities include a canonical `uri` using Inline deep links (`inline://chat/{chatId}`, `inline://chat/{chatId}/message/{messageId}`, `inline://user/{userId}`). Tools advertise output schemas, annotations, and `_meta.securitySchemes` through `tools/list`. Missing write/read scopes return normal MCP tool errors with `_meta["mcp/www_authenticate"]` so compatible clients can trigger reauthorization without treating the request as a server failure.

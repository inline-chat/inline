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
- `GET|POST|DELETE /mcp/v2` (current submission-safe MCP Streamable HTTP contract)
- `GET|POST|DELETE /mcp` (deprecated legacy MCP contract for existing clients)
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

## MCP Tools (submission v2)

Connect new clients to `https://mcp.inline.chat/mcp/v2`. Every conversation-scoped tool uses the stable `chatId`, including DMs. The legacy `/mcp` endpoint retains the earlier `chatId | userId` and selector shapes during the migration window; it is not intended for new integrations or ChatGPT submission scanning.

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
- `conversations.mentions` (read-only, app-visible): search approved conversation metadata for the desktop composer picker.
  - Input: `{ query }`, including an empty string for recent conversations.
  - Output: `{ items: ResourceLink[] }` in structured content, with empty text content, as required by the mention-search extension. At most 20 links; no message bodies are fetched by search.
  - Each `inline://chat/{chatId}` resource read checks authorization independently and returns a recent-text JSON snapshot of at most 20 messages / 32 KiB, including coverage, capture time, shortening flags, and older-history continuation. Selection does not grant access, mark messages read, or launch the native app.
- `conversations.get` (read-only): inspect one resolved chat/DM, including participants and pinned message IDs.
  - Input: `{ chatId }`
  - Output: `{ chat, details, participants[] }`
- `conversations.create` (write): create a new thread/chat in an allowed space or home threads.
  - Input: `{ title, spaceId?, description?, emoji?, isPublic?, participantUserIds? }`
  - Output: `{ chat }`
- `files.upload` (write): secure media upload helper (base64 or HTTPS URL source) that returns Inline media IDs.
  - Input: `{ sourceType: "base64" | "url", source, kind?, fileName?, contentType?, width?, height?, duration? }`
  - Output: `{ ok, source, sourceRef, sizeBytes, upload: { fileUniqueId, media, uploadKind, fileName, contentType } }`
- `files.get` (read-only): extract file/media metadata from one or more known message IDs.
  - Input: `{ chatId, messageIds, includeUrlPreviews? }`
  - Output: `{ chat, source, messageIds, includeUrlPreviews, items[] }`
- `messages.list` (read-only): list messages from a chat or DM with useful filters.
  - Input: `{ chatId, limit?, offsetId?, since?, until?, content? }`
  - Output: `{ chat, nextOffsetId, since, until, content, messages[] }`
- `messages.context` (read-only): fetch a before/after window around a known message ID.
  - Input: `{ chatId, anchorMessageId, before?, after?, includeAnchor?, content? }`
  - Output: `{ chat, anchorMessageId, before, after, includeAnchor, content, messages[] }`
- `messages.search` (read-only): query messages in one chat/DM only (no global message search).
  - Input: `{ chatId, query, limit?, since?, until?, content? }`
  - Output: `{ query, content, since, until, nextOffsetId, chat, messages[] }`
  - When present, `nextOffsetId` identifies an older `messages.list` read. It does not add pagination to search or prove older matching messages exist.
- `messages.unread` (read-only): list unread messages across all approved conversations.
  - Input: `{ limit?, since?, until?, content? }`
  - Output: `{ scannedChats, since, until, content, items[] }`
- `messages.send` (write): send Inline Markdown text to a chat or DM.
  - Input: `{ chatId, text, replyToMsgId?, sendMode? }`
  - Output: `{ ok, chatId, messageId, metadata }`
- `messages.send_media` (write): send uploaded photo/video/document to chat or DM; optional captions use Inline Markdown.
  - Input: `{ chatId, mediaKind, mediaId, text?, replyToMsgId?, sendMode? }`
  - Output: `{ ok, chatId, media, messageId, metadata }`
- `messages.send_batch` (write): send an ordered list of text/media items to a chat or DM; text items use Inline Markdown.
  - Input: `{ chatId, stopOnError?, items[] }`
  - Every item has exactly `{ type, content }` and uses normal, non-reply delivery.
  - `type` is `"text"`, `"photo"`, `"video"`, or `"document"`; `content` is text for a text item and an uploaded media ID otherwise.
  - Use `messages.send` or `messages.send_media` when a reply target or silent delivery is needed.
  - Output: `{ ok, chatId, total, sentCount, failedCount, results[] }`

Common workflows:
1. Resolve a target clearly: `spaces.list` or `people.search`, then `conversations.list`, then `conversations.get`.
2. Summarize a thread: `messages.list` with a time window (`since`/`until`) then summarize in the model.
3. Read around a found message: `messages.search` or `messages.unread`, then `messages.context`.
4. Find links/media/files in a thread: `messages.list` with `content: "links" | "media" | "files"`, then `files.get` for concrete metadata from known message IDs.
5. Create thread then post: `conversations.create` then `messages.send`.
6. List unread from yesterday: `messages.unread` with `since: "yesterday"` and `until: "yesterday"`.
7. Send a photo/file from external source: `files.upload` then `messages.send_media`.
8. Create a thread and dump content into it:
   - `conversations.create` with `title`, optional `spaceId`, and `participantUserIds`
   - then `messages.send_batch` with mixed text/media items.

Legacy tools `search` and `fetch` are removed.

Model-visible tools return structured content plus a JSON text fallback. The app-only mention-search adapter follows the host's resource-link result contract described above. Chat, message, and person entities include a canonical `uri` (`inline://chat/{chatId}`, `inline://chat/{chatId}/message/{messageId}`, `inline://user/{userId}`). The conversation URI also identifies the authorized MCP snapshot resource; native-app launching is a separate host capability. Tools advertise output schemas, annotations, and `_meta.securitySchemes` through `tools/list`. Missing write/read scopes return MCP authorization errors so compatible clients can trigger reauthorization.

## Optional ChatGPT UI

`messages.list`, `messages.search`, and `messages.context` return data without opening a card. The model can paginate a large read and write a normal summary, including the actual scope and any incomplete coverage. Rendering is separate and optional.

`messages.view` accepts canonical references for `sources`, or selected chat IDs for `catch_up`. Source selections preserve order across chats, deduplicate references, and retain unavailable entries. The reader retrieves real history for the active chat and supports older/newer pages and reply context; selected evidence is never represented as complete conversation history. Every new read checks authorization. A view does not certify how many messages the model analyzed. Catch-up loads 50 messages per page and retains a recoverable 300-message window per chat. “Since last read” uses the current read boundary; the wire format does not identify every message counted as unread, so the reader does not claim an exact first-unread marker.

The component starts as a compact preview. A supported host can expand it into an Inline-style chat list and chronological message pane. User navigation, source selection, media opening, and local scroll state belong to that component; it has no independent network client or background sync. It never sends messages or marks them read. Missing host capabilities produce a useful preview rather than an inert action.

Media uses actual filenames, sizes, durations, image variants and author metadata where available. Signed presentation image/file URLs are delivered in UI-only `_meta.inline`, outside model-visible presentation output. Embedded images stay restricted to Inline’s API media endpoint, use no-referrer, and retain descriptive fallback content if they cannot load. Canonical document/video/audio originals may also use structurally validated, unexpired R2 signed URLs tied to the returned file identity; these open through the host and are never embedded. The resource CSP remains API-only. Message text and entities are rendered without trusting HTML. Existing data-tool outputs remain compatible. Long presentation text is explicitly shortened; data tools retain the original. This is a read-focused client surface: native reactions, editing, sending, math rendering, and interactive mention/thread navigation are not implemented here.

The versioned HTML and script are embedded in the compiled module, so the MCP build includes them in the Docker runtime’s `dist` copy. There is no separate UI deployment or remote script bundle. Desktop mention selection and real host interaction require acceptance independently of package tests. See the [plugin update and release guide](../../plugins/chatgpt/RELEASING.md).

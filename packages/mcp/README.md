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
- `MCP_UI_RESOURCE_DOMAINS`: optional comma-separated exact HTTPS asset origins for signed thread media. The thread resource already permits `https://api.inline.chat` for photos; no direct API connections or wildcard origins are granted.

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

Both MCP endpoints also accept stateless MCP `2026-07-28` POST requests, with `server/discover` and webhook `events/list`, `events/subscribe`, and `events/unsubscribe`. Modern requests require the standard per-request metadata and matching HTTP headers; their GET/DELETE requests are unsupported. The older initialized Streamable HTTP lane is retained. See the [durable Events contract](../../server/docs/mcp-events.md) for the catalog, finite renewal, callback verification, replay and revocation rules.

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
- `conversations.open` (read-only): open the focused Inline thread UI. `{ chatId }` reads fresh recent history and confirmed monitoring; `{}` opens only the small picker of threads already viewed in this app. The returned `capabilities.canSend` follows the current write scope.
- `conversations.ask` (read and write): create a private consultation with the connected user and resolved teammates, capture a replay cursor, then send one question. Input: `{ title, question, participantUserIds, spaceId? }`. Output includes the confirmed chat, `questionStatus`, optional confirmed `messageId`, and `{ name, arguments, cursor }` for `events/subscribe`. Subscribe from that exact cursor before waiting, then read the current reply and continue. Preserve partial receipts and inspect uncertain writes before retrying.
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

`conversations.open` and `conversations.ask` reference `ui://inline/thread-v2.html`, a bundled React application in `plugins/chatgpt/ui`. It uses the host bridge to open/read/send, shows one thread at a time and remembers at most 12 explicitly opened thread references. It supports bounded older history, text replies, photo/video/audio/document presentation, and up to ten selected excerpts for hosts that support model-context updates. Confirmed message IDs clear the composer; an uncertain receipt retains the draft and blocks automatic resend across remount. It supplies global and per-thread entrypoint metadata for capable hosts. There is no full workspace navigation, background unread client, upload/editor/calls implementation or separate web deployment.

The MCP build compiles the React bundle first; the runtime image contains its generated HTML module. Signed media origins must satisfy the explicit widget CSP. Authentication, host placement, actual rendering and event-driven continuation remain host-dependent acceptance checks.

The previous `ui://inline/thread-v1.html` resource remains readable for cached tool descriptors. Explicit access failures carry UI-only `_meta.inline.accessDenied: true`; the component clears fetched content and disables its actions while ordinary transport failures retain the loaded view. Subscription status is connection-wide and does not prove that the current ChatGPT task is waiting.

`messages.list` and `messages.search` reference `ui://inline/message-results-v1.html`, served as `text/html;profile=mcp-app`. The passive component renders conversation/filter coverage, native chat bubbles, readable sender names and local times, and local text expansion. Source IDs remain in tool data rather than the visible transcript. An optional `senderDisplayName` comes from the existing conversation catalog, only for authors of returned messages; no additional profile requests are made. Unknown authors retain a neutral label. Native gradient initials use InlineAvatarCore’s palette and name hash. Signed profile URLs from the same catalog are limited to returned authors and supplied only in `_meta.inline.senderAvatarUrls`, outside model-visible text/structured content. Images may load only from `https://api.inline.chat/file`; unavailable/expired photos reveal the local initials fallback. The HTML and script are embedded in the compiled module, so `bun run build` includes them in the Docker runtime’s `dist` copy; no separate UI deployment, remote scripts, or remote styles are needed.

These cards show messages already visible to the model. Profile photos are presentation metadata; the card introduces no selected-context privacy boundary, sending, or additional message reads. Development origins and older direct-storage photo URLs use the native fallback rather than expanding the resource CSP. Desktop mention availability and actual host rendering require host acceptance independently of package tests. See the [plugin update and release guide](../../plugins/chatgpt/RELEASING.md).

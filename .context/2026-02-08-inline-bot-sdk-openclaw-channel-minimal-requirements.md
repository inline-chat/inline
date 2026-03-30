# Inline Bot SDK + OpenClaw Channel (Minimal Requirements Spec) (2026-02-08)

Goal: ship an **Inline Bot SDK** (owned by Inline) and an **OpenClaw channel plugin** that uses it, so OpenClaw can receive messages from Inline and reply back (like Telegram/Slack/Discord).

This spec is intentionally minimal: it defines the smallest surface that still behaves reliably.

---

## 1) Goals

1. OpenClaw can run an `inline` channel that:
1. Receives Inline messages (DMs and threads/chats).
1. Triggers an agent reply (optionally mention-gated).
1. Delivers replies back into the same Inline conversation.
1. Survives restarts without losing messages (reasonable best-effort).

## 2) Non-Goals (for MVP)

1. Full Inline client parity (dialogs, read states, pinning, etc).
1. Perfect history backfill if the bot was offline “too long”.
1. Full rich-text fidelity (entities, attachments) beyond basic text.
1. Media send/receive (photos/videos/files) beyond basic text (see Section 9 extension).

---

## 3) Architecture (Recommended)

1. **Inline-owned SDK** (Node/TS):
1. `@inline-chat/protocol` (already exists locally) remains the generated protobuf types.
1. Create `@inline-chat/bot-sdk` (new) that:
1. Talks to Inline `/realtime` (protobuf WS).
1. Exposes a typed RPC client and a normalized inbound update stream.
1. Handles reconnect/backoff and optional catch-up cursoring.

2. **OpenClaw channel implementation**:
1. Add a core provider in OpenClaw (example pattern: Slack/Telegram monitors).
1. Keep OpenClaw-specific mapping (session keys, `finalizeInboundContext`, dispatch/reply) in OpenClaw.
1. Keep Inline protocol details in the Inline SDK.

---

## 4) Inline Transport + Primitives (What the SDK wraps)

Inline’s bot runtime interface should be based on the existing protobuf WS:

1. WebSocket endpoint: `wss://<api-host>/realtime`
1. Handshake: send `ClientMessage.connectionInit { token, layer?, client_version? }`
1. Server pushes `ServerProtocolMessage.message { update: UpdatesPayload { updates: Update[] } }`
1. RPC calls are `ClientMessage.rpcCall { method, input }` and return `ServerProtocolMessage.rpcResult`

Minimum RPC methods the SDK must support:

1. `GET_ME` (identify the bot user id; loop prevention)
1. `SEND_MESSAGE` (deliver OpenClaw replies)
1. `SEND_COMPOSE_ACTION` (optional typing; can be stubbed)
1. `GET_UPDATES_STATE` (catch-up discovery on reconnect)
1. `GET_UPDATES` (catch-up fetch per bucket)

---

## 5) SDK Requirements (`@inline-chat/bot-sdk`)

### 5.1 Public API (minimal)

Provide a small, stable API that OpenClaw can call:

```ts
export type InlineBotSdkOptions = {
  baseUrl: string;           // https://api.inline.chat
  token: string;             // bot token "<userId>:IN..."
  clientVersion?: string;    // optional, for server analytics
  layer?: number;            // optional, for protocol evolution
  logger?: {
    debug?: (msg: string, meta?: unknown) => void;
    info?: (msg: string, meta?: unknown) => void;
    warn?: (msg: string, meta?: unknown) => void;
    error?: (msg: string, meta?: unknown) => void;
  };
  state?: InlineBotStateStore; // optional persistence
};

export type InlineInboundEvent =
  | { kind: "message.new"; chatId: number; message: import("@inline-chat/protocol").Message; seq: number; date: number }
  | { kind: "message.edit"; chatId: number; message: import("@inline-chat/protocol").Message; seq: number; date: number }
  | { kind: "message.delete"; chatId: number; messageIds: number[]; seq: number; date: number }
  | { kind: "reaction.add"; chatId: number; reaction: import("@inline-chat/protocol").Reaction; seq: number; date: number }
  | { kind: "reaction.delete"; chatId: number; emoji: string; messageId: number; userId: number; seq: number; date: number }
  | { kind: "chat.hasUpdates"; chatId: number; updateSeq: number; seq: number; date: number }
  | { kind: "space.hasUpdates"; spaceId: number; updateSeq: number; seq: number; date: number };

export interface InlineBotClient {
  connect(signal?: AbortSignal): Promise<void>;
  close(): Promise<void>;

  getMe(): Promise<{ userId: number }>;

  sendMessage(params: {
    chatId: number;
    text: string;
    replyToMsgId?: number;
    parseMarkdown?: boolean;
    sendMode?: "silent";
  }): Promise<void>;

  sendTyping(params: { chatId: number; typing: boolean }): Promise<void>;

  events(): AsyncIterable<InlineInboundEvent>;
}
```

Notes:

1. Use `AsyncIterable` instead of callbacks so OpenClaw can drive shutdown via `AbortSignal`.
1. Keep the SDK neutral: no OpenClaw session keys, no allowlist logic, no agent concepts.

### 5.2 Reconnect + backoff (must)

1. On WS drop or decode failures:
1. Retry forever with exponential backoff + jitter.
1. Re-run handshake, then immediately run catch-up flow (below).

### 5.3 Loop prevention (must)

1. SDK must expose `getMe()` and OpenClaw must ignore:
1. `message.out == true`
1. `message.from_id == botUserId`

### 5.4 Catch-up cursoring (strongly recommended)

The SDK should support optional persisted cursors to avoid missing messages.

State store interface:

```ts
export interface InlineBotStateStore {
  load(): Promise<{ version: 1; dateCursor?: bigint; lastSeqByChatId?: Record<string, number> } | null>;
  save(next: { version: 1; dateCursor?: bigint; lastSeqByChatId?: Record<string, number> }): Promise<void>;
}
```

Catch-up algorithm (minimal and safe):

1. Load `{ dateCursor, lastSeqByChatId }` (default `dateCursor = now`, and empty seq map).
1. Call `GET_UPDATES_STATE(dateCursor)` on connect.
1. While connected, the server will push `chatHasNewUpdates/spaceHasNewUpdates` updates to the socket.
1. For `chat.hasUpdates(chatId, updateSeq)`:
1. Let `startSeq = lastSeqByChatId[chatId] ?? updateSeq` (default to “skip backlog”).
1. If `updateSeq > startSeq`, call `GET_UPDATES(bucket=chat(chatId), start_seq=startSeq, seq_end=updateSeq, total_limit=1000)`.
1. If `result_type == TOO_LONG`, default behavior is:
1. Log a warning.
1. Fast-forward cursor to `seq = result.seq`.
1. Continue (no backfill). Optional later: backfill with `GET_CHAT_HISTORY`.
1. For every delivered update, advance `lastSeqByChatId[chatId] = max(lastSeq, update.seq)`.
1. Persist state periodically and on clean shutdown.

SDK should also advance cursors when it receives live `message.new/edit/delete` events with `seq`.

### 5.5 Ordering guarantees (per chat)

SDK should emit events in the order received, but OpenClaw must also guard:

1. Process events sequentially per chatId (single-flight queue) to avoid races.
1. Drop any event with `seq <= lastProcessedSeq[chatId]` to tolerate duplicates.

### 5.6 Logging + redaction

1. Never log raw tokens.
1. Log reconnect reasons and cursor jumps (especially `TOO_LONG`).

---

## 6) OpenClaw Integration Requirements

### 6.1 OpenClaw provider structure

Implement in OpenClaw (core) a monitor similar to Slack/Telegram:

1. `monitorInlineProvider({ token, baseUrl, accountId, cfg, runtime, abortSignal })`
1. Create SDK client.
1. For each inbound event:
1. Resolve route/session key using `resolveAgentRoute({ channel: "inline", peer: { kind, id } })`.
1. Build `FinalizedMsgContext` via `finalizeInboundContext(...)`.
1. Call `dispatchInboundMessage(...)` (or `dispatchReplyWithBufferedBlockDispatcher(...)`) with a dispatcher whose `deliver()` calls `client.sendMessage(...)`.

### 6.2 Session key strategy (recommended defaults)

Inline can have many DMs. To avoid cross-user context leakage, recommend users set:

1. `session.dmScope = "per-channel-peer"` (or `"per-peer"`).

Mapping suggestion:

1. Use `peer.kind = "dm"` for private chats and `peer.id = "chat:<chatId>"` or `user:<otherUserId>`.
1. Use `peer.kind = "group"` for threads/chats in spaces and `peer.id = "chat:<chatId>"`.

Keep the mapping deterministic and stable across restarts.

### 6.3 Mention gating

In rooms/spaces:

1. Default to “mention only”.
1. Use Inline’s `Message.mentioned` (encoded per recipient) when available.

In DMs:

1. Always accept.

### 6.4 Outbound delivery

1. Default reply target: the chatId the inbound message came from.
1. Respect OpenClaw reply threading policy by passing `replyToMsgId` when appropriate.
1. Optionally implement typing:
1. start: `sendTyping({ typing: true })`
1. stop: `sendTyping({ typing: false })`

### 6.5 Multi-account

OpenClaw inline plugin must support multiple accounts the same way Slack/Telegram do:

1. `channels.inline.accounts.<id>.token`
1. `channels.inline.accounts.<id>.baseUrl` (optional override)
1. Per-account allowlists and mention policy.

---

## 7) Operational + Security Considerations

1. **Token risk**: Inline bot token is a session token. Treat as a secret and support `tokenFile` and env var for default account.
1. **Abuse control**: ship allowlists for:
1. DM senders (Inline user ids)
1. group chat ids
1. “mention required” per chat
1. **Backlog behavior**: default to skipping historical backlog on first install; make backfill explicit.
1. **Too-long catch-up**: decide policy now:
1. MVP: fast-forward with warning
1. Later: backfill last N messages via `GET_CHAT_HISTORY`
1. **Rate limiting**: coalesce typing; avoid sending multiple replies too quickly; chunk messages.

---

## 8) Implementation Hints (Direction)

1. Keep `@inline-chat/bot-sdk` small and boring:
1. One reconnecting WS client.
1. One RPC helper.
1. One optional cursor manager.
1. Make the OpenClaw side responsible for:
1. routing, session keys, safety policies, mention gating
1. formatting prompts and replies
1. Treat “SDK version vs server version” as a first-class concern:
1. always send `client_version` and `layer`
1. add a compatibility note in SDK README

---

## 9) Extension: Media (Images / Videos / Files)

This section is an extension to add support for:

1. Inbound media from Inline (images/videos/documents) into OpenClaw context.
1. Outbound media from OpenClaw replies back into Inline (upload + send).

### 9.1 Inbound: map Inline media to OpenClaw `MsgContext`

Inline message media is `Message.media` (proto `MessageMedia`), one of:

1. `photo` (`Photo` with `sizes[].cdn_url` + `format`)
1. `video` (`Video.cdn_url` + optional `photo` thumbnail)
1. `document` (`Document.cdn_url` + `mime_type` + `file_name`)

OpenClaw expects media in these fields:

1. `MediaUrl` / `MediaUrls` (string or string[])
1. `MediaType` / `MediaTypes` (optional MIME hints)

Recommended mapping:

1. If `Message.media.photo`:
1. Choose the “best” size URL:
1. Prefer the largest `PhotoSize` with a non-empty `cdn_url`.
1. Fallback to the first size with `cdn_url`.
1. Set `ctx.MediaUrl = <cdn_url>`.
1. Set `ctx.MediaType` based on `Photo.format`:
1. `FORMAT_JPEG` -> `image/jpeg`
1. `FORMAT_PNG` -> `image/png`
1. If `Message.media.video`:
1. Set `ctx.MediaUrl = video.cdn_url` (if present).
1. Set `ctx.MediaType = "video/*"` or omit (OpenClaw can detect from download response).
1. If `Message.media.document`:
1. Set `ctx.MediaUrl = document.cdn_url` (if present).
1. Set `ctx.MediaType = document.mime_type` when non-empty.

Notes:

1. Inline `cdn_url` is expected to be signed/expiring. OpenClaw should fetch it promptly (or cache the bytes locally in its sandbox/workdir).
1. Inline “albums” can be represented by multiple messages sharing `Message.grouped_id`. If you later want multi-media inbound, aggregate by `grouped_id` into `MediaUrls` (keep order by `Message.id`/`date`) and dispatch once.

### 9.2 Outbound: send media to Inline (OpenClaw -> Inline)

OpenClaw reply payload supports:

1. `ReplyPayload.mediaUrl?: string`
1. `ReplyPayload.mediaUrls?: string[]`

Inline currently requires media be uploaded first, then referenced by id in `SEND_MESSAGE`:

1. Upload: `POST <baseUrl>/v1/uploadFile` (`multipart/form-data`)
1. Send: realtime `SEND_MESSAGE` with `SendMessageInput.media = InputMedia{ photo|video|document }`

#### 9.2.1 Upload contract (Inline HTTP)

`POST /v1/uploadFile` fields:

1. `type`: `"photo" | "video" | "document"`
1. `file`: the file bytes
1. `thumbnail` (optional): thumbnail image (used for `video`)
1. `width`, `height`, `duration` (required for `type="video"`, as strings)
1. Auth: `Authorization: Bearer <botToken>`
1. File size: enforce a client-side limit; server max is currently 500MB.

Response:

1. `photoId?`, `videoId?`, `documentId?` (plus `fileUniqueId`)

#### 9.2.2 SDK API additions (recommended)

Add minimal helpers to `@inline-chat/bot-sdk`:

```ts
export type InlineUploadType = "photo" | "video" | "document";

export type InlineUploadSource =
  | { kind: "url"; url: string }
  | { kind: "path"; path: string }
  | { kind: "bytes"; bytes: Uint8Array; fileName?: string; mimeType?: string };

export type InlineVideoMeta = { width: number; height: number; duration: number };

export interface InlineBotClient {
  // Existing:
  sendMessage(...): Promise<void>;

  // New:
  uploadFile(params: {
    type: InlineUploadType;
    source: InlineUploadSource;
    videoMeta?: InlineVideoMeta;           // required when type === "video"
    thumbnail?: InlineUploadSource;        // optional for type === "video"
  }): Promise<{ photoId?: number; videoId?: number; documentId?: number; fileUniqueId: string }>;

  sendMediaMessage(params: {
    chatId: number;
    caption?: string;
    replyToMsgId?: number;
    media:
      | { kind: "photo"; photoId: number }
      | { kind: "video"; videoId: number }
      | { kind: "document"; documentId: number };
  }): Promise<void>;
}
```

Behavior requirements:

1. `uploadFile({ source: { kind: "url" } })` must download the URL (bounded by max bytes + timeout) and stream to Inline.
1. `uploadFile({ source: { kind: "path" } })` must read local bytes without allowing path traversal surprises (OpenClaw already has sandbox staging helpers; prefer staging first).
1. Do not log `source.url` query params (may contain secrets) or bearer tokens.

#### 9.2.3 Mapping `ReplyPayload` -> Inline sends

Suggested OpenClaw deliverer behavior (mirrors Telegram/Discord behavior in OpenClaw):

1. Let `mediaList = payload.mediaUrls ?? (payload.mediaUrl ? [payload.mediaUrl] : [])`.
1. If `mediaList.length === 0`: send text as today (`sendMessage`).
1. Otherwise:
1. Send N messages, one per attachment URL.
1. Put caption text (`payload.text`) only on the first attachment message.
1. For each attachment:
1. Determine `upload.type`:
1. If MIME is `image/*`, use `"photo"`.
1. If MIME is `video/*`, use `"video"` if `videoMeta` is available, else fallback to `"document"`.
1. Otherwise use `"document"`.
1. `uploadFile(...)` then `sendMediaMessage(...)`.

Video metadata options:

1. MVP: treat videos as `"document"` unless OpenClaw can supply `{ width, height, duration }`.
1. Later: add optional inference via `ffprobe` (or relax Inline server to accept missing metadata and compute it server-side).

### 9.3 Other “more” extensions to keep in mind

1. Audio:
1. Inline has no dedicated audio media type today; send as `"document"` and let OpenClaw tag `audioAsVoice` be ignored for Inline.
1. Stickers:
1. Inline has `Message.is_sticker`; decide whether to pass sticker images as media URLs or ignore.
1. Rich entities:
1. Inline supports `Message.entities`; you can later convert to Markdown/plain for prompts and preserve in outgoing `SendMessageInput.entities`.

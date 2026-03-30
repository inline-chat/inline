# Message Forwarding Plan (Revised)

## Goals (Updated)
- New RPC `forwardMessages` that forwards **multiple source messages** to **one destination peer** per call.
- Forward header named `fwd_from: MessageFwdHeader` on `Message` (Telegram‑style naming).
- Shared SwiftUI forward sheet (iOS + macOS) for picking chats and sending; UI initially forwards **one message**, but RPC supports multi‑message for later.
- Forwarded messages are **new messages** with optional forward header.
- **Media forwarding** creates **new file entities** in DB (new IDs), but can reuse the **same CDN object/path**.

## Telegram Naming Reference (for alignment)
- Telegram schema uses `messageFwdHeader` and `fwd_from` on `message`, and `messages.forwardMessages` for the RPC, with a `drop_author` flag to suppress the header. citeturn0open0turn0open1

## Decisions (Resolved)
1. **Forward chain**: `fwd_from` always points to the **original source**.
2. **Header fields**: include `from_peer_id`, `from_id`, and `from_message_id` (no date yet).
3. **Attachments**: reuse existing `url_preview` / `external_task` when possible; otherwise strip.
4. **UI toggle**: **no toggle** yet (header always shared).
5. **Destination scope**: include **archived chats** in picker.

## Protocol Changes (Names Included)
- `proto/core.proto`
  - New message type:
    - `message MessageFwdHeader { Peer from_peer_id = 1; int64 from_id = 2; int64 from_message_id = 3; }`
  - `Message` add field:
    - `optional MessageFwdHeader fwd_from = <next_field>;`
  - New RPC:
    - `Method.FORWARD_MESSAGES` (new enum value)
    - `message ForwardMessagesInput { InputPeer from_peer_id = 1; repeated int64 message_ids = 2; InputPeer to_peer_id = 3; optional bool share_forward_header = 4; }`
    - `message ForwardMessagesResult { repeated Update updates = 1; }`
  - Wire into `RpcCall` + `RpcResult` oneofs.
- Regenerate protos: `bun run generate:proto`.

## Server: DB + Models + Encoders (Names Included)
- **DB schema** `server/src/db/schema/messages.ts`
  - Add columns: `fwdFromPeerUserId`, `fwdFromPeerChatId`, `fwdFromMessageId`, `fwdFromSenderId` (nullable).
- **Migration**
  - `bun run db:generate add_message_fwd_header` + migrate.
- **Model processing** `server/src/db/models/messages.ts`
  - Extend `DbMessage`/`DbFullMessage` and `processMessage` to carry fwd fields.
- **Encoder** `server/src/realtime/encoders/encodeMessage.ts`
  - Emit `fwdFrom` when present into `Message.fwd_from`.

## Server: Media Cloning (Required)
Add helpers to clone media **and** underlying file rows:
- `server/src/db/models/files.ts` (new helpers)
  - `clonePhotoById(photoId: number, newOwnerId: number): Promise<number>`
  - `cloneVideoById(videoId: number, newOwnerId: number): Promise<number>`
  - `cloneDocumentById(documentId: number, newOwnerId: number): Promise<number>`
Notes:
- New `files` row must get a **new** `file_unique_id` but can reuse encrypted `path_*` and CDN metadata (same underlying blob).
- Clone `photo_sizes` rows so they reference the **new file id**.
- If video/document has a thumbnail photo, clone that photo (and its sizes) too.

## Server: RPC Handler (Names Included)
- New handler file: `server/src/realtime/handlers/messages.forwardMessages.ts`
- New function: `Functions.messages.forwardMessages` (or `messages.forwardMessages` in `server/src/functions/`).
- Wire into `server/src/realtime/handlers/_rpc.ts`:
  - `case Method.FORWARD_MESSAGES: ...`

### Handler Flow (Detailed)
1. Validate input: `from_peer_id`, `to_peer_id`, `message_ids` non-empty.
2. Resolve source chat via `ChatModel.getChatFromInputPeer` and `AccessGuards.ensureChatAccess`.
3. Fetch each source message using `MessageModel.getMessage(message_id, chatId)`.
   - If any missing -> `RealtimeRpcError.MessageIdInvalid`.
4. Resolve destination chat and access.
5. For each message to forward:
   - Clone text/entities exactly (no markdown reparse).
   - Clone media using new media clone helpers (required).
   - Set `fwd_from` fields if `share_forward_header != false` (default true).
   - Insert new message with `MessageModel.insertMessage`.
   - Push updates (reuse `sendMessage` pipeline or shared helper).
6. Collect **self updates** for all forwarded messages (order preserved), return `ForwardMessagesResult`.

## Client: InlineKit Storage + Models (Names Included)
- `apple/InlineKit/Sources/InlineKit/Models/Message.swift`
  - Add `forwardFromUserId`, `forwardFromThreadId`, `forwardFromMessageId` fields.
  - Decode from proto `Message.fwd_from` in `init(from:)`.
  - Add columns in `Message.Columns`.
- `apple/InlineKit/Sources/InlineKit/Database.swift`
  - New migration: add forward header columns to `message` table.

## Client: Transaction (Names Included)
- New file `apple/InlineKit/Sources/InlineKit/Transactions2/ForwardMessagesTransaction.swift`
  - `method = .forwardMessages`
  - Input mapping to `ForwardMessagesInput`.
  - Context: `fromPeer`, `toPeer`, `messageIds`, `shareForwardHeader`.
  - `apply` uses `Api.realtime.applyUpdates`.
- Register in `TransactionTypeRegistry` if needed.

## Shared SwiftUI Forward Sheet (InlineUI)
- New shared view `apple/InlineUI/Sources/InlineUI/ForwardMessagesSheet.swift`:
  - Inputs: `messages: [FullMessage]` (UI currently passes one).
  - Uses `HomeViewModel` to list chats (active + archived), multi‑select UI.
  - Send: for each selected peer -> call `Api.realtime.send(ForwardMessagesTransaction(...))`.

## iOS Integration (Names Included)
- Add “Forward” action to message context menu in `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`.
- Present `ForwardMessagesSheet` via `UIHostingController` from the responder chain.

## macOS Integration (Names Included)
- Add “Forward” item in `apple/InlineMac/Views/Message/MessageView.swift` context menu.
- Present `ForwardMessagesSheet` in a sheet (`NSWindow.beginSheet`) with `NSHostingController`.

## Cross‑Cutting / Missed‑Spot Analysis (Checklist)
- **Updates + Sync**: verify `getChatHistory`, `newMessage` updates, and `Sync` all carry `fwd_from` through encode/decode.
- **Search/Translate**: forwarded messages should still be searchable/translatable (no special case needed if text/entities unchanged).
- **Notifications**: forwarded messages should use standard push flow (no changes unless you want “Forwarded” label).
- **Access control**: ensure both source and destination chat access checks are enforced.
- **Message ordering**: forwarded messages should preserve send date (use now) and not copy original timestamp.
- **Entities**: preserve entities without re‑parsing markdown.
- **Media**: must clone new file entities (requirement). Ensure no orphaned rows.
- **Client render**: store forward header but render normally for now.

## Tests / Validation
- Server test: forward two messages from chat A to chat B, header on.
  - Assert new messages exist, `fwd_from` set, media cloned (new IDs), updates returned.
- Server test: header off -> no `fwd_from`.
- Client smoke: forward single message iOS/mac; ensure no crashes and message shows.

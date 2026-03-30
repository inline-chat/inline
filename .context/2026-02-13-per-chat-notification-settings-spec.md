# Per-Chat Notification Settings Spec (2026-02-13)

## Goal

Let users define per-chat notification settings (DMs/threads) that can differ from global settings. Default remains inherited from global when no per-chat setting is set.

## Current State (Verified)

- Global notification mode is stored in encrypted `user_settings.general` and applied in push gating:
  - `server/src/db/models/userSettings/types.ts`
  - `server/src/functions/messages.sendMessage.ts`
- Dialogs are already per-user/per-chat and hold other per-chat user state (`archived`, `unreadMark`):
  - `server/src/db/schema/dialogs.ts`
  - `server/src/realtime/encoders/encodeDialog.ts`
- No per-chat notification settings payload exists in DB dialog rows yet.
- Apple currently hydrates many dialogs through legacy REST `getDialogs` / `updateDialog`:
  - `server/src/methods/getDialogs.ts`
  - `server/src/methods/updateDialog.ts`
  - `apple/InlineKit/Sources/InlineKit/DataManager.swift`

## Product Semantics

- Each dialog has optional `notification_settings`.
- If `notification_settings` is unset: use global mode (`UserSettings.notifications.mode`).
- If set: use per-chat mode for that chat.
- Per-chat mode values (v1):
  - `ALL`
  - `MENTIONS`
  - `NONE`
- Explicitly excluded from per-chat settings in v1:
  - `ONLY_MENTIONS`
  - `IMPORTANT_ONLY` / AI gate / zen mode fields
- Urgent nudge bypass remains unchanged.

## Data Model (Server DB)

Add nullable protobuf bytes to `dialogs` (inherit when `NULL`):

- Table: `dialogs`
- Column: `notification_settings`
- Type: `bytea`
- Payload: serialized `DialogNotificationSettings` (proto)
- Nullable: yes (`NULL` = inherit global)

Touchpoints:

- `server/src/db/schema/dialogs.ts`
- Drizzle migration via `cd server && bun run db:generate <name>` then `bun run db:migrate`

## Proto Changes

### `proto/core.proto`

1. Add optional dialog field:
- `optional DialogNotificationSettings notification_settings = 9;`

2. Add new settings object:
- `message DialogNotificationSettings`
  - `optional Mode mode = 1`
  - Mode enum limited to:
    - `MODE_ALL`
    - `MODE_MENTIONS`
    - `MODE_NONE`
    - `MODE_UNSPECIFIED` (meaning unset/default)

3. Add mutation RPC:
- `UPDATE_DIALOG_NOTIFICATION_SETTINGS` to `Method` enum
- `UpdateDialogNotificationSettingsInput`
- `UpdateDialogNotificationSettingsResult`
- wire into `RpcCall` and `RpcResult`

4. Add update type:
- `UpdateDialogNotificationSettings` in `Update.oneof update`
- payload:
  - `Peer peer_id`
  - `optional DialogNotificationSettings notification_settings`

### `proto/server.proto`

Add user-bucket server update variant:

- `ServerUserUpdateDialogNotificationSettings`
  - `Peer peer_id`
  - `optional DialogNotificationSettings notification_settings`
- Add to `ServerUpdate.oneof update`

Regenerate protocol artifacts:

- `bun run generate:proto`

## Server Behavior Changes

### New write path

Add `messages.updateDialogNotificationSettings` function + realtime handler:

- Resolve chat from `InputPeer`.
- Ensure caller has access.
- Update `dialogs.notification_settings` for `(chat_id, user_id)`:
  - store protobuf bytes when mode is set
  - set `NULL` when reset to inherit
- No-op if unchanged.

Emit both:

- realtime update to current user sessions (skip initiating session)
- user-bucket persisted update for catch-up

Touchpoints:

- `server/src/functions/messages.updateDialogNotificationSettings.ts` (new)
- `server/src/realtime/handlers/messages.updateDialogNotificationSettings.ts` (new)
- `server/src/realtime/handlers/_rpc.ts`
- `server/src/functions/_functions.ts`
- `server/src/modules/updates/sync.ts` (inflate user update -> core update)

### Read/encode path

Include `notification_settings` in dialog encoders:

- `server/src/realtime/encoders/encodeDialog.ts`

Do not modify deprecated `ApiDialog` / REST dialog payloads.

### Notification evaluation path

Use per-chat effective mode in push decisioning:

1. Compute global mode exactly as today (including legacy `disableDmNotifications` mapping).
2. Read dialog `notification_settings` for target `(chatId, userId)`.
3. Effective mode = per-chat mode if present else global.
4. Use effective mode in:
   - mention/none/all gating
   - keep existing global important-only behavior when no per-chat setting is present

Touchpoints:

- `server/src/functions/messages.sendMessage.ts`
- optional helper module for mode resolution to keep logic centralized

## Client Changes

## Apple (InlineKit + iOS/macOS UI)

### Models / local DB

Add `notificationSettings` (per-chat protobuf-mapped model) to dialog and persist locally:

- `apple/InlineKit/Sources/InlineKit/Models/Dialog.swift`
- `apple/InlineKit/Sources/InlineKit/Database.swift` (append migration at end)

### Realtime updates

Handle new update kind by mutating local dialog:

- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift`
- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift` (bucket classification/processing)

### Mutation call

Add new RealtimeV2 transaction:

- `apple/InlineKit/Sources/InlineKit/Transactions2/UpdateDialogNotificationSettingsTransaction.swift` (new)
- register in `TransactionTypeRegistry.swift`

### UI

Add per-chat control only in:

- macOS:
  - chat toolbar menu (`MainToolbar` / `ChatToolbarMenu`)
  - Chat Info (`Views/ChatInfo/ChatInfo.swift`)
- iOS:
  - Chat Info (`Features/ChatInfo/ChatInfoView.swift`)

Do not add per-chat notification controls to nav bars.

UI options for v1:

- `Use Global` (clear per-chat setting)
- `All`
- `Mentions`
- `None`

## Backward Compatibility

- Existing users: all dialogs remain `NULL` `notification_settings` -> behavior unchanged.
- Older clients ignore new proto fields/updates.
- Server remains compatible with clients that never set per-chat overrides.

## Rollout Plan

1. Ship DB migration + proto.
2. Ship server mutation + effective mode logic + user-bucket inflate.
3. Ship Apple model/update handling.
4. Enable UI mutation controls in macOS toolbar, macOS Chat Info, iOS Chat Info.

## Tests

### Server

- New function tests:
  - set `notification_settings`
  - clear to inherit
  - no-op on unchanged payload
  - invalid mode
  - invalid peer / access denied
- `updates.getUpdates` inflation test for `userDialogNotificationSettings`.
- New notification decision tests used by `messages.sendMessage` logic covering combinations:
  - global none + chat all -> notify
  - global all + chat none -> suppress
  - global onlyMentions + chat mentions -> DM behavior follows mentions
  - mention/reply/nudge/urgent nudge permutations

### Apple

- Dialog model decode/encode roundtrip for per-chat settings.
- Update application test for new update kind.
- Sync user-bucket catch-up applies new update kind.

## Production Readiness

Ready after:

- migration applied,
- notification decision tests pass,
- Apple local migration verified on upgrade path,
- multi-session sync verified (change on one device updates others).

Main risk is mode-resolution drift between global and per-chat settings; mitigate by centralizing effective-mode calculation in one server helper.

# Persist translation enabled per dialog (backend + sync)

## Goal
Persist per-user translation enabled state for a dialog in the backend, sync it across devices, and avoid overriding existing local preferences on rollout.

## Current state
- Translation enabled is client-only, stored in `UserDefaults` per peer (see `apple/InlineUI/Sources/Translation/TranslationState.swift`).
- Backend stores message translations only (table `message_translations`), not a per-dialog preference.

## Proposed backend changes
### Data model
- Add nullable fields on `dialogs`:
  - `translation_enabled` (bool, nullable)
  - `translation_enabled_updated_at` (timestamp with ms precision)

Rationale: per-user per-chat state belongs on `dialogs` (already per-user per-chat).

### API/proto
- Add optional fields to `Dialog` in `proto/core.proto`:
  - `optional bool translation_enabled = ...;`
  - `optional int64 translation_enabled_updated_at = ...; // unix seconds`
- Add corresponding fields to `TDialogInfo` in `server/src/api-types/api-schema.ts`.
- Regenerate protos after schema changes.

### Server write path
- Extend `updateDialog` to accept `translationEnabled` (optional).
- When provided, set `translationEnabledUpdatedAt = now` in DB.
- Return updated dialog with the new fields.

### Realtime sync
- Add a new user-bucket update in `proto/server.proto` (similar to `user_dialog_archived`):
  - `ServerUserUpdateDialogTranslation` with `peer_id`, `translation_enabled`, `updated_at`.
- In `server/src/modules/updates/sync.ts`, convert to a new `UpdateDialogTranslation` in `proto/core.proto`.
- Push realtime updates from `updateDialog` (same pattern as `dialogArchived`).

## Client sync strategy (last-write-wins)
### Local storage
- Keep local `translationEnabled` and a local `changedAt` (e.g. `translation_enabled_changed_at_<peer>`).

### Merge rules
- If server field is `null`: **do not override** local value.
- If server has value and `local_changed_at <= server_updated_at`: apply server value + update local changedAt.
- If `local_changed_at > server_updated_at`: keep local and call `updateDialog` to push the newer local value to server.

### When to write server
- Only when the user explicitly toggles translation.
- If local is newer than server (per rule above), also write server.

## Rollout plan (avoid overriding existing device state)
- Keep server fields nullable and default to `NULL` for existing rows.
- **Do not backfill** on upgrade.
- First device that toggles after upgrade becomes the initial server source of truth.
- Until server has a value, each device keeps its own local preference.

This prevents “iOS enabled, macOS disabled” from clobbering each other on rollout.

## Open questions
- Should we expose a “Sync translation across devices” UI toggle? (Optional)
- Do we need to include preferred target language in the same schema in the future?

## Implementation checklist
- [ ] DB migration: add columns to `dialogs`
- [ ] Schema update: `server/src/db/schema/dialogs.ts`
- [ ] Proto updates: `proto/core.proto`, `proto/server.proto`
- [ ] API schema: `server/src/api-types/api-schema.ts`
- [ ] `updateDialog` handler: accept + persist + push updates
- [ ] Update encoders to include new fields
- [ ] Client merge logic + storage for `changedAt`

# Linear integration end-to-end review (OAuth -> team selection -> create issue -> attachment updates)

Date: 2025-12-12

This doc is a thorough review of the Linear integration flow and the root cause for:

- "After Linear issue is created, no update is transferred and nothing shows on message."

It also documents what was fixed, what is still legacy/brittle, and what to verify.

---

## High-level architecture (what needs to work)

For the UI to show "Linear issue created" *and* render an attachment on the message, the system must complete:

1. OAuth connect Linear for a specific space (space-scoped token storage).
2. Pick and save a default Linear team for that space (`linear_team_id`).
3. User triggers "Create Linear Issue" on a message.
4. Server creates the issue in Linear (AI-generated title/description + labels + optional assignee).
5. Server persists a task + attachment in DB referencing the correct message row.
6. Server pushes `UpdateMessageAttachment` realtime update to all relevant recipients.
7. Clients apply the update:
   - store `ExternalTask` + `Attachment` locally (keyed by message client `globalId`)
   - refresh message UI using the update, not via a refetch.

If any one of these steps is broken, users can see "issue created" but no attachment appears.

---

## Symptom and root cause (why "created" but nothing shows)

### Root cause 1: wrong DB FK when inserting the attachment

On the server, `message_attachments.message_id` references `messages.global_id` (a global row id), not the per-chat `messages.message_id`.

The broken behavior was inserting `message_attachments.message_id` using the per-chat `messageId`, which often results in:

- attachment insert failing (FK mismatch) OR
- attachment existing but not joinable when reading message history

Fix: `server/src/methods/createLinearIssue.ts` now fetches the message row and uses `message.globalId` for the attachment FK.

Key line: `server/src/methods/createLinearIssue.ts:344`

### Root cause 2: no realtime update push (clients rely on updates)

Even when the external task existed, the client UI relies on realtime `UpdateMessageAttachment` to render immediately. The old/legacy push logic was effectively a no-op and did not send `UpdateMessageAttachment` for Linear create.

Fix: `server/src/methods/createLinearIssue.ts` now pushes `UpdateMessageAttachment` via `encodeMessageAttachmentUpdate` + `RealtimeUpdates.pushToUser`.

Key line: `server/src/methods/createLinearIssue.ts:525`

---

## Protocol + DB semantics (important to keep straight)

### Server DB identifiers

- `messages.message_id` (int): per-chat sequence id (what UI calls "messageId").
- `messages.global_id` (bigint): unique DB row id (what iOS/macOS store as `Message.globalId`).

### Attachments schema

Server:

- `message_attachments.message_id` references `messages.global_id`.
- `message_attachments.id` is the attachment row id.
- `external_tasks.id` is the external task row id.

Client (InlineKit):

- local `Attachment.messageId` references local `Message.globalId` (matches server).
- local `Attachment.attachmentId` is the protocol `MessageAttachment.id`.

### `MessageAttachment.id` meaning (protocol)

In message history encoding, attachments are encoded using the `message_attachments.id` as `MessageAttachment.id`.

Therefore, realtime `UpdateMessageAttachment` should use:

- `UpdateMessageAttachment.attachment.id == message_attachments.id`

If realtime updates instead send `external_tasks.id` as the attachment id, deletion and dedupe will break.

Fixes applied:

- Linear create now sends `message_attachments.id` (already done).
- Notion create update was corrected to send `message_attachments.id`.
- Client update-apply was hardened to delete using `attachmentId` with a legacy fallback.

---

## End-to-end flow: OAuth connect + team selection

### Connect flow (macOS/web -> server -> Linear)

Routes:

- `GET /integrations/linear/integrate?token=...&spaceId=...`
- `GET /integrations/linear/callback?code=...&state=...`

Server implementation:

- `server/src/controllers/integrations/integrationsRouter.ts`
  - sets short-lived cookies: `token`, `state`, `spaceId`
  - redirects to Linear OAuth URL (`actor=app` is set; issues appear as the app)
  - callback validates:
    - cookies exist
    - query `state` matches cookie `state`
    - the token decodes to a user who is `spaceAdmin` for `spaceId`
  - clears cookies on completion and redirects to `in://integrations/linear?success=...`

Space-scoped token storage:

- `server/src/controllers/integrations/handleLinearCallback.ts`
  - upserts `integrations` row by `(space_id, provider)` (unique index)

Key hardening now present:

- CSRF/state validation (previously missing)
- server-side admin enforcement for integrate + callback (previously UI-only)
- explicit failure redirects instead of silently logging and returning undefined

### Team selection flow (required for deterministic issue creation)

Linear requires `teamId` when creating an issue. Inline stores a per-space selection:

- `integrations.linear_team_id`

Endpoints:

- `GET /v1/getLinearTeams?spaceId=<id>` (member-only)
  - `server/src/methods/linear/getLinearTeams.ts`
- `GET /v1/saveLinearTeamId?spaceId=<id>&teamId=<id>` (admin-only)
  - `server/src/methods/linear/saveLinearTeamId.ts`

Important behavioral change:

- Issue creation now requires a saved team id.
- The server no longer silently falls back to the first available team.

Implementation:

- `server/src/libs/linear/index.ts` now supports `getLinearTeams({ requireSavedTeam: true })`
- `server/src/methods/createLinearIssue.ts` returns failure if no saved team

---

## End-to-end flow: Create Linear issue -> attachment -> realtime update -> UI

### Client entry points (apple)

iOS:

- `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`
  - thread: requires `hasLinearConnected` and `linearTeamId` before calling create
  - DM: asks user to pick a space that has Linear connected; then requires per-space `linearTeamId`
  - treats `link == nil` as failure now (no success toast without a link)

macOS:

- `apple/InlineMac/Views/Message/MessageView.swift`
  - requires connected + `linearTeamId` now (aligned with iOS)
  - treats `link == nil` as failure now

### Server method

Main method:

- `server/src/methods/createLinearIssue.ts`

Key responsibilities:

- Resolve `spaceId` (prefer `chat.spaceId`; allow explicit `spaceId` for DM mode)
- Enforce membership: `Authorize.spaceMember(spaceId, currentUserId)`
- Build AI prompt context from surrounding messages + participants + workspace users + labels
- Call OpenAI with a structured JSON response (`{ title, description, labelIds, assigneeLinearUserId }`)
- Validate/filter the AI-selected `labelIds` against the fetched Linear label list; retry without assignee/labels if needed
- Call Linear API to create issue
- Note: we intentionally do **not** set Linear `stateId` in `issueCreate` because workflow states are team-scoped and fetching an "unstarted" state without filtering by team can produce a state id that is invalid for the selected team (Linear GraphQL can return `data: null` + `errors[]` in that case).
- Insert `external_tasks` (encrypted title) + `message_attachments` (FK: `messages.globalId`)
- Push realtime update: `UpdateMessageAttachment` with `message_attachments.id`

### Realtime push semantics (DM peer encoding gotcha)

For DMs, the peer shown on each client is "the other user". That means encoding must differ per recipient.

The push implementation mirrors the Loom pattern:

- For the current user recipient: encode with the DM input peer "other user".
- For the other user recipient: encode with the DM input peer "current user".

This prevents clients from applying the update to the wrong dialog/chat view.

Implementation:

- `server/src/methods/createLinearIssue.ts` (dmUsers branch)
- `server/src/methods/notion/createNotionTask.ts` (dmUsers branch)
- `server/src/methods/notion/deleteNotionTask.ts` (dmUsers branch)

### Client apply logic (InlineKit)

`UpdateMessageAttachment` apply pipeline:

- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift`
  - if `attachment.attachment == nil`: treat as deletion
    - primary: delete by `Attachment.attachmentId == update.attachment.id`
    - legacy fallback: delete by `externalTaskId == update.attachment.id`
  - else: save attachment + inner item(s) to DB
    - `Attachment.saveWithInnerItems(db, attachment: update.attachment, messageClientGlobalId: message.globalId)`
  - refresh UI with `MessagesPublisher.shared.messageUpdatedSync`

Local persistence details:

- `Attachment.messageId` stores the message client `globalId` (not per-chat messageId).
- `Attachment.attachmentId` stores the server `message_attachments.id` (protocol `MessageAttachment.id`).

To prevent duplicates from older mismatched ids, `Attachment.saveWithInnerItems` was hardened to dedupe by:

- `(messageId, externalTaskId)` or `(messageId, urlPreviewId)` if `attachmentId` does not match.

File:

- `apple/InlineKit/Sources/InlineKit/Models/Attachment.swift`

---

## Attachment deletion flow (Linear + Notion)

API:

- `POST /v1/deleteAttachment` (historically named for Notion)
  - server handler is `server/src/methods/notion/deleteNotionTask.ts`
  - now supports `externalTask.application == "linear"` by calling `deleteLinearIssue(...)`

Important correction:

- Clients should rely on realtime updates to remove attachments locally.
  - Previously, `DataManager.deleteAttachment(...)` optimistically deleted local rows using the wrong message id key (messageId vs globalId), leaving broken local state.
  - Now `DataManager.deleteAttachment(...)` does not mutate local DB up-front; it calls the API and waits for realtime deletion update to reconcile state.

File:

- `apple/InlineKit/Sources/InlineKit/DataManager.swift`

Known gap (still worth fixing):

- Deleting from the external service uses `chat.spaceId` to find the integration token.
- For DM-mode tasks created "in a space", the chat itself may not have a `spaceId`, so the server may not be able to delete from Linear/Notion even though it can detach locally.
  - Suggested fix: store `spaceId` on the task or attachment row, or include `spaceId` in the delete request and authorize membership/admin appropriately.

---

## Space settings UI removal (macOS)

Goal: remove the "Space Settings" UI and keep only "members", "invite", "integrations" in the sidebar menus.

Changes:

- Removed "Space Settings" from the plus menu:
  - `apple/InlineMac/Views/Sidebar/MainSidebar/SpaceSidebar.swift`
- Removed the `Nav.Route.spaceSettings` route and its handler:
  - `apple/InlineMac/App/Nav.swift`
  - `apple/InlineMac/Views/Main/ContentView.swift`

Space members action menu already contains the desired items:

- `apple/InlineMac/Views/Sidebar/SpaceMembersView.swift`

---

## Logging and troubleshooting checklist

If "issue created" but no attachment appears, check these logs:

Server:

- Linear create start / context:
  - "Starting Linear issue creation"
  - "Fetched Linear issue context"
- AI + Linear API:
  - "Generating Linear issue title via OpenAI"
  - "Linear issue created"
- DB:
  - "Created Linear external task record"
  - "Created message attachment row for Linear external task"
- Realtime:
  - "Pushing messageAttachment update for Linear external task"
- OAuth:
  - "Starting Linear OAuth integrate"
  - "Linear OAuth callback state mismatch"
  - "Linear OAuth callback succeeded"

Client (InlineKit):

- Realtime apply:
  - "Saved message attachment ..."
  - "Deleted attachment ..."

Manual verification steps:

1. Connect Linear in a space (admin required).
2. Select default Linear team for that space.
3. Create issue from a message:
   - confirm server logs show attachment insert using `message.globalId`
   - confirm server logs show "Pushing messageAttachment update ..."
4. Confirm client receives and applies update without refetch:
   - attachment row is stored with `Attachment.messageId == Message.globalId`
   - `Attachment.attachmentId == message_attachments.id`

---

## Legacy/no-op/brittle pieces (what was cleaned up or called out)

- Legacy iOS Linear create helper in `apple/InlineIOS/Features/Message/UIMessageView.swift`:
  - referenced global Settings path, used debug prints, and did not respect space/team gating
  - removed

- Older update behavior mismatched ids:
  - Notion create update used `externalTask.id` as `MessageAttachment.id` (now corrected)
  - client deletion apply assumed `attachment.id` was `externalTaskId` (now corrected with a legacy fallback)

- OAuth was previously missing `state` validation and relied on UI for admin permissions:
  - now validated and enforced server-side

---

## Follow-ups (recommended)

- Fix external-service deletion for DM-created tasks (needs a reliable `spaceId` source).
- Decide whether `createLinearIssue` should return structured errors instead of `{ link: undefined }` so clients can show specific failure reasons.
- Ensure web client (if applicable) uses the same attachment update semantics and gating logic.

---

## Update (post-review fixes applied): 2025-12-12

This repo changed after the initial review; the following production blockers were found and fixed.

### Fixed: Linear deletion actually calls the GraphQL API correctly

Bug: `deleteLinearIssue(...)` used a GraphQL query with `$id` but the helper did not send GraphQL variables, so Linear deletions would never succeed.

Fix:

- `server/src/libs/linear/index.ts`:
  - `queryLinear(...)` now accepts optional `variables` and includes them in the GraphQL request body.
  - `deleteLinearIssue(...)` now passes `variables: { id: issueId }`.

Impact:

- `/v1/deleteAttachment` can now delete Linear issues (when `chat.spaceId` is available).

### Fixed: Linear OAuth callback no longer reports success when DB upsert fails

Bug: `handleLinearCallback` caught DB insert/upsert errors and still returned `{ ok: true }`. This could show “Connected” in clients even though no integration row was saved.

Fix:

- `server/src/controllers/integrations/handleLinearCallback.ts`:
  - DB upsert errors are logged via `Log.shared.error(...)` (so Sentry captures it).
  - The handler returns `{ ok: false, error: "Failed to save Linear integration" }` on persistence failure.

### Improved: OAuth error propagation to clients (and UI surfaces it)

Improvement:

- `server/src/controllers/integrations/integrationsRouter.ts` now redirects to:
  - `in://integrations/linear?success=false&error=<encoded>`
  instead of always using the generic `callback_failed`.
- `apple/InlineMac/Views/SpaceSettings/IntegrationCard.swift` now reads the `error` query param and shows it inline when connect fails.

### Disabled: macOS global integrations page (space-only)

Inline integrations are space-scoped; macOS should not expose any “global integrations” connect UI.

- `apple/InlineMac/Views/Settings/Views/IntegrationsSettingsDetailView.swift` is now compiled out (`#if false`) to avoid any dormant/accidental navigation to a global integrations screen.

### Validation run

- `cd server && bun run typecheck`
- `cd server && bun test src/__tests__/methods/saveLinearTeamId.test.ts src/__tests__/methods/disconnectIntegration.test.ts`

### Remaining risks / still worth addressing before production

- Migration risk: `server/drizzle/0045_add_integrations_space_provider_unique.sql` will fail if prod has duplicate `(space_id, provider)` rows; dedupe before applying.
- Unrelated but high-risk logging: `server/src/modules/notion/agent.ts` contains a `console.log` that prints prompts/content; remove before production if that file is shipped/enabled.
- Known gap: DM-created tasks may not delete from Linear/Notion because deletion resolves token via `chat.spaceId` (DM chats may not have a `spaceId`); local detach can still work via realtime deletion.

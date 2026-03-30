# Space-level Linear integration + issue creation (Inline)

> Shared-memory doc: update this file whenever you change Linear integration UX/APIs.
> Add an entry under “Changelog” with date (YYYY-MM-DD), what changed, and follow-ups.

This doc summarizes the work done in this branch/worktree related to:

- Space-level integrations UI (macOS) and OAuth callback handling
- Space-level Linear backend integration + team selection APIs
- iOS: disable global Linear connect UI, add "Create Linear Issue" action in message context menu, render Linear attachments similarly to Notion "Will Do"

Date: 2025-12-12

---

## Changelog

- 2025-12-12: Initial space-scoped Linear integration (backend), macOS space integrations UI + OAuth callbacks, iOS menu/attachments.
- 2025-12-12: macOS: expose Linear “Options” (default team selection) from Space Integrations.
- 2025-12-12: Fix Linear create-issue attachment persistence + realtime updates; harden OAuth (state validation + admin enforcement); align attachment update/delete IDs to `message_attachments.id`; macOS menu now shows “Create Linear Issue” immediately (gates on click).

## User-facing behavior

### macOS

- Added per-space Settings and Integrations pages (modeled after iOS but macOS-idiomatic).
  - Space Integrations shows Notion + Linear connect cards.
  - Notion options (database selection) are shown as a SwiftUI sheet.
  - Linear options (default team selection) are shown as a SwiftUI sheet.
- Space members view now has a single ellipsis menu for space actions (invite, manage members, settings, integrations).
- OAuth callbacks for integrations now work on macOS via the `in://` URL scheme.

Notes:

- macOS has a "Create Linear Issue" action in message context menus for space threads (gating/caching details may still need tightening; see TODOs).
- macOS attachment rendering for `ExternalTask` works, but copy is still Notion-specific in some places (see TODOs below).

### iOS

- Global "Integrations" settings entry was removed/disabled (prevents users from hitting the now space-scoped Linear OAuth).
- In a space thread message context menu, a new action appears when Linear is connected:
  - "Create Linear Issue" -> shows a loading toast -> calls `ApiClient.createLinearIssue` -> shows success toast with "Open" action.
- Linear external task attachments render similarly to Notion "Will Do" attachments.

Notes:

- iOS does not yet have a space-level Linear connect UI (only Notion is shown under space integrations on iOS). Users must connect Linear from another client for now (macOS/web) for iOS to enable the menu.

---

## Backend changes (server/)

### Linear OAuth: use app actor

- Linear OAuth authorization URLs now include `actor=app` so created issues appear as the app rather than the user.
  - Implemented in `server/src/libs/linear/index.ts` in `getLinearAuthUrl`.
  - Doc reference: https://linear.app/developers/oauth-actor-authorization
  - Existing tokens remain user-actor until users re-authorize.

### Integrations table hardening

- Added `linear_team_id` to the `integrations` table for space-level team selection.
  - Migration: `server/drizzle/0044_add_linear_team_id.sql`

Why `linear_team_id` is needed:

- Linear issues must be created _in a team_ (the API requires `teamId` when creating an issue).
- A single Linear workspace/org typically has multiple teams, and “which team should Inline file issues into?” is a per-space choice.
- We store the selected Linear team id on the space’s integration row so:
  - issue creation is deterministic (always uses the chosen team),
  - admins can change it later without reconnecting OAuth,
  - and we avoid guessing (e.g. “first team”) which can silently file issues into the wrong team.
- Added a unique index `(space_id, provider)` to enforce one integration row per space/provider.
  - Migration: `server/drizzle/0045_add_integrations_space_provider_unique.sql`
- Linear and Notion OAuth callbacks now upsert on `(spaceId, provider)` to avoid duplicate rows and nondeterministic token selection.
  - `server/src/controllers/integrations/handleLinearCallback.ts`
  - `server/src/libs/notion.ts`

Important migration note:

- If production already has duplicate `(space_id, provider)` rows, the unique index migration will fail. Dedupe before applying `0045_*`.

### Space-level Linear APIs (v1)

Added v1 endpoints to support selecting a Linear team per space:

- `GET /v1/getLinearTeams?spaceId=<id>`
  - Lists available teams for the space's Linear token.
  - `server/src/methods/linear/getLinearTeams.ts`
- `GET /v1/saveLinearTeamId?spaceId=<id>&teamId=<id>`
  - Saves `linear_team_id` on the space's Linear integration row.
  - Admin-only (`Authorize.spaceAdmin`).
  - `server/src/methods/linear/saveLinearTeamId.ts`

Also hardened existing Notion option saving:

- `GET /v1/saveNotionDatabaseId?...`
  - Now admin-only (`Authorize.spaceAdmin`) and removed debug prints.
  - `server/src/methods/notion/saveNotionDatabaseId.ts`

### Linear issue creation is now space-scoped

- `server/src/methods/createLinearIssue.ts` now derives `spaceId` from `chats.spaceId` and requires membership.
  - Requests outside a space (DMs) return `{ link: undefined }`.
- `server/src/libs/linear/index.ts` now fetches Linear tokens via the space integration row.

### Tests / validation done

- Added a backend test for saving Linear team id:
  - `server/src/__tests__/methods/saveLinearTeamId.test.ts`
- Commands run during development:
  - `cd server && bun test src/__tests__/methods/saveLinearTeamId.test.ts`
  - `cd server && bun run typecheck`

---

## Apple client changes

### macOS (apple/InlineMac)

- Added new routes:
  - `Nav.Route.spaceSettings(spaceId:)`
  - `Nav.Route.spaceIntegrations(spaceId:)`
  - Wired in `apple/InlineMac/Views/Main/ContentView.swift`
- Added per-space pages:
  - `apple/InlineMac/Views/SpaceSettings/SpaceSettingsView.swift`
  - `apple/InlineMac/Views/SpaceSettings/SpaceIntegrationsView.swift`
  - `apple/InlineMac/Views/SpaceSettings/IntegrationOptionsView.swift`
  - `apple/InlineMac/Views/SpaceSettings/IntegrationCard.swift`
  - `apple/InlineMac/Views/SpaceSettings/SpaceSettingsViewController.swift`
  - `apple/InlineMac/Views/SpaceSettings/SpaceIntegrationsViewController.swift`
- Space action menu consolidation in space members:
  - `apple/InlineMac/Views/Sidebar/SpaceMembersView.swift` now uses an ellipsis menu containing create/invite/members/settings/integrations.
- macOS URL scheme integration callback handling:
  - `apple/InlineMac/Info.plist` now includes the `in` scheme.
  - `apple/InlineMac/App/AppDelegate.swift` accepts `inline://` and `in://` and posts `.integrationCallback`.
- Added assets used by the macOS integration cards:
  - `apple/InlineMac/Assets.xcassets/linear-icon.imageset`
  - `apple/InlineMac/Assets.xcassets/notion-logo.imageset`

### iOS (apple/InlineIOS)

- Disabled global integrations link in Settings:
  - `apple/InlineIOS/Features/Settings/Settings.swift`
- Added "Create Linear Issue" menu item in message context menus when Linear is connected:
  - `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`
  - Uses existing `ApiClient.createLinearIssue`.
- Updated toast rendering to support `linear-icon` image:
  - `apple/InlineIOS/Utils/ToastView.swift`
- Updated attachment embed copy/icon when the attachment is a Linear external task:
  - `apple/InlineIOS/Features/Message/MessageAttachmentEmbed.swift`

---

## How to verify locally (manual)

### Backend

1. Run migrations:
   - `cd server && bun run db:migrate`
2. Typecheck:
   - `cd server && bun run typecheck`
3. Run focused test:
   - `cd server && bun test src/__tests__/methods/saveLinearTeamId.test.ts`

### macOS app

1. Connect Linear in a space:
   - Space -> Space Settings -> Integrations -> Connect Linear.
2. Confirm the callback returns to the app via `in://integrations/linear?success=true`.
3. Confirm Integrations page shows Linear as connected.

### iOS app

1. Ensure Linear is connected for the space (connect from macOS for now).
2. Open a space thread chat.
3. Long-press a message with text -> context menu should show "Create Linear Issue".
4. Tap it:
   - Should show a progress toast and then a success toast with an "Open" button.
   - A Linear external task attachment should render under the message.

---

## Known issues / TODOs

- iOS Notion gating: `NotionTaskManager.hasAccess` uses `hasIntegrationAccess`, which can be true for Linear-only spaces. The "Will Do" menu may appear even when Notion is not connected.
- iOS space-level Linear connect UI is not implemented yet (only Notion exists under space integrations on iOS).
- macOS "Create Linear Issue" can feel flaky if the menu is opened before the space’s Linear connection state has been fetched/cached.
- macOS `ExternalTaskAttachmentView` copy still references Notion for delete confirmation and uses "will do" phrasing.
- There is an unrelated macOS change in `apple/InlineMac/Views/Message/Media/NewPhotoView.swift`.

---

## Key related files (grouped)

### Server

- `server/src/controllers/integrations/integrationsRouter.ts`
- `server/src/controllers/integrations/handleLinearCallback.ts`
- `server/src/libs/linear/index.ts`
- `server/src/libs/notion.ts`
- `server/src/db/schema/integrations.ts`
- `server/src/db/models/integrations.ts`
- `server/src/methods/getIntegrations.ts`
- `server/src/methods/createLinearIssue.ts`
- `server/src/methods/linear/getLinearTeams.ts`
- `server/src/methods/linear/saveLinearTeamId.ts`
- `server/src/methods/notion/saveNotionDatabaseId.ts`
- `server/src/controllers/v1.ts`
- Migrations:
  - `server/drizzle/0044_add_linear_team_id.sql`
  - `server/drizzle/0045_add_integrations_space_provider_unique.sql`
- Tests:
  - `server/src/__tests__/methods/saveLinearTeamId.test.ts`

### macOS

- `apple/InlineMac/App/AppDelegate.swift`
- `apple/InlineMac/App/Nav.swift`
- `apple/InlineMac/Info.plist`
- `apple/InlineMac/Views/Main/ContentView.swift`
- `apple/InlineMac/Views/Sidebar/SpaceMembersView.swift`
- `apple/InlineMac/Views/Sidebar/MainSidebar/SpaceSidebar.swift`
- `apple/InlineMac/Views/SpaceSettings/*`
- Assets:
  - `apple/InlineMac/Assets.xcassets/linear-icon.imageset`
  - `apple/InlineMac/Assets.xcassets/notion-logo.imageset`

### iOS

- `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`
- `apple/InlineIOS/Features/Message/MessageAttachmentEmbed.swift`
- `apple/InlineIOS/Utils/ToastView.swift`
- `apple/InlineIOS/Features/Settings/Settings.swift`

# Notion Authenticated URL Previews Plan

Date: 2026-06-02

## Goal

Add authenticated Notion URL previews for pages, databases, data sources, file/media blocks, and file properties while preserving the existing message attachment model and keeping provider-specific logic outside the main server package. The design should make future providers like Linear, Sentry, Figma, GitHub, and others straightforward to add without weakening URL-fetching safety.

## Current Shape

- Message attachments already support `UrlPreview` through `MessageAttachment.url_preview`.
- `server/src/functions/messages.sendMessage.ts` detects up to 3 preview URLs and starts async preview processing after the message update is pushed.
- `server/src/modules/urlPreview/processUrlPreview.ts` owns the current generic preview pipeline:
  - global preview cache by normalized URL
  - image download and photo upload
  - DB insert into `url_preview` and `message_attachments`
  - update publication through `UpdateMessageAttachment`
- `packages/url-preview` already holds the generic URL preview implementation and safety filters outside the server package.
- `packages/url-preview/src/filters.ts` intentionally blocks protected hosts like `notion.so`, `notion.site`, `linear.app`, and `sentry.io` from unauthenticated generic fetching.
- The server already has Notion OAuth and a space-scoped integration row with encrypted tokens, plus Notion task code using the newer data source model in `server/src/modules/notion`.

## Notion API Facts To Design Around

From the current official Notion docs:

- The latest Notion API version is `2026-03-11`.
- Since API version `2025-09-03`, databases and data sources are split. A database contains child `data_sources`; data source properties live on the data source object.
- `Retrieve a page` returns page properties, not page content. Page content must be fetched with `Retrieve block children`.
- `Retrieve block children` only returns the first level of block children and requires read content capabilities.
- Notion file objects can appear in page covers/icons, blocks, and `files` properties. Notion-hosted file URLs are temporary signed URLs that expire after about 1 hour, so they should not be persisted as client-facing media URLs.
- Notion returns 403 for missing capabilities and 404 when the object is missing or the connection does not have access.

References:

- https://developers.notion.com/reference/data-source
- https://developers.notion.com/reference/database
- https://developers.notion.com/reference/retrieve-a-page
- https://developers.notion.com/reference/get-block-children
- https://developers.notion.com/guides/data-apis/retrieving-files

## Product/Security Decisions

1. Keep Notion under the existing URL preview attachment, not a new attachment oneof.
   - Use `UrlPreview.provider = "notion"`.
   - Use generic fields for clients: `site_name`, `title`, `description`, `media_type`, `photo`, `display_url`, `author`, and `layout`.
   - Add only small generic fields if client rendering really needs them, such as `provider_resource_type` with values like `notion.page`, `notion.database`, `notion.data_source`, `notion.file`, `linear.issue`.

2. Do not relax the generic URL preview filters.
   - `notion.so` and `notion.site` should stay blocked in unauthenticated generic fetching.
   - Authenticated provider previews use a separate provider path with explicit host allowlists and credentials.

3. V1 should use space-level Notion integrations for space chats.
   - This matches the existing integration model and avoids leaking a user's private token-derived metadata into a space by surprise.
   - User-level tokens can be added after the permission UX is explicit. For DMs/self chats, user-level token support is reasonable once the credential model supports user-owned connections.

4. Preview metadata is shared with everyone who can read the Inline message.
   - If a space-level Notion token can access a page and a user posts that URL into a space chat, the resulting title/summary/media is part of the message.
   - Do not include sensitive property values by default. Keep descriptions bounded and prefer structural summaries.

5. Never persist Notion signed file URLs as preview media.
   - For Notion file objects, use names/counts/types in text metadata.
   - For icons/covers/images, optionally download the temporary image server-side within strict byte/type limits and store it as an Inline `Photo`, same as the generic preview image path.
   - Do not import arbitrary Notion files as Inline documents in v1.

## Package Boundary

Keep the server as the orchestrator only. Provider-specific logic should live in workspace packages.

Recommended package shape:

```text
packages/url-preview/
  src/public-preview/       # existing generic HTML/OpenGraph/YouTube/Loom flow
  src/auth-preview/
    types.ts                # provider interface and result schema
    registry.ts             # build-time provider registry
    safety.ts               # shared host allowlists, result sanitizer, request limits
    providers/notion.ts     # Notion deterministic API parser/fetcher

server/src/modules/urlPreview/
  processUrlPreview.ts      # orchestration, DB insert, update publication
  credentials.ts            # server-only integration token lookup/decrypt
  persistence.ts            # shared UrlPreviewResult -> url_preview row conversion
```

Alternative if we want cleaner naming later:

- Create `packages/link-preview-core` and move current `packages/url-preview` into it.
- Add provider packages such as `packages/link-preview-notion`, `packages/link-preview-linear`.
- This is cleaner for external package authors, but it is more churn than necessary for Notion v1.

The minimal-change path is to keep `@inline-chat/url-preview` and add authenticated provider support there.

## Provider Interface

The provider interface should be deterministic and server-agnostic:

```ts
export type PreviewAuthScope =
  | { type: "space"; spaceId: number }
  | { type: "user"; userId: number }

export type PreviewCredential = {
  provider: string
  accessToken: string
  scopes?: readonly string[]
  externalWorkspaceId?: string
}

export type AuthPreviewContext = {
  url: string
  normalizedUrl: string
  scope: PreviewAuthScope
  credential: PreviewCredential
  fetch: SafeProviderFetch
  limits: PreviewLimits
  now: Date
}

export type AuthenticatedPreviewProvider = {
  provider: string
  protectedHosts: readonly string[]
  canHandle(url: URL): boolean
  resolve(ctx: AuthPreviewContext): Promise<UrlPreviewResult | null>
}
```

Rules:

- Providers do not import `server/src`, Drizzle, encryption, or update publishing.
- Providers do not receive DB handles.
- Providers receive a safe fetch wrapper, not raw unconstrained network access.
- Providers return the same `UrlPreviewResult` shape as public previews, plus optional generic provider resource metadata if added.
- Providers must redact or omit tokens and raw response payloads from thrown errors.

## Safe Provider Fetch

`SafeProviderFetch` should enforce security centrally:

- HTTPS only.
- Host allowlist per provider.
- No redirects outside provider allowlist.
- Timeout and max response bytes.
- JSON-only for API fetches unless the provider explicitly declares allowed content types.
- Global and provider-specific concurrency limits.
- Per-space/provider rate limits.
- Sanitized request logging with no authorization header values.

For Notion v1:

- Allow only `api.notion.com`.
- Do not let the Notion provider fetch arbitrary URLs from Notion response payloads.
- For image cover/icon download, use the existing public `fetchBinary` path with current URL safety checks and byte/type bounds, or a separate "download temporary Notion file image" helper that only accepts Notion file objects and stores the bytes immediately as an Inline photo.

## Credential Model

Current table:

- `integrations` has `space_id`, `user_id`, `provider`, encrypted token columns, plus provider-specific fields like `notion_database_id` and `linear_team_id`.

Target model:

```text
integration_connections
  id
  provider
  owner_type              -- "space" | "user"
  owner_space_id
  owner_user_id
  created_by_user_id
  access_token_encrypted
  access_token_iv
  access_token_tag
  refresh_token_encrypted
  refresh_token_iv
  refresh_token_tag
  token_expires_at
  scopes_json
  external_workspace_id
  external_user_id
  status                  -- "active" | "revoked" | "error"
  last_checked_at
  created_at
  updated_at
  revoked_at

integration_settings
  id
  connection_id
  key
  value_json_encrypted?   -- or typed columns for common settings
```

Migration strategy:

- Keep `integrations` for existing Notion/Linear code during v1 if necessary.
- Add a server-only `CredentialResolver` that can read old rows now and new rows later.
- Move `notion_database_id` and `linear_team_id` toward provider settings instead of keeping provider-specific columns on the shared credential row.
- Rename `encryptLinearTokens`/`decryptLinearTokens` to provider-neutral token helpers before adding more providers.

Credential resolution rules:

- Space chat: prefer active space-owned provider connection for the chat's `spaceId`.
- DM/self chat: allow active user-owned connection for the sender only after explicit product/UX decision.
- If no usable credential exists, do not create a preview and do not fall back to generic fetching for protected hosts.
- If the token returns 401/403/404, do not publish a partial preview. Log sanitized provider/status metadata only.

## Data Model For Previews

Use existing `url_preview` for persisted message previews.

Recommended additions:

```text
url_preview
  provider_resource_type text nullable
  provider_resource_id_hash bytea nullable
  auth_scope_type text nullable      -- null | "space" | "user"
  auth_scope_id bigint nullable
  fetched_at timestamp nullable
  expires_at timestamp nullable
```

Notes:

- `provider_resource_id_hash` allows dedupe/debug without exposing Notion object IDs.
- `auth_scope_*` is for audit/debug/cache invalidation, not client rendering.
- `expires_at` matters for previews that should be refreshed, but v1 can keep sent previews immutable.

Do not use the existing global `url_preview_cache` for authenticated provider previews. It is keyed only by URL and is unsafe for private metadata.

V1 cache recommendation:

- No DB cache for authenticated previews.
- Optional in-memory dedupe for concurrent identical `(provider, scope, normalizedUrl)` jobs.

V1.1 scoped cache option:

```text
authenticated_url_preview_cache
  id
  provider
  scope_type
  scope_id
  url_hash
  provider_resource_id_hash
  metadata_encrypted
  metadata_iv
  metadata_tag
  fetched_at
  expires_at
  last_used_at
```

Only add this if Notion rate limits become a real issue.

## Message Send Flow

Keep the current async attachment update behavior.

New flow:

1. `sendMessage` extracts preview URLs as it does today.
2. `processUrlPreviews` classifies each URL:
   - public URL: existing `fetchUrlPreview` path.
   - protected provider URL: authenticated provider path.
   - blocked/sensitive URL: no preview.
3. Auth provider path:
   - Determine chat scope and provider from URL.
   - Resolve credential for `(provider, scope)`.
   - Call provider through safe fetch.
   - Sanitize and bound the result.
   - Convert result to `url_preview` row.
   - Insert `message_attachments` row.
   - Publish `UpdateMessageAttachment`.
4. Keep the message `hasLink` flag true when a protected URL is present even if no preview is created.

## Notion URL Classification

Accept only Notion web hosts:

- `notion.so`
- `www.notion.so`
- `notion.site`
- subdomains under `notion.site` only if we deliberately support public Notion sites in the authenticated provider path

Parse IDs conservatively:

- Extract UUID-like 32-hex or dashed UUID IDs from URL path/query.
- Strip workspace slug/title prefixes.
- Do not trust query params with sensitive names.
- If no stable Notion ID can be extracted, skip authenticated preview.

Classify using API attempts rather than URL shape alone:

1. Try `pages.retrieve(page_id)`.
2. If page retrieval fails with object-not-found, try `databases.retrieve(database_id)` for database URLs.
3. If database retrieval succeeds and returns data sources, preview the database.
4. If an explicit data source ID is detected or copied, try `dataSources.retrieve(data_source_id)`.
5. For file/media blocks, try `blocks.retrieve(block_id)` and, if needed, block children for page content.

Use a shared Notion API version constant: `2026-03-11`.

## Notion Preview Content V1

Page preview:

- `siteName`: `Notion`
- `provider`: `notion`
- `providerResourceType`: `notion.page`
- `title`: page title property or title block fallback
- `description`: bounded summary from safe properties:
  - parent type/name when cheap
  - last edited date
  - first 1-3 text blocks from `blocks.children.list(page_size: small)` if read content is allowed
  - file count if file properties exist
- `photo`: page cover or image icon only if downloaded and stored safely; emoji icon may be folded into title/description until protocol has icon metadata.
- `mediaType`: `article` unless primary content is a file/image.

Database preview:

- Use latest database/data source split.
- `providerResourceType`: `notion.database`
- `title`: database title.
- `description`: count/list child data sources, inline/full-page hint, last edited date.
- `photo`: cover/icon when safe.
- `mediaType`: `article` or `embed`; probably `article` for v1.

Data source preview:

- `providerResourceType`: `notion.data_source`
- `title`: data source title/name.
- `description`: property count plus a bounded list of visible property names/types.
- Do not query rows in v1 unless needed; if later we query rows, keep `page_size` very small.

File/media preview:

- `providerResourceType`: `notion.file`
- `title`: file name when available.
- `description`: file type/source and parent page if cheap.
- For image/pdf/file/video/audio blocks, show metadata only.
- Do not persist signed Notion file URLs.
- Do not download arbitrary documents in v1.
- For image-like file blocks, optionally import a thumbnail/photo only within the same strict image limits used by generic previews.

## Client Behavior

No required client change for v1 if we stay within existing `UrlPreview` fields.

Potential small UI follow-up:

- Show provider label/icon based on `provider == "notion"`.
- If `provider_resource_type` is added, choose badge text:
  - `Page`
  - `Database`
  - `Data source`
  - `File`
- Keep rendering lightweight. Message views should not fetch Notion directly.

## Tests

Package tests in `packages/url-preview`:

- Notion URL ID parsing for common page/database/data-source/file/block URLs.
- Notion provider maps page/database/data-source/file API responses to bounded `UrlPreviewResult`.
- Notion provider does not include signed file URLs in returned media.
- Safe fetch blocks non-Notion hosts and redirects.
- Provider errors redact tokens.

Server tests:

- Protected Notion URL with no integration creates no attachment and does not generic-fetch.
- Space chat with Notion integration creates a `url_preview` attachment with `provider = notion`.
- Wrong space/no chat access cannot use another space's token.
- 403/404/401 from Notion creates no preview and logs sanitized status.
- Authenticated previews never use global `url_preview_cache`.
- Sent message update arrives before attachment update.
- Existing public URL preview tests still pass.

Manual checks:

- Send a public URL and verify old previews still work.
- Send a Notion page URL in a space with no token: message sends, no preview.
- Connect Notion to a space and send page/database/data-source/file URLs: preview attaches asynchronously.
- Revoke Notion access and verify previews stop silently without blocking send.

## Rollout

Phase 1: Abstraction and safety

- Add authenticated provider types/registry/safe fetch in `packages/url-preview`.
- Add server `CredentialResolver` adapter.
- Split current `processUrlPreview` into public-preview and persistence helpers without behavior change.
- Add tests proving protected hosts still do not generic-fetch.

Phase 2: Notion provider

- Implement Notion URL parser and deterministic API calls with `Notion-Version: 2026-03-11`.
- Use existing space-scoped Notion OAuth credentials.
- Map Notion responses to current `UrlPreview` fields.
- No authenticated DB cache in v1.

Phase 3: Optional protocol polish

- Add `provider_resource_type` to `UrlPreview` if client badges are worth it.
- Regenerate protobufs and update Apple renderers only for badge/icon display.

Phase 4: Credential model cleanup

- Add generic `integration_connections` and migrate old `integrations` rows.
- Move provider settings out of shared credential columns.
- Rename token encryption helpers to provider-neutral names.

Phase 5: Future providers

- Add Linear/Sentry/Figma provider packages against the same interface.
- Each provider declares:
  - protected hosts
  - required credential owner types
  - allowed API hosts
  - result mapping
  - redaction tests

## Open Questions

- Should user-owned Notion tokens ever auto-preview links in group/space chats, or only in DMs/self chats?
- Should posting a private provider URL show a small "preview generated from space Notion access" indicator in clients?
- Do we want immutable previews forever, or should authenticated previews refresh on edit/webhook when provider metadata changes?
- Should Notion image covers/icons be imported as Inline photos in v1, or should v1 be text-only for private content?

## Recommended V1

Implement authenticated Notion previews as `UrlPreview` attachments with `provider = "notion"`, using only space-level tokens and no authenticated DB cache. Keep Notion logic in `packages/url-preview`, enforce provider fetch safety centrally, and keep server changes limited to credential resolution, orchestration, persistence, and update publication.

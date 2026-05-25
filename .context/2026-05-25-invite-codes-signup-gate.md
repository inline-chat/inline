# Invite Codes Signup Gate Plan

## Goal

Make Inline publicly downloadable while keeping first-time signup gated by invite codes. Existing users must keep logging in normally. Every new real user should receive a small invite allowance, admins should be able to add more for one user or all users later, and the database should be directly operable for emergency/manual grants.

## Current Auth Shape

- Public email auth is in `server/src/methods/sendEmailCode.ts` and `server/src/methods/verifyEmailCode.ts`.
- `sendEmailCode` is open and only sends an OTP plus `challengeToken`.
- `verifyEmailCode` verifies the OTP, then creates the user if missing in `getUserByEmail`.
- Existing user detection treats `pendingSetup === true` as not an existing user.
- Space invites can pre-create `users` rows with `pendingSetup: true` via `UsersModel.createUserWhenInvited`.
- Admin user management already exists in `server/src/controllers/admin.ts`; user detail/update endpoints require setup completion and step-up for writes.
- Drizzle schema lives in `server/src/db/schema`; migrations should be generated with `bun run db:generate <name>` from `server/`.

## Product Rules

1. Existing users can log in without an invite code.
2. New public users must supply a valid invite code when verifying their email code.
3. Pending setup users created through a space invite should be allowed to finish signup without an app invite code, because the space invite is already an invitation.
4. A consumed invite code creates exactly one new real user.
5. Each new real user receives a default grant, proposed default: `3` available invites.
6. Admin can grant additional invites to a single user.
7. Admin can bulk grant additional invites to all eligible non-deleted, non-bot users.
8. Invite codes should be manually creatable/queryable from the database without app code changes.
9. Invite codes should not store raw random secrets as the primary verifier.

## Proposed Data Model

Add `server/src/db/schema/inviteCodes.ts` and export it from `schema/index.ts`.

`invite_codes`

- `id serial primary key`
- `code_hash text not null unique`
- `code_prefix varchar(12) not null`
- `created_by_user_id integer references users(id)`
- `owner_user_id integer references users(id)`  
  The user whose invite allowance produced this code. Null for admin/system seeded codes.
- `redeemed_by_user_id integer references users(id) unique`
- `redeemed_email varchar(256)`
- `redeemed_at timestamp`
- `expires_at timestamp`
- `disabled_at timestamp`
- `note text`
- `date timestamp default now()`

Indexes:

- unique index on `code_hash`
- index on `owner_user_id`
- index on `redeemed_by_user_id`
- partial/regular index for active code lookup can be omitted at first because verification is by hash; add if admin lists/searches grow.

Add invite allowance to `users`:

- `invite_quota integer not null default 0`
- `invite_quota_updated_at timestamp`

This keeps "add more for a user/all users" simple and DB-friendly. Available invites are:

`users.invite_quota - count(invite_codes where owner_user_id = user.id)`

This counts generated codes, not only redeemed codes, so users cannot generate unlimited outstanding codes. Admin grants increment `invite_quota`. If we want revoked/expired codes to return quota later, add a `counts_against_quota boolean default true`, but v1 can keep it simple.

## Code Format

Use human-friendly codes like:

`INLINE-XXXX-XXXX`

Implementation:

- Normalize by trimming, uppercasing, removing spaces and hyphens before hashing.
- Generate 80+ bits of randomness, encode with a non-confusing alphabet, display grouped.
- Store only `hashToken(normalizedCode)` or a dedicated SHA-256 helper; store `code_prefix` for admin display/search.

Security note: invite codes are bearer tokens, lower sensitivity than sessions, but still should not be stored as plaintext. Admin can generate and show new codes once; existing codes can be listed by prefix/status only.

## Server Module

Create `server/src/modules/invites/inviteCodes.ts`.

Core functions:

- `normalizeInviteCode(code: string): string`
- `createInviteCodes(input: { ownerUserId?: number; createdByUserId?: number; count: number; expiresAt?: Date; note?: string }): Promise<Array<{ id: number; code: string }>>`
- `redeemInviteCode(input: { code: string; email: string; userId: number }, tx): Promise<void>`
- `grantInvites(input: { userId: number; count: number; actorUserId?: number; note?: string }): Promise<void>`
- `grantInvitesToAll(input: { count: number; actorUserId?: number; includePendingSetup?: boolean }): Promise<number>`
- `getInviteSummary(userId: number): Promise<{ quota: number; generated: number; redeemed: number; available: number }>`

Redeem should run inside the same DB transaction as user creation/update:

1. Normalize and hash code.
2. Find code row.
3. Reject missing, disabled, expired, or already redeemed.
4. Set `redeemedByUserId`, `redeemedEmail`, `redeemedAt`.
5. Ensure update uses `where id = ? and redeemed_at is null` so concurrent attempts cannot double-spend.

## Auth Flow Changes

Change `verifyEmailCode` input:

- Add optional `inviteCode`.

After OTP verification:

1. Load user by normalized email.
2. If user exists and `pendingSetup !== true`, proceed normally.
3. If user exists and `pendingSetup === true`, treat it as an invited pending user and finish setup without an app invite code.
4. If user does not exist:
   - Require `inviteCode`; if missing/invalid, return a new API error.
   - In a transaction, create the user, redeem the invite code against that new user, and set `invite_quota` to the default.
5. For all newly activated users, set `pendingSetup: false`.

Add API errors in `server/src/types/errors.ts`:

- `INVITE_CODE_REQUIRED` 403 or 400
- `INVITE_CODE_INVALID` 400
- `INVITE_CODE_USED` 400
- `INVITE_CODE_EXPIRED` 400

Recommended response status: `403` for missing invite on signup gate, `400` for malformed/invalid code. Keep client copy generic so invalid/used/expired does not leak much.

Important: do not put invite-code validation in `sendEmailCode`. Email OTP should still work for existing users and should not reveal whether an email is eligible. The gate belongs after OTP verification.

## Client Changes

`apple/InlineKit/Sources/InlineKit/ApiClient.swift`

- Add `inviteCode: String? = nil` to `verifyCode`.
- Send `inviteCode` when non-empty.
- Add API error mapping/copy if there is a central mapper.

iOS onboarding:

- Add an invite-code field only for new users.
- Since current iOS flow does not store `existingUser`, either:
  - Preferred: pass `existingUser` from `sendCode` into the code screen and show invite input only when `existingUser == false`.
  - Simpler v1: show an optional invite-code field on the code screen; only require it client-side when server returns `INVITE_CODE_REQUIRED`.

macOS onboarding:

- `OnboardingViewModel.existingUser` is already populated by `OnboardingEnterEmail`.
- Show invite-code input on `EnterCode` when `existingUser == false`.
- Preserve current code-entry path for existing users.

CLI:

- Add an optional invite-code prompt/flag in the email verification flow so public CLI signup remains possible.

## User Invite Management UX

This can be two phases.

Phase 1, admin/database only:

- Admin endpoints:
  - `GET /admin/users/:id/invites` returns quota/generated/redeemed/available plus recent invite rows.
  - `POST /admin/users/:id/invites/grant` body `{ count, note? }`, requires step-up.
  - `POST /admin/invites/grant-all` body `{ count, note? }`, requires step-up.
  - `POST /admin/users/:id/invites/create-codes` body `{ count, expiresAt?, note? }`, requires step-up, returns raw codes once.
- Add invite fields to `/admin/users` and `/admin/users/:id` responses if useful for the UI.

Phase 2, user-facing invites:

- Add authenticated API endpoint to create/view own invite codes.
- Add iOS/macOS settings entry "Invites" showing available count, generated codes, and copy/share controls.

Do not block the signup gate on Phase 2 if admin/database seeding is enough for launch.

## Admin/Database Operations

Seed launch invites:

- Add a script under `server/scripts/` or an admin endpoint to generate N admin/system invite codes.
- Script should print raw codes once and store hashes.

Manual DB grant for one user:

```sql
update users
set invite_quota = invite_quota + 5,
    invite_quota_updated_at = now()
where id = 1234;
```

Manual DB grant for all users:

```sql
update users
set invite_quota = invite_quota + 1,
    invite_quota_updated_at = now()
where coalesce(deleted, false) = false
  and coalesce(bot, false) = false
  and coalesce(pending_setup, false) = false;
```

Manual code creation should preferably use the server helper/script so hashes match code normalization.

## Migration/Rollout

1. Add schema fields and generated migration.
2. Backfill existing users with an initial invite quota, proposed:
   - real users: `3`
   - bots/deleted/pending setup: `0`
3. Deploy backend accepting optional `inviteCode`; before client release, old clients can still log in if existing users.
4. Release iOS/macOS/CLI with invite-code signup UI.
5. Generate initial admin invite codes for public launch.
6. Monitor failed signup errors by type.

Compatibility risk:

- New users on old clients will fail with `INVITE_CODE_REQUIRED` after entering OTP and have no field to recover. For App Store/TestFlight rollout, either ship clients first while server still allows open signup, or add a temporary server-side allowlist/bypass flag until minimum client versions are common.

## Tests

Backend tests in `server/src/__tests__/api.test.ts` or a new auth invite test file:

- Existing user can verify email without invite code.
- Missing invite blocks brand-new email after OTP verification.
- Valid invite creates user, consumes code, creates session, grants default quota.
- Reusing invite code fails.
- Expired/disabled invite fails.
- Pending setup user can complete signup without app invite code.
- Concurrent redemption only creates/assigns one user/code redemption.
- Admin grant-one increments quota and requires step-up.
- Admin grant-all updates only eligible users.

Client checks:

- Swift compile for `InlineKit`.
- iOS/macOS onboarding manually verifies:
  - existing user sees normal flow
  - new user sees invite input
  - invalid invite shows actionable error

## Open Decisions

- Default invite count: proposed `3`.
- Should generated but unredeemed codes consume quota? Proposed yes for simplicity and abuse control.
- Should pending setup users from space invites get default public invites when they finish setup? Proposed yes if they become real users, unless invite growth should be slower.
- Should invite codes expire? Proposed no default expiry for user-generated codes, optional expiry for admin campaigns.
- Should public signup support phone auth too? Current request is signup gate generally, but email auth is the visible signup path. If phone signup remains public, mirror the same invite gate in `verifySmsCode`.

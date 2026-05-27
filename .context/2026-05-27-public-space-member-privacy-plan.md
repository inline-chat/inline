# Public space member privacy plan

Date: 2026-05-27

## Goal

Ship a backend-enforced privacy mode for public community spaces, starting with the production "Town Hall" space:

- spaces get a public flag
- when a space is public, members can enumerate the member roster
- when a space is public, non-admin members do not receive sensitive user fields for other members, including email, phone number, pending setup, time zone, exact status/last online
- admins/owners keep member-management visibility

## Current findings

### Space schema has no public flag

`server/src/db/schema/spaces.ts` currently has `id`, `name`, `handle`, `creatorId`, `date`, `deleted`, `updateSeq`, and `lastUpdateDate`. There is no space-level privacy/public indicator.

`proto/core.proto` `Space` also has no public/privacy field, so clients cannot know a space is in stricter mode.

### Realtime getSpaceMembers leaks full users

`server/src/functions/space.getSpaceMembers.ts`:

- validates only that `spaceId` is positive
- does not check caller membership
- loads every `members` row in the space
- loads every user record for those members
- returns `Encoders.user({ user: u.user, min: false })`

`Encoders.user(..., min: false)` includes `email`, `phoneNumber`, `pendingSetup`, `status`, and `timeZone`.

This is the highest priority exposure.

### Space member add updates leak full invited users

`server/src/functions/space.inviteToSpace.ts` persists and broadcasts `spaceMemberAdd` with `Encoders.user({ user, min: false })` into the space update bucket and realtime pushes.

For a public space, every member who can sync the space bucket can receive the newly added member's email/phone/etc unless this is changed.

### Legacy /v1 getDialogs is a major public-space risk

`server/src/methods/getDialogs.ts`:

- loads the space with all members and each member's user record
- creates missing private chats/dialogs from the caller to every space member
- appends all space member users to the response
- returns `users: users.map(encodeFullUserInfo)`

This leaks full user records for all members and also creates DMs that may make future leakage worse. This path must be patched even if the new realtime API is primary.

### Legacy /v1 getSpaceMembers lacks access validation

`server/src/methods/getSpaceMembers.ts` returns min users, but it does not verify that the caller is a member of the space. It should require membership.

### Legacy /v1 getUser returns full user data while declaring min response

`server/src/methods/getUser.ts` declares `TMinUserInfo` but returns `encodeFullUserInfo(user)`. This means any authenticated caller who knows a user ID can fetch email/phone/etc. This is not limited to Town Hall, but it undermines the public-space privacy goal.

### Other full user surfaces to audit in patch

- `server/src/functions/messages.getChats.ts` encodes referenced last-message/DM users with full `Encoders.user` by default.
- `server/src/functions/messages.getChatParticipants.ts` does not call `AccessGuards.ensureChatAccess` before returning participants and encodes full users.
- `server/src/modules/updates/sync.ts` can inflate `newChat.user` with full user info for private chat creation.
- API-type min users currently still include `online`, `lastOnline`, and `pendingSetup`; for public spaces we likely need a stricter public profile shape.

## Proposed model

Add a space-level `isPublic`/`public` flag that means "community/public space with stricter privacy". This is separate from chat `publicThread`.

For public spaces:

- admin/owner:
  - can call member management APIs
  - can receive full member list and full user info where needed for management
- regular member:
  - can access public threads according to existing `canAccessPublicChats`
  - can enumerate members through `getSpaceMembers`
  - receives only public/min user profiles for member users
  - does not receive member-add user private fields through realtime or catch-up sync
  - only receives public profiles for users needed to render accessible chats/messages
- non-member:
  - cannot call space APIs

Public profile should include only:

- `id`
- `firstName`
- `lastName`
- `username`
- `bot`
- `profilePhoto`

It should not include:

- email
- phone number
- pending setup
- time zone
- online / last online

## Implementation plan

1. Add schema and protocol flag

- Add `isPublic` to `server/src/db/schema/spaces.ts`, backed by `is_public boolean not null default false`.
- Generate a Drizzle migration with `bun run db:generate public-space-privacy`.
- Add `optional bool is_public = 5;` to `proto/core.proto` `Space`.
- Update `server/src/realtime/encoders/encodeSpace.ts` and legacy `encodeSpaceInfo`/`TSpaceInfo`.
- Regenerate protobufs with `bun run generate:proto`.

2. Add shared privacy helpers

Create a small server helper, likely `server/src/modules/privacy/spacePrivacy.ts`:

- `getSpacePrivacyContext(spaceId, viewerId)` returns `{ space, viewerMember, isPublicSpace, viewerCanManageMembers }`.
- `getSpacePrivacyContext(spaceId, viewerId)` enforces membership before any member listing.
- `encodeUserForViewer(user, opts)` or `encodePublicUser(user)` centralizes public user encoding so endpoints do not choose `min: false` ad hoc.

Avoid DB work inside computed values; keep helpers explicit and query-backed.

3. Patch realtime member APIs

- `functions/space.getSpaceMembers.ts`:
  - require caller membership for all spaces
  - if space is public and caller is not admin/owner, return members with public/min users
  - keep full data for admin/owner; for private spaces preserve existing behavior unless we decide to harden globally.
- `functions/space.inviteToSpace.ts`:
  - when persisting `spaceMemberAdd` for a public space bucket, store public/min user, not full user.
  - when returning the invite result to the admin caller, full user is acceptable.
  - when pushing realtime updates in a public space, do not send full user to regular members.

4. Patch legacy HTTP APIs

- `methods/getSpaceMembers.ts`: add membership check and return min users.
- `methods/getDialogs.ts`: for public spaces, keep the member roster as min users for regular members, but remove automatic DM creation to every space member unless the caller is admin/owner. Encode returned users with public profile unless the caller is admin/owner.
- `methods/getUser.ts`: return `encodeMinUserInfo` or a stricter public user by default. Only return full user for self/admin-specific surfaces.
- `methods/getPrivateChats.ts`: keep full peer data for actual DMs for now, but do not rely on public-space membership-created DMs to expose public-space members.

5. Patch chat participant and referenced-user surfaces

- `functions/messages.getChatParticipants.ts`: call `AccessGuards.ensureChatAccess` before loading participants. For public-space chats, require admin/owner if the result enumerates participants; otherwise return public profiles only for non-admins.
- `functions/messages.getChats.ts`: encode `users` as public/min profiles when the referenced user is from a public-space context and the viewer is not admin/owner. For normal DMs/private spaces, preserve behavior unless we want broader hardening.
- `modules/updates/sync.ts`: for inflated `newChat.user`, avoid full user if the chat is related to a public space and viewer is not admin/owner.

6. Tests

Add focused tests for:

- public-space non-admin can call realtime `getSpaceMembers`, receives members plus min users
- public-space admin can call `getSpaceMembers`
- private-space member behavior remains compatible
- public-space `spaceMemberAdd` update contains no email/phone/status/timeZone for regular members
- legacy `/v1/getDialogs` for a public space returns members as min users, does not create DMs to every member, and does not include full user fields
- legacy `/v1/getUser` does not return email/phone for arbitrary user ID
- `getChatParticipants` requires chat access

Run:

- `cd server && bun test src/__tests__/functions/getSpaceMembers.test.ts src/__tests__/functions/getDialogs.test.ts src/__tests__/functions/getChats.test.ts`
- `cd server && bun test src/__tests__/functions/inviteToSpace.test.ts src/__tests__/functions/messages.participants.test.ts`
- `cd server && bun run typecheck`

7. Production rollout

- Deploy schema/proto/backend first.
- Set the production "Town Hall" row to public using a controlled migration/admin script after confirming the exact space ID or unique handle.
- Suggested one-off data change shape:
  - `update spaces set is_public = true where id = <town_hall_space_id> and deleted is null;`
  - if using handle, prefer exact handle over name because `name = 'Town Hall'` may not be unique.
- After enabling, verify with a non-admin account:
  - `getSpaceMembers` returns members but no email/phone/status/timeZone
  - `getDialogs` includes member public profiles but no private emails
  - member-add realtime/catch-up update has no email/phone
- Verify with an admin account:
  - member list and invite/manage flows still work

## Risk notes

- This is a server-side privacy fix. Clients may need follow-up UI handling for hidden/blocked member lists, but the backend should enforce privacy immediately.
- Existing clients may expect `getSpaceMembers` to work for regular members. The server preserves member visibility and strips private user fields for public spaces.
- Some old DM/dialog rows may already exist due to `getDialogs` auto-creation. The urgent patch should stop creating new ones; cleanup of existing Town Hall auto-DMs can be a follow-up after we inspect impact.
- Existing persisted space update buckets may already contain full `spaceMemberAdd.user` payloads. Once a space is marked public, `getUpdates` still inflates old persisted payloads unless we sanitize on read or rewrite old updates. For Town Hall, implement read-time sanitization for public spaces before enabling the flag, or backfill/remove sensitive old member-add payloads.

# Mentions: Auto-Add Policy + Mention Indicators (2026-02-07)

From notes (Feb 4-7, 2026): "@ mention make sure adds ?", "don't add @ mentioned people to thread automatically after first 2 message and ask for it from toolbar?", "need to show @ mention on threads".

## Goals

1. Mentions behave consistently across iOS and macOS.
2. Mentioning a non-participant can help onboarding early in a thread, without surprising users later.
3. Thread list can show a reliable mention indicator for the current user (not a guess based on last message).
4. Server enforces permissions for adding participants (especially for space threads).

## Non-Goals (For Tomorrow)

1. Rebuild the entire mention entity system.
2. Complex mention privacy rules beyond the existing access model.

## Current State (What Exists)

1. Mentions are extracted client-side in compose and sent as entities.
2. macOS has auto-add-on-mention, but it is hard-coded to the first 10 messages.
3. iOS has no auto-add-on-mention.
4. Server `messages.addChatParticipant` does not validate space membership/permissions strongly for space threads.
5. `Message.mentioned` exists in protocol and local models, but the server does not populate it.

Key files:
- Mention detection: `apple/InlineKit/Sources/InlineKit/RichTextHelpers/MentionDetector.swift`
- Entity extraction: `apple/InlineUI/Sources/TextProcessing/ProcessEntities.swift`
- macOS auto-add: `apple/InlineMac/Views/Compose/ComposeAppKit.swift`
- iOS compose: `apple/InlineIOS/Features/Compose/ComposeView.swift`
- Server add participant: `server/src/functions/messages.addChatParticipant.ts`
- Mention flag missing: `server/src/realtime/encoders/encodeMessage.ts`

## Policy Proposal

### 1. Auto-add window (recommended)

1. Auto-add mentioned users only for the first N messages in a thread.
2. Recommended N = 2 (matches the note: "after first 2 message ask for it from toolbar").
3. Auto-add is only allowed in private threads (home threads).
4. For space threads, never auto-add silently. Show a prompt only if sender has permission and the target is a member.

### 2. After N messages

1. Do not auto-add.
2. Show a lightweight toolbar prompt: "Add @alice to thread?".
3. Sender must confirm explicitly.

Tradeoff:
1. Lower N reduces surprise and accidental participant adds.
2. Prompt-after-N keeps onboarding flow available without being creepy.

## Server Changes

### 1. Harden `addChatParticipant` permissions (required)

1. Space threads: require that the target user is a member of the space.
2. Space threads: require that the current user has permission to add participants (define rule).
3. Home threads: keep creator-only rule.
4. Always verify thread access for both actor and target.

Touchpoint:
- `server/src/functions/messages.addChatParticipant.ts`

### 2. Populate `Message.mentioned` per recipient (required for mention indicators)

Idea:
1. Compute `mentioned = true` for a specific recipient if the message entities include a mention of that user.
2. This is encode-time, per-recipient data, so it must be computed while encoding updates for a target user.

Touchpoints:
- `server/src/realtime/encoders/encodeMessage.ts`
- `server/src/realtime/encoders/encodeFullMessage.ts` (if separate)

Notes:
1. This does not require DB schema changes.
2. This enables a thread-level mention badge via local DB queries.

## Client Changes

### macOS

1. Replace the hard-coded auto-add limit (10) with a shared policy constant (N).
2. Gate auto-add by thread type (home/private only).
3. After N, show a toolbar prompt instead of auto-add.
4. Add mention badge in thread list:
5. Badge should reflect "has unread mention", not "last message mentions you".
6. Implement by querying local DB: any unread message in the chat where `mentioned == true`.

Likely touchpoints:
- `apple/InlineMac/Views/Compose/ComposeAppKit.swift`
- New UI thread list row: `apple/InlineMac/Views/Sidebar/NewSidebar/SidebarItemRow.swift`
- Legacy list (avoid if possible): `apple/InlineMac/Features/Sidebar/MainSidebarItemCell.swift`

### iOS

1. Mirror the same policy and prompts.
2. Implement mention badge in thread list using the same local DB rule.

Touchpoints (likely):
- `apple/InlineIOS/Features/Compose/ComposeView.swift`
- Home list row view (where unread badges are rendered)

## UX Details (Prompt)

1. Prompt appears only if the mentioned user is not already a participant.
2. Prompt appears only if sender is allowed to add participants.
3. Prompt is dismissible, and does not re-appear for the same mention multiple times.

## Testing Plan

1. Server: space thread add participant rejects non-space members.
2. Server: encode sets `mentioned=true` only for the mentioned user, not for others.
3. macOS/iOS: after N messages, mention does not auto-add; prompt appears.
4. Thread list: mention badge appears when there is an unread mentioned message, disappears when read.

## Acceptance Criteria

1. Mention auto-add happens at most for the first 2 messages in a home thread.
2. After message 2, mentioning someone never silently adds them.
3. Mention indicators are accurate and consistent across platforms.
4. Space membership and permissions are enforced by the server.

## Open Questions

1. Exact permission rule for space threads: who can add participants (creator, admin, any member)?
2. Should the mention badge show only when unread, or also for "you were mentioned" even if read?


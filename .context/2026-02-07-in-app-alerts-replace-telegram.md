# In-App Alerts: Replace Telegram With Inline (2026-02-07)

From notes (Feb 7, 2026): "small: move alerts outside of Telegram and put inside Inline".

This spec treats “alerts” as operational/product update messages that today might be routed to Telegram (or other external chat) but should live in Inline itself.

Related spec:
- `/.agent-docs/2026-02-07-bots-sdk-and-updates-thread.md`

## Goals

1. Inline has a first-class channel/thread for:
2. Product updates (release notes, announcements).
3. Operational alerts (CI failures, deploy status, incident notes).
4. Users don’t need Telegram to stay informed.
5. Permissions are clear: read-only for most, write for a small set of maintainers/bots.

## Non-Goals (For First Pass)

1. A full incident management system.
2. A general-purpose monitoring/alerting pipeline.

## Proposed UX

1. A dedicated system space: "Inline".
2. A dedicated read-only thread: "Updates".
3. Optional second thread: "Alerts" (ops/CI/deploy).
4. Threads are pinned and visually distinct (badge or icon).

## Permission Model

1. Read access: all users (or all space members if we scope it).
2. Write access:
3. Only maintainers (admin role) and service bots.
4. Replies:
5. Disabled for normal users (read-only).
6. Reactions allowed (optional) to measure engagement.

Implementation approach:
1. Add a “readOnly” flag to chat settings with role-based exceptions.
2. Server enforces write restrictions.

## Ingestion Model (How Alerts Get Into Inline)

Option A (Fast): CLI/Bot SDK sender
1. A bot runs in CI or on a server and calls `inline` CLI to post messages.
2. Use the bot/updates long-poll API shape from the bots spec.

Option B (More robust): webhook endpoint
1. A server endpoint accepts signed webhook payloads and posts to the Updates/Alerts thread.
2. This removes the need to ship CLI credentials into CI runners.

## Message Format Guidelines

1. Alerts are structured:
2. Title line: `[SEV2] Deploy failed`
3. Body: key details and links.
4. Include tags: `#deploy`, `#ios`, `#mac`, `#server`.

## Implementation Plan

### Phase 1: "Updates" thread MVP

1. Create a special thread (or reserve an existing thread ID) for updates.
2. Enforce read-only permissions.
3. Add a bot path to post updates.

### Phase 2: "Alerts" thread + severity conventions

1. Add a second thread.
2. Add lightweight conventions for severity and tagging.
3. Add optional notification rules (push only for high severity).

### Phase 3: Surface in UI

1. Pin and label the thread(s) in sidebar.
2. Add “new update” badge.
3. Consider a small “What’s new” panel powered by the Updates thread.

## Acceptance Criteria

1. We can post a release update into Inline via a bot.
2. Normal users cannot post/reply in the Updates thread.
3. The Updates thread is discoverable and easy to find.

## Open Questions

1. Should "Inline Updates" be global-public or per-space?
2. Should we allow replies in a separate “Feedback” thread instead?


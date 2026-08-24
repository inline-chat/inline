# Realtime Sync Engine

Inline Realtime V3 keeps the server and every client converged without replacing useful cached state during ordinary recovery. This page is the public technical contract for update ownership, gap handling, and message-history coverage.

The server emits canonical access-transition and per-chat history-clear updates. Legacy constructors remain decodable for already-persisted update rows, but new mutations do not emit them and Inline never dual-writes both families.

## The three buckets

Every durable update belongs to one inferred bucket. Updates do not carry a bucket field.

| Bucket | Owns |
| --- | --- |
| User | Account/settings/profile changes; dialog open/archive/follow/read state; space join/leave; top-level chat access gained or lost |
| Space | Membership and space-settings changes |
| Chat | Messages, pins, chat metadata/visibility, participants/groups, moves/deletion, and scoped clear-history effects |

`markAsUnread` is user-owned. `userAddedToChat` and `userRemovedFromChat` represent effective access transitions for independent, top-level chats; optional group data is provenance. Subthreads are discoverable through their parent and emit no durable access event when created. Reactions, compose/presence, and new-message notifications are ephemeral.

## Cursor and target

Each bucket has one durable cursor: the last sequence whose projection was committed. A volatile target is the highest sequence the client knows it needs.

```text
stale or duplicate       seq <= cursor      ignore
contiguous               seq = cursor + 1   apply + commit
gap                      seq > cursor + 1   fence bucket + fetch
```

Only the affected bucket pauses. Pages contain at most 100 logical updates. Unknown future update content is an accounted no-op so an older client does not become permanently stuck; a known reducer failure does not advance the cursor.

## Large-gap recovery

The server permits incremental replay through 10,000 logical updates. Above that it returns `TOO_LONG`: an instruction to install an authoritative snapshot. Its sequence is a target, never permission to fast-forward.

- User repair captures the current user checkpoint through `GET_UPDATES_STATE` before fetching `GET_CHATS`, the current user, and settings. It installs those projections before continuing after the captured checkpoint.
- Space repair uses `GET_SPACE`: `Space.seq`, the authenticated user's `membership`, and small space settings—never the full member list.
- Chat repair uses `GET_CHAT` and a bounded latest-history read while preserving cached messages and user-owned dialog preferences.

Snapshot identity and sequence are validated before projection and cursor commit together. A failed or malformed repair preserves the old cursor. There is no cold 50-update replacement, local 1,000-update slicing, or time-based 5/14-day lookback.

## Message-history holes

Update continuity does not prove history continuity. Apple stores merged inclusive message-ID intervals that remain unknown. Only a successfully applied `GET_CHAT_HISTORY` response can close one; `GET_CHATS`, `GET_CHAT`, `GET_MESSAGES`, realtime messages, and sent messages may materialize rows but do not certify a contiguous interval.

An `AROUND` anchor is a numeric coordinate, not a required row. The server selects the nearest history below, at, and above that ID even if the exact message was deleted or never existed. Cached messages still render on the first frame. A dedicated per-chat repair owner fetches holes as the visible window reaches them, avoiding destructive chat replacement.

## Presentation

Clients retain cached content while they connect or repair and expose stable Connecting and Updating phases after small tunable presentation delays. Network state never waits on a fixed delay; the delays only prevent imperceptibly short transitions from flashing.

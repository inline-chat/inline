# Cross-Device Persistent Sync of Read Events (3 Proposals)

## Context / Learnings (Telegram + current Inline sync experiment)
- Telegram treats reads as a **coalesced max-read pointer** (per dialog/thread) and propagates them via **pts-ordered updates**.
- Clients only push read state when the chat is readable (visible/bottom, active), then send `readHistory(max_id)`; server emits a read update with pts.
- This avoids per-message events and keeps write volume low while still giving durable cross-device sync.
- Inline today has a **bucketed updates** system with per-bucket seq, and a **sync experiment** that allows only certain updates through bucket catch-up.

Goal: add **cross-device persistent** read sync, minimizing write volume while keeping ordering and correctness.

---

## Proposal A — User-Bucket Read Updates (Coalesced Max-Read Pointer)
**Summary**: Persist a read update into the **user bucket** whenever a dialog’s `readMaxId` advances (coalesced), and include it in the sync experiment allowed list.

**Data model**
- Add server update type: `ServerUserUpdateReadMaxId` with `peer_id`, `read_max_id`, `unread_count`.
- Store in `updates` table (bucket = User, entityId = userId) with seq.

**Flow**
1. On read action, update `dialogs.readInboxMaxId` (already in DB).
2. If the new `readMaxId` > previous, enqueue **one** user-bucket update (coalesced; drop repeats).
3. Realtime still pushes `UpdateReadMaxId` immediately for active sessions.
4. Sync experiment fetches user bucket and applies `UpdateReadMaxId` (allowed list updated).

**Pros**
- Minimal changes to current sync architecture.
- Preserves strict ordering with other user-bucket events via seq.
- Easy to reason about and test.

**Cons**
- Still writes an update row per dialog read advance (though coalesced).
- User-bucket volume can rise for heavy readers unless throttled.

**Mitigations**
- Coalesce per dialog: only enqueue if `readMaxId` increases.
- Optional debounce (e.g., 2–5s) or per-session batching.

**Changes**
- `proto/server.proto`: add server user update.
- `server/src/modules/updates/userBucketUpdates.ts`: enqueue read updates.
- `server/src/modules/updates/sync.ts`: inflate user read updates -> `UpdateReadMaxId`.
- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift`: allow `.updateReadMaxId` in `shouldProcessUpdate`.
- Add tests for read update inflation + sync catch-up ordering.

---

## Proposal B — Dialog Read-State Snapshot Sync (No Update Rows)
**Summary**: Do **not** write per-read updates to `updates`. Instead, persist read state in `dialogs`, and during sync deliver a **snapshot/diff** of read states.

**Data model**
- Add a new RPC: `getReadState` or extend `getUpdatesState` to include read pointers (per dialog).
- Optionally store `dialogs.updatedAt` to compute diffs since last sync date.

**Flow**
1. On read: only update `dialogs.readInboxMaxId` (no updates table write).
2. On sync start (or periodically), client requests read state diff since `lastSyncDate`.
3. Client applies read pointers locally.

**Pros**
- Lowest write volume; no per-read update rows.
- Read state stays in a single source of truth.

**Cons**
- Requires new sync surface (RPC + storage for last read-state cursor).
- Ordering relative to message edits/deletes must be handled carefully.
- Potentially heavier sync response (list of dialogs).

**Mitigations**
- Only include dialogs updated since `lastSyncDate`.
- Cap response size; paginate.

**Changes**
- New RPC and schema updates.
- Read-state diff logic in server.
- Client apply logic in sync engine.

---

## Proposal C — Hybrid: Read-State Delta Bucket (Batched)
**Summary**: Keep a **small, dedicated read-state delta stream** stored in a separate table or in updates with **batch rows**, not one row per read.

**Data model**
- A `read_state_events` table (userId, peerId, readMaxId, unreadCount, updatedAt).
- A single **batch update** row in user bucket containing N read-state changes.

**Flow**
1. On read: upsert `read_state_events` (coalesced per peer).
2. Periodically (or on disconnect), enqueue a **batch update** with all pending read deltas.
3. Client applies batch read updates via sync.

**Pros**
- Reduces write amplification while still using updates seq.
- Preserves ordering with other user updates if batch is inserted into user bucket.

**Cons**
- More moving parts: a new table + batcher.
- Batch size limits and duplicate handling required.

**Mitigations**
- Compact batch payload: only `peer_id`, `read_max_id`, `unread_count`.
- Enforce size/ttl; flush on disconnect.

**Changes**
- Add read-state events storage + batcher.
- Add batch update proto and inflater.
- Client apply logic for batch updates.

---

## Cross‑cutting decisions (need input)
1. Should read updates be **chat bucket** or **user bucket**? (Proposal A/B/C assume user bucket to keep per-user state.)
2. Do we need **outbox read** state too, or only inbox read?
3. Should read updates be **gated** by the existing experiment flag, or always allowed?
4. Debounce window (if any) for enqueueing read updates?

---

## Recommendation (initial)
- Start with **Proposal A** (user-bucket coalesced max-read pointer). It fits current architecture and is closest to Telegram’s pts-based update flow.
- If write volume is still high, evolve to **Proposal C** (batch deltas).
- Consider **Proposal B** only if you want to remove read events from the updates stream entirely.


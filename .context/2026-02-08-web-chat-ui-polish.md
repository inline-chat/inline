# Web Chat UI Polish (Noor2-Inspired)

Date: 2026-02-08

## Goal
Reduce scope and ship a polished web chat UI by copying the *feel* of Noor2's web frontend:
- Sidebar chat items (row density, hover affordances, active styling)
- Chat header (title/subtitle, typing indicator)
- Message list (simple, readable, consistent spacing)

## Non-goals (for this pass)
- Reactions UI
- Thread creation / new chat flows
- Advanced message actions (forward, pin, etc)
- Space tab bar

## Work Items
1. Sidebar UI
   - Make header truly minimal (space picker only, Noor2-like spacing).
   - Simplify list (reduce visual noise; keep sections only if helpful).
   - Archive UX: footer toggle mode; item hover shows archive/unarchive affordance.
   - Ensure archive/unarchive does not mutate unrelated fields (pinned/draft).
2. Chat Header
   - Align typography/spacing with Noor2 header patterns.
   - Show typing indicator in subtitle (already wired through compose actions).
3. Message List
   - Match Noor2 density/padding.
   - Improve per-row metadata presentation (time/status) without clutter.
   - Ensure avatar fallback works for all users (including self).
4. Routing
   - Keep `dialogId`-based route canonical; ensure space picker updates URL reliably.
   - If switching to path-based space routing later, prefer `/app/s/$spaceId/d/$dialogId` to avoid mismatches.
5. Local Cache/DB Review (web/packages/client)
   - Evaluate robustness and identify concrete risks (schema versioning, query invalidation, multi-tab sync, memory growth).
   - Propose minimal improvements that don't explode scope.

## Status
- In progress.
- Implemented: sidebar search removed, archive toggle moved to footer (always visible), sidebar header made minimal (Noor2-ish), message row right-meta hidden until hover, archive/unarchive no longer forces `pinned: false`.

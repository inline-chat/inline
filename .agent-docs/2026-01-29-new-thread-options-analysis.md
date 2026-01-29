# New Thread Options - Deeper Analysis (A/E/C)

Date: 2026-01-29

## Context & constraints
- New UI only (Nav2, new sidebar, CMD+K).
- Server `createChat` requires non-empty title; private threads require participants; home public threads unsupported.
- Current blocker: "can't create optimistic chats" (avoid optimistic DB inserts for chats).

## Option E: Compose-first (no optimistic chat; create on first send)
### UX
- Best perceived UX: immediate typing without disabled send; feels intentional and modern.
- Avoids showing a fake chat or spinner.

### Safety & correctness
- Strong: no temp chat IDs, no DB cleanup, no message migration.
- Draft is the source of truth until createChat succeeds.

### Complexity
- Requires a draft container not keyed to a dialog/chat ID.
- Must derive participants at create time (mentions or explicit picker).
- Title must be supplied; allow pre-send title field or default "Untitled".
- Attachments need a staging model (pre-chat) or defer to later.

### Maintainability
- Good if compose-first is thin and reuses ComposeAppKit.
- Risk of divergence between pre-chat and in-chat compose flows.

### When to pick
- Best if immediate typing is a top UX goal and optimistic DB writes remain blocked.

## Option A: Optimistic stub + send disabled
### UX
- Familiar chat UI immediately, but send is disabled until server response.

### Safety & correctness
- Safer than migration, but still needs optimistic DB objects.
- Must migrate draft from temp dialog to real dialog on success.

### Complexity
- Requires temporary Chat/Dialog/Participant records.
- Requires "creating" UI state and send gating.

### Maintainability
- OK, but introduces a temp-chat concept that persists in data layer.

### When to pick
- If optimistic chat inserts become possible and you want fewer new UI surfaces.

## Option C: Server-first create, then open
### UX
- Slowest; user cannot type until server returns.

### Safety & correctness
- Highest: no optimistic data, no draft migration.

### Complexity
- Minimal. Uses existing transaction and simple loading UI.

### Maintainability
- Excellent; least branching logic.

### When to pick
- Safe interim step while validating UX and backend constraints.

## Summary guidance
- If UX priority = immediate typing, prefer E.
- If priority = lowest risk today, choose C.
- If later enabling optimistic inserts, A can be a stepping stone.

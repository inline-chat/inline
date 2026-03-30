# Subthreads (Reply Threads) Spec + Implementation Plan

Date: 2026-02-19
Owner: platform planning
Scope: Add message-level subthreads on top of existing top-level threads (`Peer.thread`) in the new UI.

## 1) Goal

Enable users to open a dedicated reply thread from a message inside an existing thread chat, view all replies in that subthread, reply inside it, and see per-message reply summary (reply count + unread hint) in the parent timeline.

## 2) Current State (from codebase)

### Existing thread model
- `Peer.thread` maps 1:1 to `chats` rows (`type = thread`) and is the atomic timeline container.
- `messages` are keyed by `chatId` + per-chat `messageId`.
- `reply_to_msg_id` exists on `messages` but is nullable, not indexed for thread timelines, and has no FK enforcement.
- History/read/update pipelines are chat-centric (`chatId` everywhere in server, clients, and local DB models).

### UI surfaces
- Apple new UI already has full chat timeline/composer/navigation stack and message context menus (`MessageView`, `ComposeAppKit`, `Nav2`).
- Web new UI has sidebar and data hydration, but no real message timeline route yet (`MainSplitView.Content` is still placeholder text).

### Server constraints that matter
- Write path increments `chats.lastMsgId` and emits `UpdateBucket.Chat` updates keyed by chat.
- Unread/read state is tracked in `dialogs` per chat.
- Notifications and update routing depend on chat update groups (`chat_participants` or space membership).
- `getUpdateGroup` currently scans participant sets and already has an OOM risk note (no batching).

## 3) Architecture Options

### Option A: Reply graph only (no subthread entity)
Store only `reply_to_msg_id` and compute subthread timeline by traversing reply chains.

Pros
- Minimal schema expansion.

Cons
- No stable subthread identity for routing/state.
- Hard to do unread, subscription, and notifications.
- Expensive query path and significant special-case code in history/search/update sync.
- Conflicts with current chat-centric architecture.

Verdict: not recommended.

### Option B: Subthread as child chat (first-class)
Create a child chat for each subthread and route it as a regular `Peer.thread`, linked back to a parent message.

Pros
- Reuses existing chat history/send/read pipelines.
- Stable peer identity and navigation.
- Clean separation from parent timeline message IDs.

Cons
- Naive implementation causes participant/dialog row explosion if we clone full membership for each subthread.
- Requires explicit handling for summary counters on parent message.

Verdict: recommended with lightweight participation model (below).

## 4) Recommended Model (Option B, optimized)

Represent each subthread as a chat row, but do **not** auto-materialize full participant/dialog sets for all parent members.

### Data model changes (server)

1. `chats` (extend)
- `parent_chat_id BIGINT NULL`
- `parent_message_id BIGINT NULL` (or pair with message id type already used in APIs)
- `is_subthread BOOLEAN NOT NULL DEFAULT false`
- Index on `(parent_chat_id, parent_message_id)` unique for one subthread per root message.

2. `message_subthread_state` (new table)
- `parent_chat_id BIGINT`
- `parent_message_id BIGINT`
- `subthread_chat_id BIGINT`
- `reply_count INT`
- `latest_reply_at BIGINT`
- `latest_reply_msg_id INT`
- `updated_at BIGINT`
- PK/unique by `(parent_chat_id, parent_message_id)`.

3. `subthread_participants` (new table)
- `subthread_chat_id BIGINT`
- `user_id BIGINT`
- `read_max_msg_id INT DEFAULT 0`
- `following BOOLEAN DEFAULT true`
- `muted BOOLEAN DEFAULT false`
- `joined_at BIGINT`
- Unique `(subthread_chat_id, user_id)`.

Notes
- Parent-chat membership remains source of truth for authorization to open/read subthread.
- `subthread_participants` controls notification/unread fanout for subthread traffic.

### Protocol/API changes

1. `proto/core.proto`
- Extend `Chat` with optional subthread linkage fields (`parentThreadId`, `parentMessageId`, `isSubthread`).
- Extend `Message` with optional `subthreadSummary` for root message rows in parent timeline.
- Add `SubthreadSummary` message (`subthreadChatId`, `replyCount`, `unreadCount`, `latestReplyAt`, `latestReplier`).

2. Add operations
- `messages.openSubthread(parentPeer, parentMessageId)` -> returns subthread `Peer.thread` (idempotent create/get).
- `messages.getSubthreadSummary(parentPeer, parentMessageIds[])` (optional if summary not embedded in history payload).

3. Keep existing
- `sendMessage` and `getChatHistory` continue to work by chat peer; subthread peer is just another thread chat.

### Server behavior

1. Open subthread
- Validate parent chat access.
- Ensure parent message exists in parent chat.
- Upsert child chat row + `message_subthread_state`.
- Add caller to `subthread_participants` (+ dialog for caller if needed).

2. Send message in subthread
- Authorize by parent chat membership and subthread existence.
- Insert as normal message in `subthread_chat_id`.
- Update `message_subthread_state.reply_count/latest_reply_*`.
- Emit:
  - normal `newMessage` for subthread update group (followers/participants),
  - parent-chat lightweight `subthreadSummaryUpdated` event (for root message badge).

3. Read/unread
- Parent chat unread remains unchanged by subthread-only messages.
- Subthread unread is tracked per `subthread_participants.read_max_msg_id`.
- Summary unread count on parent message computed per user from subthread participant state.

4. Notifications
- Notify only `subthread_participants` (and optionally root author if product wants auto-follow).
- Avoid parent chat-wide broadcast for subthread traffic.

## 5) Client Plan

### Apple (new UI first)

Primary files
- Navigation: `apple/InlineMac/App/Nav2.swift`, `apple/InlineMac/Features/MainWindow/MainSplitView+Routes.swift`
- Message row/actions: `apple/InlineMac/Views/Message/MessageView.swift`, `apple/InlineMac/Views/Message/EmbeddedMessageView.swift`
- Timeline/composer: `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`, `apple/InlineMac/Views/Compose/ComposeAppKit.swift`
- Shared models/viewmodels: `apple/InlineKit/Sources/InlineKit/ViewModels/FullChat.swift`, `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift`, `apple/InlineKit/Sources/InlineKit/ApiClient.swift`, `apple/InlineKit/Sources/InlineKit/Database.swift`

Changes
- Add subthread route target (can be explicit route case or `chat(peer: subthreadPeer)` plus parent context).
- Add "View replies" action to message context menus / reply preview taps.
- Show reply count + unread badge on root message rows.
- In subthread view, composer sends to subthread peer while keeping parent message banner context.
- Ensure toolbar back/forward and history semantics work in `Nav2`.

### iOS

Primary files
- `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`
- `apple/InlineIOS/Features/Chat/ComposeView.swift`
- `apple/InlineIOS/Navigation/Router.swift`
- `apple/InlineIOS/Utils/ChatState.swift`

Changes mirror macOS:
- Add context-menu action and row affordance to open subthread.
- Route into subthread peer.
- Keep dedicated compose state for active subthread context.

### Web new UI

Primary files
- `web/src/routes/app/index.tsx`
- `web/src/components/mainSplitView/MainSplitView.tsx`
- `web/src/components/sidebar/Sidebar.tsx`
- `web/packages/client/src/database/models.ts`
- `web/packages/client/src/realtime/transactions/get-chat-history.ts`

Prerequisite blocker
- Build actual chat timeline route/components first; current content area is placeholder.

Subthread changes after prerequisite
- Add route stack: `/app/chat/:chatId` and `/app/chat/:chatId/subthread/:parentMessageId`.
- Add message row component with reply summary + open-subthread action.
- Add composer context for subthread route.
- Persist/restore scroll and parent-return navigation.

## 6) Phased Rollout Plan

### Phase 0: Product + API decisions (required)
- Decide if subthread replies should ever appear in parent timeline.
- Decide follower model: auto-follow root author? auto-follow repliers?
- Decide visibility: only via parent message vs optional sidebar list.

### Phase 1: Backend foundations
- DB migrations for new tables/columns.
- Proto/API changes and codegen.
- `openSubthread` + summary update events.
- Server tests for auth, idempotency, counts, read/unread.

### Phase 2: Apple new UI (macOS + iOS)
- Add message-level entrypoints and navigation.
- Render summary badge/count in parent timeline.
- Subthread timeline + composer integration.
- End-to-end tests/manual QA for back navigation, unread, notifications.

### Phase 3: Web new UI
- Deliver missing chat route/timeline baseline.
- Add subthread routes and message UI entrypoints.
- Add summary/unread rendering and composer behavior.

### Phase 4: Rollout + migration
- Feature flag per platform.
- Internal dogfood -> staged rollout.
- Optional migration policy for historic `reply_to_msg_id` messages:
  - no backfill for v1 (simpler), or
  - lazy backfill when opening a root message.

## 7) Risks, Blockers, Concerns

1. Web readiness blocker
- Web new UI does not yet render chat timeline; subthreads there are blocked until baseline chat view exists.

2. Scalability risk
- Child chat model is unsafe if it clones participants/dialogs to all parent members.
- Must use lightweight `subthread_participants` and avoid full fanout.

3. Update/notification consistency risk
- Need two streams: subthread messages and parent summary updates.
- Incorrect wiring can cause stale badges or over-notification.

4. Authorization risk (security)
- Subthread access must be strictly gated by parent chat authorization.
- Must prevent ID enumeration leakage across spaces/threads.

5. Cross-client contract drift
- Apple/web/local DB/proto must ship in lockstep; otherwise mixed clients may show broken badges/navigation.

6. Search/analytics gaps
- Existing search is chat-only; subthread-aware query semantics need explicit design.

## 8) Testing Plan

Backend
- Unit/integration:
  - open-subthread idempotency,
  - send/read in subthread,
  - parent summary counters,
  - auth boundary (space member vs non-member),
  - notification audience selection.

Apple
- Focused package build/tests in `InlineKit`.
- Manual QA flows for new UI routing and compose state.

Web
- Typecheck + route tests for nested chat/subthread paths.
- UI tests for back navigation and summary badge updates.

Perf checks
- Measure update group query load before/after.
- Validate no N x participants explosion under many subthreads.

## 9) Delivery Estimate (ballpark)

Assuming 1 backend + 1 Apple + 1 web engineer working in parallel after API decisions:
- Phase 0: 2-3 days
- Phase 1: 1.5-2.5 weeks
- Phase 2: 1.5-2 weeks
- Phase 3: 1-2 weeks (depends heavily on web baseline chat timeline completion)
- Phase 4: 3-5 days

Total: ~4.5 to 8 weeks calendar depending on web baseline completion and rollout safety requirements.

## 10) Recommended Next Step

Run a short decision checkpoint on 3 product choices before implementation:
1. Parent timeline visibility policy for subthread replies.
2. Follower/notification policy.
3. Whether subthreads appear in sidebar/discoverability surfaces in v1.

Without locking these, backend contract choices will likely churn.

---

## 11) North Star Update: Thread Graph + Backlinks + ACL Expansion + Share Links

This section updates the plan for the expanded goal:
- subthreads become graph nodes,
- threads can form links/backlinks beyond strict parent-child reply,
- child threads can include people not in the parent thread,
- threads can later be shared publicly with a link.

### Why this is a larger problem than v1 subthreads

Current architecture is chat-centric and access is tightly coupled to chat membership:
- Peer identity is only `user` or `thread` (`proto/core.proto`).
- Access checks for space threads require space membership and, for private threads, chat participants (`server/src/modules/authorization/accessGuards.ts`).
- Update fanout is derived from chat participants or space members (`server/src/modules/updates/index.ts`).

So graph links and ACL expansion must be modeled explicitly; it cannot be layered only on `reply_to_msg_id`.

### Graph-native data model additions

1. `thread_edges` (new)
- `id`
- `from_chat_id`
- `to_chat_id`
- `edge_type` (`reply_root`, `manual_link`, `reference`)
- `source_message_id` nullable (message that created the link)
- `created_by`, `created_at`
- Unique constraints to prevent duplicate active edges for same semantic key.

2. `chat_access_policy` (new or folded into `chats`)
- `chat_id`
- `policy_type` (`inherit_parent`, `explicit_participants`, `space_public`, `link_public`)
- `parent_chat_id` nullable
- `parent_message_id` nullable
- `allow_external_participants` bool

3. `chat_share_links` (new)
- `id`, `chat_id`, `token_hash`
- `created_by`
- `expires_at` nullable
- `max_uses` nullable
- `use_count`
- `require_auth` bool
- `join_mode` (`view_only`, `join_as_participant`)
- `revoked_at` nullable

4. Keep `message_subthread_state`
- still needed for parent-row summary counters (reply count/unread/latest).

### Protocol/API additions for the graph target

1. New graph APIs
- `createThreadLink(fromPeer, toPeer, sourceMessageId?, type)`
- `deleteThreadLink(linkId)`
- `getThreadGraph(peer, depth?, direction?)`
- `getThreadBacklinks(peer, cursor?)`

2. Subthread/ACL APIs
- `openSubthread(parentPeer, parentMessageId)` (idempotent)
- `addSubthreadParticipant(peer, userId)` for explicit ACL nodes
- `setThreadAccessPolicy(peer, policy)` for moving from inherited to explicit/public

3. Share link APIs
- `createThreadShareLink(peer, config)`
- `revokeThreadShareLink(linkId)`
- `joinThreadByLink(token)` (or `resolveThreadShareLink`)

### Critical constraints/blockers from current code

1. External participants in space-linked threads are currently blocked by design
- Access guard enforces space membership for space threads.
- `moveThread` explicitly documents external participant support as future work.

2. Fanout scaling
- `getUpdateGroup` already notes potential OOM path for large participant sets.
- Graph + many linked threads can amplify this if fanout model is not optimized.

3. No deep-link/share-link infra for chats today
- There is no thread share-token flow in current backend routes/proto; must be added from scratch.

### Recommended delivery strategy for the north star

Phase A (Graph-ready v1)
- Ship first-class subthreads as child chat nodes.
- Add `thread_edges` now (at least for `reply_root`) so backlinks are native from day one.
- Keep ACL as `inherit_parent` only in v1 to de-risk.

Phase B (Graph navigation)
- Expose backlinks and linked-thread UI surfaces.
- Add graph query endpoints and efficient edge indexes.

Phase C (ACL expansion)
- Add `explicit_participants` mode for selected subthreads.
- Add participant management for subthreads independent from parent participants.
- Keep strict auth checks and audit logs.

Phase D (Public/share links)
- Add signed share links with revoke/expiry/usage controls.
- Add join/view policy and abuse controls (rate limits + logging).

### Security risks to treat as release gates

1. Link token leakage / brute-force
- Use random high-entropy tokens, store hash only, rate-limit resolve/join.

2. Unauthorized graph traversal
- Backlink/graph queries must filter by per-node access, not only source node access.

3. ACL desync
- Access policy transitions must be transactional with participant/update state changes.

4. Data exfiltration through previews
- Parent message previews and thread metadata in graph results must be redacted when user lacks access.

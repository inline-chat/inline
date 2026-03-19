# Subthreads / Reply Threads Plan (Feedback Revision)

Date: 2026-03-12
Status: revised after product feedback
Supersedes direction in:
- `2026-03-12-graph-linked-subthreads-plan.md`
- `2026-03-12-nested-subthreads-child-chat-plan.md`
- `2026-03-12-reply-threads-subthreads-plan.md`

## Constraints This Revision Assumes

- subthreads are real chats
- nesting depth is unbounded
- reply threads are just subthreads anchored to a parent message
- the system may later support extra participants outside the parent space
- public-parent reply threads must inherit access from the parent chat because the parent may later become private
- linked reply threads should create a real per-user dialog on first open, but that dialog should stay hidden from sidebar lists until explicitly promoted
- live message updates should still behave like normal chats for access-eligible users who are online or viewing
- manual backlinks / references are a later feature, not part of the first subthread launch

## What The Current System Actually Does

This matters because some of the new behavior should extend current patterns, not replace them.

Current server behavior:

- `getChats` queries all accessible chats for the user and creates missing dialog rows for them
- `getChat` also creates a dialog row on open if one does not exist
- dialogs are the current source for sidebar rows, read max id, archive state, and notification overrides
- messages, history, replies, update buckets, and read APIs are all chat-scoped

Implication:

- top-level chat behavior already assumes "accessible chat => dialog"
- changing that globally would be a much larger product shift than subthreads require

So the safer direction is:

- keep top-level chat behavior mostly as-is
- make linked subthreads opt out of eager dialog creation

## Executive Summary

The revised recommendation is:

1. keep the primary structural parent on `chats`
2. use `parent_message_id` to distinguish reply-thread subthreads from plain subthreads
3. keep `chat_links` out of the core launch and reserve it for later reference/backlink relationships
4. use `parent_chat_id` as the inherited access source in v1
5. keep `chat_participants` as direct grants, not as a materialized union of inherited access
6. keep live message delivery chat-like
7. use dialogs as the durable per-user state container for linked subthreads, while decoupling dialog existence from sidebar visibility
8. keep follow/open-strategy out of the core v1 spec while still allowing hidden dialogs to carry full thread state
9. keep hidden-thread promotion logic centralized so product rules can change later without touching multiple read/send/open paths

This gives a clearer model than putting everything into a general graph table up front.

## Today MVP Focus

The immediate end-user UX target is narrower than the full future subthread feature.

Today’s target flow is:

- right click a message and choose `Reply in a Thread`
- create a subthread anchored to that message
- open the subthread as a real chat
- render the anchored message as a special first row in the subthread message list
- send messages inside the subthread
- support back navigation to the parent chat
- default the title to `Re: <initial part of message>`
- show a reply summary under the parent message like `2 replies`
- if unread state exists for that user, show a small unread dot there as well

User-ready stage-2 polish on top of that flow:

- opening or sending in a hidden reply thread must not auto-promote it into the sidebar
- add an explicit `Show in Sidebar` action backed by a dedicated RPC
- use a reply-thread glyph in sidebar/chat icons instead of the generic thread hashtag where possible
- render the anchor context like a real message row, with the `Replies` separator below it and the first date separator above the first actual thread message
- make the reply summary footer lighter-weight than embedded replies: no blue leading line, slightly wider, subtle hover state, trailing loading affordance while opening
- add a parent-thread open action from the reply-thread toolbar overflow menu
- on macOS, inherit reply-thread translation state from the parent thread when navigating in

For v1 realtime, that parent-message reply summary can continue to piggyback on the existing `editMessage` path rather than introducing a dedicated new update type immediately.

That means:

- reply-count changes and recent-replier changes update through the parent message edit path
- reply-thread unread-state changes can use the same centralized path in v1
- if read/unread churn in very large threads becomes too noisy later, this is the first candidate to split into a user-scoped summary update

This means the implementation should focus on reply-thread subthreads first, while still using the full data model that can support plain subthreads later.

## Full Model Ready, Narrow UI Surface

The schema and protocol should still be ready for:

- plain subthreads with `parent_message_id = null`
- infinite nesting through `parent_chat_id`
- inherited access through the `parent_chat_id` chain
- direct child participants through `chat_participants`

But today’s end-user UI does not need all of that exposed.

For the first slice, the visible product surface can stay limited to:

- message-anchored reply threads
- parent-message reply summary
- child-thread open/send/back flow

## Core Data Model

## `chats` Should Own The Primary Relationship

Add to `chats`:

- `parent_chat_id`
- `parent_message_id`
- optionally `root_chat_id` later if we want a cached lineage root

Semantics:

- top-level chat:
  - `parent_chat_id = null`
  - `parent_message_id = null`
- plain subthread:
  - `parent_chat_id = <parent chat>`
  - `parent_message_id = null`
- reply thread:
  - `parent_chat_id = <parent chat>`
  - `parent_message_id = <message in parent chat>`

This gives a built-in primary parent without requiring a general-purpose link table to also define structure.

## Why This Is Better Than Making `chat_links` Primary

Your feedback is right here.

If every structural relationship lives in `chat_links`, the system immediately has to answer:

- which edge is the real parent?
- which edge drives breadcrumbs?
- which edge drives inherited access?
- which edge decides if a chat is top-level or nested?

Putting the primary relation directly on `chats` removes that ambiguity.

The later graph/reference system can still exist, but it should be secondary.

## `chat_links` Should Be Deferred To Reference-Only Use

For the first subthread/reply-thread implementation, `chat_links` should not be required.

If added later, it should be for:

- backlinks
- additional manual references
- "also linked from here" relationships

Not for:

- primary parentage
- inherited access
- top-level filtering

That can all live on `chats`.

## Access Control Model

## Use `parent_chat_id` As The Inherited Access Source In V1

For the current scope, a separate `acl_chat_id` field is not required.

Reason:

- structure and inherited access are the same thing in the current design
- adding a second field now creates an invariant we do not yet need
- if structure and access diverge later, we can add a separate ACL source field then

Recommended rule:

- treat `parent_chat_id` as the source of inherited access
- if later we add generic references through `chat_links`, those links must not affect access

## Do Not Assume Access Is Bounded By Space Membership

Future support for extra participants outside the space means a child thread cannot assume:

- "all viewers are space members"
- or "space membership is the full effective audience"

A chat may still belong to a space organizationally through `space_id`, while access is widened with direct user grants.

That means space membership is not the final ACL ceiling.

If a child thread later includes participants from outside the space:

- the child thread should still keep the parent `space_id`
- `space_id` remains organizational context, not a hard ACL boundary

## Keep `chat_participants` As Direct Grants

This is the main revision to the earlier plan.

Do not split subthread-specific access into:

- inherited participants
- extra participants
- materialized effective participants

That is too fragile and too much bookkeeping for a first design.

Use this simpler rule instead:

- `chat_participants` means direct grants on that chat
- inherited access comes from `parent_chat_id`

Access check for a linked chat becomes:

1. if user is directly granted on this chat, allow
2. else if `parent_chat_id` is set, check inherited access through the parent chain only
3. else fall back to the chat's own normal access model

This preserves a clean mental model:

- direct grants live on the child
- inherited grants come from the structural parent chain
- direct grants are scoped to the child thread and remain valid for the child even if they are not present on the parent
- direct grants on a child do not automatically propagate to that child's descendants

No union table is needed.

Important clarification:

- descendants inherit only from the ancestor chain's inherited scope
- descendants do not inherit intermediate child-local direct grants unless those users are also directly granted on the descendant

That keeps "extra participants on this child are scoped to this child" true even with infinite nesting.

## Why This Handles Public -> Private Correctly

If a reply thread under a public thread inherits through `parent_chat_id`, then:

- while parent is public, child inherits public access
- if parent later becomes private, child automatically becomes private-inherited too

That is exactly the behavior you called out.

This is stronger than copying public eligibility at creation time.

## DM / Self Parent Rule

Keep the previous recommendation:

- a subthread under a DM or self-chat should still be stored as `type = thread`

Reason:

- it may later grow beyond two users
- it needs normal thread identity and routing
- it should not be forced through DM min/max-user semantics

Inherited access still comes from the DM parent via `parent_chat_id`.

## Security Rule For Reply Anchors

If a child has direct participants who cannot access the parent chat, the anchored parent message row may still be shown inside the subthread.

Recommended rule:

- if the anchored parent message is present, it is acceptable to show it to subthread users inside the child thread
- this is allowed even when the viewer is present only through child-thread participation

But this is not a blocker for the core subthread model in the current plan.

## Dialog / Sidebar Model

## What Should Stay The Same

For top-level chats:

- keep current `getChats` behavior for now
- new users should still get sidebar dialogs for top-level accessible chats

That avoids a much larger sidebar redesign during subthread rollout.

## What Should Change For Linked Subthreads

Linked subthreads should not be eagerly dialog-created for every access-eligible user.

Instead, a linked subthread should create a dialog only when a user explicitly opens that thread or otherwise performs an action that needs durable per-user thread state.

Opening a linked subthread should create a hidden dialog row for that user on first open.

This keeps subthreads from flooding the sidebar while preserving top-level behavior and reusing the existing dialog-backed state model.

## Do Not Add Follow State To The Core Spec Yet

`following` and `open_when` are not required for the core subthread implementation.

For v1, the relevant durable per-user primitives are:

- dialog exists
- dialog sidebar visibility is explicit

If a linked subthread has a dialog for a user:

- it can accumulate unread
- it can store read position
- it can be archived/unarchived
- it can be pinned/unpinned
- it can use the existing dialog notification settings

If that dialog is `sidebar_visible = true`:

- it appears in sidebar and home lists

If that dialog is `sidebar_visible = false`:

- it stays hidden from sidebar and home lists
- it is still the durable state container for that user's thread state

If a linked subthread has no dialog for a user:

- it has no durable per-user state yet

This is enough for the feature you are currently specifying while keeping the semantics clean.

## Realtime, Unread, And Delivery

## Keep Live Message Delivery Chat-Like

The earlier plan was too aggressive in tying live delivery to a separate follow concept.

Revised rule:

- access-eligible users can still receive normal live message updates
- dialog existence controls durable unread/archive/read state
- sidebar surfacing is controlled by explicit dialog visibility
- pin remains dialog-level UI state and does not need a separate follow concept

This preserves the important current-chat behavior:

- a user viewing a subthread should not lose live updates just because they do not have a dialog

## Durable State Should Be Dialog-Gated

For linked subthreads:

- no dialog row:
  - no durable per-user thread state exists yet
- hidden dialog row exists:
  - normal unread/read/archive/pin/notification semantics apply
  - the thread remains absent from sidebar and home lists
- visible dialog row exists:
  - normal unread/read/archive/pin/notification semantics apply
  - the thread can appear in sidebar and home lists

Design note:

- hidden dialogs should be promotable to visible later without changing the underlying thread-state model

This is the line that keeps sidebars from blowing up while preserving real thread state.

## Current `getUpdateGroup` Implication

Current server code still thinks in terms of "all accessible users receive chat updates."

That can remain acceptable for live message pushes in v1, but it becomes a performance concern for heavily nested subthreads.

So the plan should be:

- keep live updates broadly chat-like first
- keep durable unread behavior dialog-gated
- keep sidebar surfacing gated by explicit dialog visibility
- later optimize live fanout if subthread scale makes it necessary

## Dialog Creation Triggers

For linked subthreads, durable dialog rows should be created only when one of these is true:

- the user explicitly opens the subthread
- the user pins the subthread
- the user explicitly asks to show the thread in sidebar later

Additional automatic creation triggers such as creator, anchor author, reply target author, or `@` mention can be added later if product needs them, but they should not be part of the lowest-risk v1.

When a dialog is created by first open, it should default to hidden from sidebar.

This is the v1 dialog-materialization policy for linked subthreads.

## API Recommendation

## Keep RPC Additions To The Minimum Required

The default approach should be:

- add the smallest number of new RPCs
- add the smallest number of new args
- reuse existing chat-scoped methods wherever possible

## Required Wire Additions For The Reply-Thread MVP

Even with a minimal RPC surface, the MVP still needs a few protocol/data additions:

- extend `Chat` with `parent_chat_id` and `parent_message_id`
- add `createSubthread`
- allow `GetChatResult` to represent "chat opened and hidden dialog created on first open"
- expose reply-thread summary on parent messages so the row can render `2 replies` and an unread dot

Recommended extra result field for UX simplicity:

- `GetChatResult.anchor_message`

Why:

- the child thread can render the anchored parent message as a special first row without an extra fetch
- this avoids adding a new RPC just to load the anchor row

If we want to keep the wire even tighter, the client can fetch the anchor through existing message fetch APIs after opening the child chat, but that costs an extra roundtrip.

## One Clearly Required Creation RPC

You are right that `createLinkedThread` and `createReplyThread` are unnecessary as separate concepts.

Use one creation RPC:

- `createSubthread`

Input:

- `parent_chat_id`
- optional `parent_message_id`
- chat metadata
- optional participants / direct grants

Meaning:

- no `parent_message_id` => plain subthread
- `parent_message_id` set => reply thread

This matches the product model:

- reply thread is just a message-anchored subthread

## Fetch / Open

Keep existing chat-scoped RPCs:

- `getChat`
- `getChatHistory`
- `sendMessage`
- `readMessages`
- `searchMessages`

For v1, do not add more RPCs unless the UI proves it cannot work without them.

Recommended default:

- open a known subthread via existing `getChat`
- load subthread history via existing `getChatHistory`
- rely on dialog-backed discovery in sidebar for subthreads that already have dialogs
- rely on parent-context metadata in existing payloads where needed

## `getSubthreads` Is Optional, Not Required

If parent-context discovery cannot be carried cleanly by existing payloads, then add:

- `getSubthreads(parent_chat_id, parent_message_id?)`

But that should stay a second-step addition, not part of the core RPC set by default.

Manual reference-link RPCs can also wait for later.

## Future Manual Links / References

This should stay out of the core implementation for now.

Later, if we want generic references/backlinks:

- add a `chat_links` table
- add `linkSubthread` / `unlinkSubthread` RPCs
- optionally expose special message rows with custom subthread-link rendering

That future system should layer on top of the primary parent fields already stored on `chats`.

## Discovery And Sidebar Shape

## Current Top-Level Discovery Can Stay Mostly Intact

Because `getChats` already creates dialogs for top-level accessible chats, a new user can still discover:

- DMs
- top-level threads
- public/private/home threads they are allowed to access

That part does not need a redesign for the first subthread launch.

## Linked Subthread Discovery Should Be In-Context First

Linked subthreads should initially be discoverable through:

- parent message reply-thread affordances
- parent chat "subthreads" section
- direct open from a known chat id

Not through:

- automatic inclusion in the full accessible sidebar list

This is the simplest way to avoid clutter while keeping the rest of the app stable.

## Special Message Rows

For the reply-thread MVP, the anchored parent message should be rendered as a special first row in the child thread message list.

This is preferable to a separate header because:

- it keeps the anchor in the same scroll model as the child timeline
- it reuses message-row rendering patterns
- it makes back navigation and message-list layout simpler

Your note about a special empty-content message type is also good and fits a later phase.

That could become the main in-chat affordance for plain subthreads that are not tied to a reply anchor.

It does not need to change the base subthread model.

## Implementation Phases

### Phase 0: Lock invariants

Agree on:

- `parent_chat_id` is the primary structural parent
- `parent_message_id` means "this subthread is also a reply thread"
- `parent_chat_id` is also the inherited access source in v1
- `chat_participants` are direct grants only
- DM-born subthreads use `type = thread`
- linked subthreads do not get eager dialogs for all access-eligible users
- linked subthreads create hidden dialogs on first open

### Phase 1: Schema + proto

- add `parent_chat_id` and `parent_message_id` to `chats`
- extend `Chat` encode/model to carry parent metadata

### Phase 2: Server access + creation

- implement `createSubthread`
- update access checks to allow direct grant or inherited access through `parent_chat_id`
- validate anchored reply threads against parent message existence

### Phase 3: Dialog semantics

- stop eager dialog creation for linked subthreads in general listing flows
- opening a linked subthread creates a hidden dialog row for that user
- keep linked-subthread dialogs hidden from sidebar until explicitly promoted
- use dialogs as the durable per-user state container for read/unread/archive/pin/notification state

### Phase 4: UI

- message-level "open reply thread"
- chat-level "open/create subthread"
- render the anchored parent message as a special first row in the child message list
- support standard back navigation to the parent chat

### Phase 5: Future reference links

- add `chat_links` for manual backlinks / references
- optionally add special subthread-link messages

## Major Risks

### 1. Anchor preview semantics

Child-only participants may not have parent access.

That can be handled later at the presentation layer and should not block the core thread/access/dialog model.

### 2. Ambiguous open behavior

Resolved:

- opening a linked subthread creates a hidden dialog row on first open
- dialog existence is the durable state boundary
- sidebar visibility is a separate dialog flag
- pin does not imply any separate follow concept

The implementation should still leave room to promote hidden dialogs into visible sidebar items later if product semantics change.

### 3. Fanout / performance

Keeping live updates chat-like means nested subthreads can still increase message fanout costs.

This is acceptable initially.

The important requirement is that the core model stays optimization-friendly:

- inherited access must remain explicit through the structural parent chain
- child-local direct grants must remain non-transitive
- dialog state must stay separable from raw chat access
- live fanout can be optimized later without changing the data model

### 4. Sidebar query drift

Current `getChats` is access-driven and dialog-creating.

Linked subthreads need opt-out behavior there, otherwise the sidebar will fill up immediately.

## Bottom Line

The revised best plan is:

- store primary subthread structure on `chats`
- use `parent_message_id` to make a subthread also be a reply thread
- use `parent_chat_id` for inherited access in v1
- keep `chat_participants` as direct grants only
- keep top-level dialog/sidebar behavior mostly unchanged
- avoid eager dialogs for linked subthreads
- create hidden linked-subthread dialogs on first open
- keep live message updates chat-like
- gate durable unread/archive behavior on dialog existence
- gate sidebar surfacing on explicit dialog visibility
- keep follow/open-strategy out of the v1 subthread spec

That is simpler, less ambiguous, and closer to the product constraints you clarified.

# Async Chat Open With Delayed Route Commit

## Goal
- Keep UI responsive during chat open.
- User click should be acknowledged immediately.
- Keep showing current route while new chat data preloads in background.
- Commit route change only when chat payload is ready, so first render is instant.

## Desired UX
1. User clicks a chat in sidebar.
2. Sidebar immediately shows pending selection state (pressed/loading).
3. Current route remains visible and interactive (no hang).
4. Once preload is ready, route switches to target chat and renders instantly.
5. If user clicks another chat before ready, old preload is canceled and replaced.

## Scope
- macOS new UI path (`Nav2`, `MainSidebarList`, `MainSidebarItemCell`, `MainSplitView`, `ChatViewAppKit`, message view model bootstrap).
- Do not change server/API behavior.

## Phase 1: Navigation Coordination
- Add pending chat-open state to `Nav2`:
  - `pendingChatPeer: Peer?`
  - `pendingChatToken: UUID?` (for stale result rejection)
- Add API in `Nav2`:
  - `requestOpenChat(peer:)` async
  - Starts background preload task, sets pending state, commits `navigate(to: .chat(peer:))` only when preload finishes.
- Ensure history semantics remain unchanged:
  - Only final committed route is recorded in history.
  - Pending state is not a route entry.

## Phase 2: Preload Pipeline
- Introduce a `ChatOpenPreloader` actor/service in macOS layer.
- Preload operations (off main):
  - Fetch minimal chat header payload needed to build chat screen.
  - Fetch initial message window for target peer (same ordering/window as current message list first render).
- Return `PreparedChatPayload` keyed by peer/token.
- Handle cancellation:
  - New request cancels prior task.
  - Completed stale token is ignored.

## Phase 3: View Construction From Prepared Payload
- Extend `ChatViewAppKit` init to accept optional `PreparedChatPayload`.
- If payload exists:
  - Skip blocking fetch path in init.
  - Render directly from prepared data.
  - Start observation/refetch asynchronously after initial render.
- Keep fallback path for cold/missed payload.

## Phase 4: Sidebar Immediate Feedback
- Use `Nav2.pendingChatPeer` to show pending highlight/loading affordance in sidebar cells.
- Keep existing selected-route highlight behavior once route commits.
- Prevent flashing between old/new selection during pending state.

## Phase 5: Guardrails
- Add timeout fallback (for example, 300-500ms):
  - If preload is slow, either continue waiting (strict mode) or commit route with spinner fallback.
  - Default should be strict mode if UX goal is "switch only when ready."
- Preserve keyboard navigation semantics (next/prev chat should use same request path).

## Instrumentation
- Add signposts:
  - `ChatOpenClick`
  - `ChatPreloadStart/End`
  - `ChatRouteCommit`
  - `ChatFirstRender`
- Track:
  - click-to-commit latency
  - commit-to-first-render latency
  - main-thread blocked time during click-to-commit window

## Risks
- Duplicate work if prepared payload is not consumed by `ChatViewAppKit`.
- State races when users click rapidly.
- Route/history edge cases on back/forward if pending request completes late.

## Rollout
1. Behind a local feature flag.
2. Validate with sidebar switching trace.
3. Compare before/after:
  - `MainSplitView.setContentArea`
  - `SQLQueryGenerator.makeStatement`
  - `StatementAuthorizer.authorize`
  - frame drops during rapid switching.

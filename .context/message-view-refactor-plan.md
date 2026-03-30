# UIMessageView Reuse Refactor Plan

## Goal
Make `UIMessageView` reusable and cheaper to configure by establishing a clear, deterministic configuration flow and minimizing subview churn. The end state should allow `MessageCollectionViewCell` to reuse a single `UIMessageView` instance and update it efficiently when data changes.

## Constraints / Non-Goals
- Do not change message rendering semantics or visual layout.
- Avoid unsafe casts/force unwraps; keep concurrency safe.
- Keep ID types as `Int64`.

## Proposed Architecture
1. **Introduce a stable configuration model**
   - Add `UIMessageView.Content` (or `MessageViewConfiguration`) that contains:
     - `displayText`, `entities`, `outgoing`, `hasMedia`, `hasAttachments`, `reactions`, `isSticker`, etc.
     - Derived flags: `isMultiline`, `shouldShowFloatingMetadata`, `showReactionsInside/Outside`.
   - Provide a single `build(from: FullMessage)` factory, so all decision logic is in one place.

2. **Single construction, multi-update**
   - `UIMessageView` creates all persistent container views in `init` and never re-creates them.
   - Add `configure(with content: Content)` to apply changes via `isHidden`, `alpha`, and data updates.
   - Add `prepareForReuse()` to reset transient state (shine, gesture state, temporary overlays).

3. **View ownership & pooling**
   - Use one container stack and swap arranged subviews by enabling/disabling instead of re-creating.
   - Pool reaction views or reuse `ReactionsFlowView` with `configure` only.
   - Create attachment subviews lazily but keep references once created; toggle visibility thereafter.

4. **State and identity checks**
   - Maintain a `lastConfigKey` (hash of `Content`) to short-circuit redundant updates.
   - Keep separate state for `translationState` so the coordinator can update it without reconfiguring content.

5. **Layout and constraints**
   - Move all constraints to `init` or one-time setup methods.
   - Replace per-update constraint churn with constraint activation toggles, or `isHidden` + stack spacing adjustments.
   - Prefer `setNeedsLayout()`; use `layoutIfNeeded()` only inside specific animations.

6. **MessageCollectionViewCell integration**
   - Create `messageView` once in `init`.
   - Replace `setupBaseMessageConstraints()` with a one-time layout + `configure` call.
   - Use `prepareForReuse()` to clear UI state without removing views.

## Implementation Steps
1. Create `UIMessageView.Content` + builder (from `FullMessage`).
2. Add `configure(with:)` + `prepareForReuse()` to `UIMessageView`.
3. Refactor `MessageCollectionViewCell` to keep a single `UIMessageView` instance and call `configure`.
4. Remove now-redundant `setupMessageContainer` and move decisions into `Content`.
5. Add small sanity tests or debug assertions for config key mismatches (optional).

## Progress (2026-01-06)
- [x] Content model + builder with derived flags and dependency comments.
- [x] UIMessageView build-once + configure/prepareForReuse path.
- [x] Constraint sets/toggles for bubble/container layout.
- [x] MessageCollectionViewCell reuse + constraint updates.
- [x] Replace ad-hoc prints with Logger in touched files.
- [x] Fix UIMessageView compile errors (InlineProtocol import, attachmentSignature typing).
- [ ] Coordinator/size cache follow-up.
- [ ] Manual validation on message variants + Instruments pass.

## Expected Benefits
- Fewer allocations and less constraint churn during fast scrolling.
- Clearer control flow (one configuration path, fewer side effects).
- Easier to reason about updates and state resets.

## Risks / Mitigations
- Risk of incorrect visibility toggles → mitigate by snapshotting current output and verifying with UI tests.
- Risk of stale attributed text or metadata → use config key + explicit field updates.
- Risk of regression in tap handling → keep gesture wiring centralized and unchanged.

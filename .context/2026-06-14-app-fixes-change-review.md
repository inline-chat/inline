# App Fixes Change Review

Date: 2026-06-14

## Goal

Review every change from the app-fixes session one by one, record progress, and separate blocking findings from follow-up quality notes.

## Progress

- [x] Shared/server behavior changes
- [x] macOS menu/window/message changes
- [x] iOS compose/message/browser/history changes
- [x] Final validation summary

## Findings

No blocking findings found in this review.

Non-blocking follow-ups:

- `ChatParticipantsWithMembersViewModel` now observes all local direct chats for mention-candidate refreshes. That matches the product behavior, but large accounts may make this observation noisier than needed. Profile candidate refresh frequency before broadening the feature further.
- `TargetMessagesFetcher.ensureCachedOnce` intentionally remembers attempted message ids for the actor lifetime. This prevents deleted-message loops, but the set is unbounded across a long app session. Consider pruning per target or adding a small cap if this becomes visible in memory traces.
- The iOS edit-animation fix is structurally correct, but still needs manual visual smoke testing because the automated checks can only prove buildability and snapshot safety, not whether the collection-view animation feels right.
- macOS message hit-testing now has a narrower implementation, but there is still no automated hit-test harness for action rows and URL preview attachments.

## Review Notes

- macOS Edit menu: native Writing Tools, speech, dictation, and Emoji & Symbols menu items are routed through AppKit/responder-chain selectors. The Emoji item targets `NSApp`, which is the correct native character-palette route.
- Mention autocomplete: source-aware candidates dedupe by user id, preserve participant/space-member priority, omit direct chats on bare `@`, and filter direct chats with missing or zero `lastMsgId`.
- Global search: whitespace-only input short-circuits, human users still match partially, and bots only pass an exact case-insensitive username predicate.
- Bot limit: the new exported `MAX_BOTS_PER_USER` constant keeps implementation and test in sync.
- macOS window size/position: the default main window now uses an AppKit frame autosave name after first-run sizing/centering; restored scenes still rely on existing restoration state.
- macOS message actions/link previews: action buttons now own their full pill hit area, and attachment stacks only return arranged child hits instead of blank stack whitespace.
- Minimal message sizing: minimal mode no longer treats the timestamp as part of content flow for reaction placement, and large emoji sizing remains available for reply-thread summaries without applying ordinary emoji-only layout rules.
- iOS compose plus button: iOS 26 uses `UIButton.Configuration.glass()` behind an availability gate with no layer clipping; earlier iOS keeps the clipped fallback.
- Inbox sidebar default: `UserDefaults.register(defaults:)` changes only the default for users without an existing stored value.
- iOS link haptics: haptics fire when the URL/text/link-preview context menu is actually presented.
- iOS in-app browser: SFSafariViewController sheet detents are limited to `.large()`, so there is no half-height stop.
- Missing replied messages: reply placeholders trigger a detached utility task that goes through the actor-backed one-shot fetcher and async database lookup.
- iOS remote older history: the coordinator mirrors macOS remote history fallback, blocks duplicate in-flight cursor requests, records empty remote boundaries, and forces a local async older load only after a non-empty remote result is saved.
- iOS reply-thread pill: height/title/color/spacing changes are internally consistent and keep dynamic type enabled.
- iOS edit updates: edit publishers now request animated updates, and the collection view reloads visible items only when animation was explicitly requested.
- Validation reviewed from the implementation pass: focused InlineKit tests, server bot/search tests, iOS build, macOS build, and touched-file `git diff --check` all passed. `server` typecheck remains blocked by pre-existing workspace issues.

# App Fixes Progress Plan

Date: 2026-06-13

## Goal

Implement the requested macOS, iOS, shared Swift, and server fixes one by one, with focused validation for each affected area.

## Checklist

- [x] macOS Edit menu: restore native Emoji & Symbols, Writing Tools, dictation, speech, spelling/substitution/transform commands, and their shortcuts through the native responder chain.
- [x] Mention autocomplete: hide user chats without messages, prioritize current participants and space members, and only include other chatted users once the query starts matching.
- [x] Global search: hide bots by default and only show bot users on an exact username match.
- [x] Bot limits: raise the per-user bot creation cap from 5 to 25.
- [x] macOS window state: verify native position/size restoration and compare Ghostty if the current approach is weak.
- [x] Message click handling: carefully harden action button and link-preview hit registration without regressing text/link gestures.
- [x] Minimal message layout: fix brittle sizing around large emoji with reactions and reply-thread summaries.
- [x] iOS compose: make the plus button use native circular glass and avoid parent clipping.
- [x] Sidebar default: make inbox-mode sidebar default for new macOS installs.

## Validation Plan

- Run focused Swift tests for shared mention/message sizing helpers when touched.
- Run focused server tests for bot limit and search behavior.
- Run focused Swift build/typecheck for touched Apple packages where practical.
- Launch macOS app after menu/window/message UI changes if the build is healthy.

## Validation Log

- `xcrun swift test --package-path apple/InlineKit --filter MentionCompletionViewModelTests` passed.
- `xcrun swift test --package-path apple/InlineKit --filter TargetMessagesFetcherTests` passed.
- `cd server && bun test src/__tests__/functions/createBot.test.ts src/__tests__/methods/searchContacts.test.ts` passed.
- `xcodebuild -project apple/Inline.xcodeproj -scheme "Inline (iOS)" -configuration Debug -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build` passed with existing warning noise.
- `xcodebuild -project apple/Inline.xcodeproj -scheme "Inline (macOS)" -configuration Debug -destination "generic/platform=macOS" CODE_SIGNING_ALLOWED=NO build` passed with existing warning noise.
- `git diff --check -- <touched files>` passed.
- `cd server && bun run typecheck` failed on existing broad workspace issues: missing built declaration outputs for packages such as `packages/protocol/dist` plus unrelated implicit-`any` errors in older tests/modules.

## Window Restoration Notes

- Inline already uses `NSWindowRestoration` for route state and AppKit launch restoration.
- Ghostty uses AppKit restoration for full terminal state, plus a custom last-window frame cache for normal new-window placement.
- Inline's default main window did not have an AppKit frame autosave name, so non-restoration launches could still recenter. Added native frame autosave for the default main window only.

## Follow-Up Candidates

- `MessageViewAppKit` and `MinimalMessageViewAppKit` still duplicate a large amount of gesture, hit-test, reaction, attachment, and reply-thread plumbing. Extract shared interaction/layout helpers once the current message-view WIP settles, so future fixes do not need two hand-edited copies.
- `MessageSizeCalculator` lives in the macOS app target, so focused Swift package tests cannot cover minimal-mode layout regressions. Consider moving pure layout math into a package-level helper or adding app-target unit coverage for large emoji, reactions, reply-thread summaries, and action rows.
- `MessageAttachmentsView` now has explicit child hit testing, but there is no automated interaction coverage for URL preview/action-row click targets. Add a small AppKit hit-test test harness or preview-only test before the next round of interaction changes.
- `server` typecheck currently fails before this change can be evaluated cleanly because generated package declaration outputs are missing and older files have implicit-`any` errors. Fixing the baseline would make server-side changes safer to validate.
- Apple app builds pass, but these UI paths still need manual smoke testing for native Edit menu shortcuts, message hit targets, iOS link menus, remote history loading, and edited-message animations.
- The Xcode builds surface existing SwiftProtobuf generated-code deprecation warnings and Swift concurrency warnings in older message-view/share-extension code. Regenerating protos and cleaning the concurrency warnings would reduce future signal noise.

## Added Next Items

- [x] iOS links: add haptic feedback when a long-press presents the link menu.
- [x] iOS in-app webview: remove the half-height sheet detent so it is either open or dismissed.
- [x] Replies: add an async one-time `ensureMessage` gap fill for unloaded replied messages without sync DB reads, retry loops, or repeated deleted-message fetches.
- [x] iOS messages: bring the macOS remote load-more behavior to iOS.
- [x] iOS reply thread pill: polish it closer to macOS and make it slightly taller.
- [x] iOS edited messages: find why collection-view message update patches are not animated and fix it.

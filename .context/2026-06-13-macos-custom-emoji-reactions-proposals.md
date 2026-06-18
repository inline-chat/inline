# macOS Custom Emoji Reactions Proposals

Date: 2026-06-13

## Goal

Add a trailing option to the macOS quick reaction list that opens an emoji picker, lets the user choose an emoji, and applies it as a reaction to the target message.

This assumes "custom emoji reaction" means "any user-selected Unicode emoji" rather than workspace-uploaded Slack-style custom image emoji. If product wants uploaded custom emoji assets, see Proposal 3.

## Current Shape

- `ReactionOverlayView` owns the fixed quick reaction list and sends add/delete through `Api.realtime.send(.addReaction/.deleteReaction)`.
- `ReactionOverlayWindow` is a floating borderless `NSPanel` opened from both `MessageViewAppKit` and `MinimalMessageViewAppKit`.
- Context menu "Add Reaction..." and long press both route to the same overlay.
- Double click has a separate hardcoded ack reaction path using `✔️`.
- `EmojiPanelPicker` already bridges to macOS Emoji & Symbols with a hidden `NSTextView`, and `EmojiTextFieldPicker` wraps it for chat icons.
- Protocol and storage already represent reactions as `string emoji`; the server stores this in a `text` column with a unique `(chatId, messageId, userId, emoji)` constraint.

## Proposal 1: Native Emoji & Symbols Panel From The Quick Picker

Add a trailing icon button to `ReactionOverlayView` after the default reactions. Clicking it opens the macOS Emoji & Symbols panel using a reusable version of `EmojiPanelPicker`.

Implementation shape:

- Move `EmojiPanelPicker` out of `Views/NewChatScreen` into a reusable macOS component location, or extract the AppKit receiver into `EmojiPanelSelectionBridge`.
- Add `onEmojiPickerRequested` / `onEmojiSelected` to `ReactionOverlayView`.
- Add a trailing plain icon button, probably `plus` or `face.smiling`, with help text like "More reactions".
- On selection, normalize to the first `Character`, validate it is emoji, then call a shared `toggleReaction(emoji:fullMessage:)`.
- Keep the hidden receiver alive until selection. Prefer anchoring it to the source message window or a small coordinator object rather than relying on the overlay panel staying alive.
- Close the reaction overlay after a valid selection.

Pros:

- Smallest product change and closest to the requested UI.
- Uses native macOS picker, search, skin tone variants, recents, and keyboard behavior without building any of that.
- No protocol, server, database, or cross-platform data change for Unicode emoji.
- Fits the existing `EmojiTextFieldPicker` direction and can reuse proven code.

Cons / risks:

- The system character palette is app-global and responder-chain driven; positioning and lifecycle are less deterministic than an in-app picker.
- The existing hidden-text-view bridge filters non-ASCII, which is too loose for reactions. It should validate actual emoji clusters before sending.
- If the receiver lives inside the overlay panel and the overlay closes on outside click, the selection callback can be lost. This needs explicit lifecycle handling.
- Does not support uploaded custom image emoji.

Engineering risk: medium-low if the receiver lifecycle is handled deliberately; medium if mounted naively inside the overlay.

## Proposal 2: Build An Inline Emoji Picker In The Reaction Overlay

Keep the user inside Inline's reaction panel. The trailing option expands the existing overlay into a picker view, or opens a second Inline-owned `NSPanel`, with a search field and grid of emoji sourced from `EmojiAutocompleteData`.

Implementation shape:

- Create `ReactionEmojiPickerView` with sections for recent/default emoji, a search field, and a grid.
- Use `EmojiAutocomplete.suggestions(matching:)` for search.
- For browsing, either expose `EmojiAutocompleteData.rawEntries` through a public API or add a small curated category model.
- Add keyboard navigation, return-to-select, escape-to-close, and mouse hover states.
- Persist recent reaction choices locally, likely under app settings/user defaults.
- Reuse the same shared `toggleReaction(emoji:fullMessage:)` path.

Pros:

- Fully controlled lifecycle, positioning, keyboard behavior, and visual design.
- Easier to make the quick picker feel like Inline instead of handing users to the system palette.
- Can be extended later with recent reactions, frequently used emoji, per-space defaults, or uploaded custom emoji results.
- Does not depend on private-ish palette window discovery and AppKit character palette behavior.

Cons / risks:

- More work than the requested trailing button implies.
- We would need to implement or expose browse data; current autocomplete data is optimized for search, not a polished categorized picker.
- Skin tone, variants, accessibility names, search ranking, and keyboard navigation are product details we would own.
- Risk of building a less capable picker than macOS already provides.

Engineering risk: medium. UX quality risk: medium unless we spend enough time on categories, search, and keyboard support.

## Proposal 3: First-Class Uploaded Custom Emoji Reactions

Treat "custom emoji" as workspace/server-managed custom emoji assets, not just arbitrary Unicode emoji. This means reactions need an identity richer than `string emoji`.

Implementation shape:

- Add a reaction target model, for example `ReactionValue { unicode: String } | { customEmojiId: Int64 }`.
- Update proto, generated Swift/TS, server DB schema, reaction encoders, SDK/bot API types, and clients.
- Add custom emoji asset storage, permissions, CDN/file loading, caching, and rendering in reaction chips.
- Build or extend the picker to search both Unicode emoji and uploaded custom emoji.
- Migrate or keep backward-compatible handling for existing `emoji` string reactions.

Pros:

- Correct model if Inline wants Slack/Discord-style custom emoji.
- Enables workspace culture/custom assets and richer future reactions.
- Avoids overloading a plain string with custom asset identifiers.

Cons / risks:

- Much larger than this macOS UI change.
- Touches protocol, server, Apple clients, TS SDKs, bot API, sync, rendering, caching, and migration behavior.
- Requires product and moderation decisions around upload, permissions, deletion, and fallback rendering.
- Not needed for "pick any Unicode emoji" reactions.

Engineering risk: high. Product scope: high. This should be a separate project.

## Proposal 4: Staged Hybrid

Implement Proposal 1 now, but shape the code so Proposal 2 or 3 can replace the picker later without rewriting reaction sending.

Implementation shape:

- Introduce a small shared reaction action helper for macOS, for example `MessageReactionActions.toggle(emoji:fullMessage:)`.
- Use it from `ReactionOverlayView`, reaction chips, and eventually the double-click ack path where practical.
- Add the trailing picker option using the native Emoji & Symbols panel.
- Persist recent custom selections after a successful send, then optionally replace least-useful fixed defaults or show recents before the fixed defaults.
- Keep picker invocation behind a narrow protocol/callback like `requestEmojiSelection(anchor:onSelect:)`.

Pros:

- Delivers the requested feature quickly while reducing duplicated reaction logic.
- Avoids locking the product into the system picker.
- Lets us learn from usage before building a full picker.
- Keeps the backend/protocol unchanged for Unicode emoji.

Cons / risks:

- Slightly more structure than a one-file patch.
- Still inherits the native picker lifecycle issues for V1.
- Does not solve uploaded custom emoji assets by itself.

Engineering risk: low-medium. This is the best balance for a Unicode emoji V1.

## Evaluation

| Criterion | Proposal 1: Native Panel | Proposal 2: Inline Picker | Proposal 3: Uploaded Custom Emoji | Proposal 4: Staged Hybrid |
| --- | --- | --- | --- | --- |
| Ships trailing picker option quickly | High | Medium | Low | High |
| Native macOS feel | High | Medium | Low-medium | High |
| Lifecycle/control reliability | Medium | High | Depends on picker | Medium |
| Unicode emoji coverage | High | Medium-high | Medium-high | High |
| Uploaded custom emoji support | None | Future-friendly | High | Future-friendly |
| Backend/proto changes | None | None | Required | None for V1 |
| Implementation cost | Low-medium | Medium-high | High | Medium |
| Maintenance cost | Low | Medium | High | Low-medium |

## Recommendation

Use Proposal 4 for V1: add the trailing "more reactions" option backed by the native Emoji & Symbols panel, but first extract the reaction toggle/send path and the emoji selection bridge enough that the overlay is not tightly coupled to AppKit palette quirks.

The important implementation detail is receiver lifetime. Do not mount the hidden `NSTextView` only inside an overlay that may close before the character palette returns a selection. Either keep the overlay open while the palette is active and ignore palette-window clicks, or create a small selection coordinator owned by the source message/main window until selection/cancel.

## Suggested V1 Checklist

- Extract `toggleReaction(emoji:fullMessage:)` from `ReactionOverlayView` into a tiny shared helper.
- Add client-side validation that selected text is a single emoji grapheme cluster.
- Refactor `EmojiPanelPicker`/receiver into a reusable component outside `NewChatScreen`.
- Add the trailing button to `ReactionOverlayView.defaultReactions` UI, not to the reaction data list.
- Ensure the overlay dismisses after selection and still dismisses on Esc/outside click when the picker is not active.
- Verify both `MessageViewAppKit` and `MinimalMessageViewAppKit` entry points.
- Add a focused manual test for: long press -> plus -> select emoji; context menu -> Add Reaction -> plus -> select emoji; selecting an emoji already reacted by the current user toggles it off or avoids duplicate insertion.

## Production Readiness Notes

- Security risk is low for Unicode V1, but we should validate and cap emoji input length before sending. The server currently accepts arbitrary reaction strings.
- Performance risk is low if we use the native picker. An inline grid should avoid loading/rendering all emoji cells repeatedly inside message rows.
- Backward compatibility is good for Unicode V1 because the wire format and DB already store reaction emoji as strings.

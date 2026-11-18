# Emoji

Everything emoji for the web app, as one feature other code plugs into: the data, search and ranking, usage (frecency, reaction picks, skin tone), the reaction picker, the full picker, the composer's `:` suggestions and emoji button, and helpers for drawing reactions. Ported from the Mac app (`apple/InlineUI/Sources/EmojiAutocomplete/`, `ReactionPickerEmojis/`, `TextProcessing/EmojiPickerData.swift`, `apple/InlineMac/Views/Components/EmojiPickerPopover2.swift`, `apple/InlineMac/Views/ReactionPicker/ReactionOverlayView.swift`); the tests cite the Swift lines each rule comes from.

Lab: `web/lab-emoji.html` (`src/lab/emoji/`). `?theme=dark&dir=rtl&width=narrow&usage=empty&tone=medium&open=reaction|reactionFull|composer&q=heart`. `globalThis.__emojiLab` is a snapshot (open pickers, each picker's query, active cell, active tab, columns, rendered rows and cells from the DOM, the quick row, the composer's suggestions, a search table, `activeElement`, and `focusIn`: `"reaction"`, `"composer"`, `"inline"` (the inline quick row) or `"page"`, where focus is); `globalThis.__emojiLabControl` drives it (`openReaction` (looks the Add Reaction button up when the picker opens), `expandReaction(q)`, `openComposerPicker`, `setQuery(picker, q)`, `pickerKey(picker, key, from)`, `key(name)` at the focused element, `scrollInline(y)`, `selectTab`, `search(q)`, `typeComposer(text)`, `acceptSuggestion(i)`, `setTheme`, `setDir`, `setWidth`, `setTone`, `resetUsage`).

## Three chunks

| Part | Import | Contents | Size (gzip, minified) |
| --- | --- | --- | --- |
| Light half | `features/emoji` (`index.ts`) | services and loader, usage store, tones, quick reaction rules and set, `:` source, drawability check, display helpers | 4.9 KB |
| Pickers | `import("features/emoji/chunk")` | picker, reaction picker and composer button controllers and views | 10.3 KB before StyleX extraction |
| Data | loaded by `services.loader.load()` (`import("./engine")`) | the table (1,898 base emoji) and the search engine | 44.8 KB |

Measured with `bun build --splitting --minify` on these files with `@inline/*`, React and StyleX external (no `vite build` in this run). The data chunk never reaches the initial bundle: only `services.ts` names it, inside `import()`. The light half is small, but the wiring below keeps even it out of the initial bundle.

## Data (`data/`, generated)

`web/tooling/emoji/generate.ts` reads the Swift sources (data only: the generated table, the alias dictionary, the popularity list, the section boundaries, the quick set) and writes:

- `data/emoji-data.generated.ts`: `EMOJI_ROWS`, one string, a row per base emoji in Unicode order, tab-separated fields: emoji, shortcode (with the Mac's overrides applied: `hash`, `asterisk`, `dark_sunglasses`, accented labels rebuilt), label, aliases, CLDR keywords, tone. Aliases and keywords are stored normalized and without the repeats the Mac's index drops anyway, in the Mac's order (word order decides multi-word ties). `EMOJI_SECTIONS` (id, title, first row; the nine standard categories in order) and `EMOJI_POPULAR`.
- `data/quick-reactions.generated.ts`: the quick set (`ReactionPickerEmojis.defaultEmojis`), their tone templates, the legacy acknowledgement marks.

Regenerate from `web/`: `bun tooling/emoji/generate.ts` (`--check` exits 1 when stale). `data.test.ts` fails when the files differ from what the sources generate (it lives in `src/` because the web suite only collects `src/**` tests).

**Skin tones** come from the source: the Mac table lists every toned variant. A base emoji takes a tone when all five uniform-tone variants exist; its tone field is `"1"` (the modifier goes after the first code point, dropping a VS16 there: 316 emoji), the light variant itself whose U+1F3FB marks every place a tone goes (7: 🧑‍🤝‍🧑, 🫱‍🫲 and the like), or empty. The generator checks every tone's variant equals what the field produces. Mixed-tone variants (two people, two tones) are not offered, as on the Mac.

## Drawing emoji

Native glyphs in the platform font, no images (`font.ts`): `"Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji", "Twemoji Mozilla", "Android Emoji", "EmojiSymbols", emoji, sans-serif`, also the `emojiTokens.fontFamily` token. Text-default characters (❤, ☺) carry VS16 in the data, and emoji views set `font-variant-emoji: emoji` (ignored by browsers without it, where VS16 decides). A sent reaction is the exact string chosen.

**Drawability** (`support.ts`): `createEmojiSupport({ probe })` is a seam; the default `canvasEmojiProbe` is `measuredEmojiProbe(canvasGlyphMeasure())`, a second seam (`GlyphMeasure`: advance, ink box, ink and painted pixel counts of one drawn emoji) under a judgement against 😀: advance or ink wider than 1.4 × means a sequence the font split; ink taller than 1.3 × means a glyph from a face with other metrics (it draws clipped in a row sized for emoji); no pixel in a color other than the black fill (when 😀 has some) means a missing glyph, while gray and white emoji (💀, 🤍) still count as painted; nothing drawn fails; with a monochrome emoji font only the shape tests apply, with an unreadable canvas only the advance test. The canvas is 96 × 56 with the 24 px glyph inset, so wide or tall ink is seen whole. `services.warm()` scans every emoji in idle slices of 48. `support.check(emoji)` probes one now if it is not checked yet (the quick row's, about 15 draws on the first open; kept for the page's life; no `revision` bump). Unchecked emoji count as drawable; pickers read the result when they open (nothing disappears under the pointer); the `:` source filters too, and the quick row skips an emoji that cannot draw and takes the next suggestion (from the default set at the end), keeping 15. On Windows, flags draw as letters and the Flags tab is expected to disappear.

## Search (`engine.ts`)

A line-by-line port of `EmojiAutocomplete.suggestions` (`EmojiAutocomplete.swift`): normalize (case and diacritic folding, `+1`/`-1` kept, separators to `_`); terms (shortcode, aliases, keywords, compact forms) and words; tiers exact shortcode 0, alias 3, strong word 10, keyword 14, shortcode prefix 18, alias prefix 20, strong word prefix 23, multi-word 24, keyword prefix 27, compact prefix 28, fuzzy 38, substring 40, plus tightness; one-character queries match exact shortcodes and aliases only, two-character queries complete shortcodes only; fuzzy (one typo, no substitution under five letters) and substring only fill in when strict matches are thin; popularity and frecency lift (usage capped at 7); ties by shorter shortcode, then table order. Compared as UTF-8 bytes as in Swift. All of the Mac's search expectations are in `search.test.ts` (33 first-result cases and the list cases). Building the engine (parse and index) takes about 6 ms and a search about 0.06 ms (Bun on an M-series Mac; a browser on the reference machine is untested).

## Usage (`usage.ts`)

`new EmojiUsage({ store, now })` over an injected `KeyValueStore` (`get`, `set`, `remove`). The Mac's keys and shapes: `chat.inline.emojiUsage.v1` (frecency: usage key → `[count, lastUsedSeconds]`, 160 kept, 10-day half-life), `chat.inline.reactionPicker.emojiUsageCounts.v1` (reaction picks by emoji as shown), `chat.inline.preferredEmojiSkinTone.v1` (`standard`, `light`, `mediumLight`, `medium`, `mediumDark`, `dark`). `record` (an insert), `recordReaction` (a pick: counts and frecency), `removeReactionSuggestion`, `scores()`, `frequentlyUsed(limit, resolve)`, `skinTone`, `setSkinTone`, `revision`. `localStorageKeyValueStore()` is guarded (private windows and quota read as empty and drop writes).

## Pickers

- **Full picker** (`picker.ts`, `EmojiPicker.tsx`): Frequently Used (16) then the nine categories, captured on open; search (160 results) highlights the first so Return picks it; focus stays in the search field with `aria-activedescendant` into the grid; Down enters the grid, Left and Right edit the text until there is a highlight; the grid is its own tab stop (APG grid with `aria-activedescendant`: arrows flow across sections keeping the column, Home, End, Ctrl+Home, Ctrl+End, Page Up, Page Down; typing there searches); Escape clears the search, then closes; arrows mirror in right-to-left. A virtualized grid: rows of 36 px and 28 px headers laid out once, only rows in view plus two each side are rendered (about 13 rows and 95 cells of the 250 rows), positioned by transform; a highlight move re-renders two rows. Category bar (a toolbar with roving focus, active tab follows the scroll), skin tone choices (a radio group: arrows, Return, Escape), a preview line (emoji, name, `:shortcode:`). Width `min(320 px, available)`; columns adapt (8 at 320 px).
- **Reaction picker** (`reaction-picker.ts`, `ReactionPicker.tsx`): the Mac's row (the message's own emoji first, then learned picks by count, then the default set; 15; preferred tone; pressed for yours; only what draws) and a plus button that expands to the full picker in the same popover. Keys: Left, Right (mirrored), Home, End, Return or Space, Down or the plus to expand, a letter to expand searching for it, Delete (or the context menu's "Remove from Suggestions") for a learned pick. Adding records the pick; removing does not. Data loads on open, so the full picker is ready by the time it is asked for. Focus: the kit's popover focuses the first tab stop on open (the row's active button, one roving tab stop); on the first frame after any open, the caller's popover too, the controller focuses the active button again if focus is not in the row (lost to the body, on the opener, or elsewhere in the popover), so a row drawn after the open still ends focused; the row's buttons are keyed by place, so a new row updates them in place and never moves the focused one. With its own popover and an `anchor`, `open()` waits for the anchor to be in the document with a layout box (a frame at a time, up to 30, then opens anyway), so a picker opened in code at start-up is placed at its anchor; on close it returns focus to the anchor when focus was left on the body or in the closed popover (an opener a click did not focus, a call from code). `frame` injects the frame scheduler.
- **Composer button** (`composer-picker.ts`, `ComposerEmojiButton.tsx`): the full picker in a popover above the button; a choice records the use, closes, and calls `onInsert`. Focus goes to the popover while the placeholder shows, to the search field when the picker attaches, back to the button on close. `open()` from code waits for the button's layout as the reaction picker does (`frame.ts`).

## Composer `:` suggestions (`composer-source.ts`)

`createEmojiSuggest({ services })` returns `{ suggest, rows, recordAccepted }`. `suggest(trigger)` has the composer's `SuggestFn` shape, the same as `mentions.suggest`; it answers `emoji` triggers and returns nothing for others. Rows: `id` `emoji-<base>`, `title` `:shortcode:`, `subtitle` the name, `glyph` and `item.text` the emoji in the preferred tone (no trailing space), 8 rows. The trigger is `@inline/composer`'s `detectEmoji`, a port of the Mac detector; it fires from the first character as the Mac's does, and the ranking keeps one-character queries to exact shortcodes and aliases (`:x` → ❌). `minQueryLength` raises the threshold. The Mac converts nothing on a closing colon (`doesNotDetectAfterCompletedShortcode`), so neither does this.

## Wiring (for the integrator)

### App services, once

```ts
// web/src/app/services.ts (or wherever app services live)
import { createEmojiServices, type EmojiChunk, type EmojiServices } from "../features/emoji"
import { signal } from "@inline/reactive"

export const emoji: EmojiServices = createEmojiServices() // usage in localStorage, per device (see "Recents" below)
export const emojiChunk = signal<EmojiChunk | undefined>(undefined)
let chunkLoad: Promise<EmojiChunk> | undefined
export const loadEmojiChunk = () =>
  (chunkLoad ??= import("../features/emoji/chunk").then((chunk) => (emojiChunk.set(chunk), chunk)))

// after first paint (web/src/app/warmup.ts queue):
warmup.add(() => loadEmojiChunk())
warmup.add(() => emoji.warm()) // data chunk + drawability scan, idle lane
```

If even the light half must stay out of the initial bundle, load `features/emoji` with `import()` too and keep `emoji` in a signal; the composer source below already tolerates `undefined`.

### (a) Add Reaction and the hover action

The chat feature's `MessageActions` already opens a popover (`actions.picker`) at the Add Reaction button's rectangle (hover capsule, `run` with `anchor`) or at the row (menu), and sets `actions.pickerTarget`. Replace the body of `ReactionPicker` in `web/src/features/chat/MessageActionLayers.tsx`:

```tsx
import { useModel, useSignal } from "@inline/reactive/react"
import type { MessageTarget } from "@inline/view/features"
import { emoji, emojiChunk } from "../../app/services"

function ReactionPicker(props: { actions: MessageActions }) {
  const { actions } = props
  const chunk = useSignal(emojiChunk)
  if (!chunk) return <QuickFallback actions={actions} /> // today's row, until the chunk arrives
  return <EmojiReactionPicker actions={actions} chunk={chunk} />
}

function EmojiReactionPicker(props: { actions: MessageActions; chunk: EmojiChunk }) {
  const { actions, chunk } = props
  const picker = useModel(
    () =>
      new chunk.ReactionPickerController({
        services: emoji,
        popover: actions.picker,
        target: actions.pickerTarget,
        describe: (value) => {
          const row = (value as MessageTarget).row
          return { messageText: row.text, mine: row.reactions?.filter((r) => r.mine).map((r) => r.emoji) }
        },
        onChoose: (value) => actions.choose(value), // toggles; MessageActions closes the popover
      }),
    [actions, chunk],
  )
  return (
    <PopoverContent controller={actions.picker} style={chunk.reactionPickerPopoverStyle}>
      <chunk.ReactionPickerView controller={picker} />
    </PopoverContent>
  )
}
```

`onChoose` runs while the popover is still open, so `actions.choose` still sees its target. Opening on an emoji before the chunk loads: call `loadEmojiChunk()` from `openPicker` (or rely on the warm-up). `QUICK_REACTIONS` from `features/emoji` is the Mac's 15 for the fallback row (the chat feature's own list of 8 differs from the Mac's).

### (b) The composer: `:` suggestions and the emoji button

In the chat pane where the composer model is created (`web/src/features/chat/`):

```ts
import { createEmojiSuggest } from "../emoji"
import { emoji } from "../../app/services"

const emojiSuggest = createEmojiSuggest({ services: emoji }) // once per pane, or once per app
const model = createComposerModel({
  ...,
  suggest: (trigger) => (trigger.kind === "emoji" ? emojiSuggest.suggest(trigger) : mentions.suggest(trigger)),
})
```

The first `:` starts loading the data and shows nothing; the list fills in when it arrives (the source reads the loader's signal inside the composer's computed). Accepted rows count for recents and frecency by themselves: each row's `onAccept` (the composer's suggestion hook) records it, once per accepted row and never for a dismissed list. Nothing to wire; `recordAccepted` stays for other callers.

The emoji button, in `ComposerView.tsx` (trailing slot, next to send, as the Mac's glass composer shows it when there is nothing to send):

```tsx
const chunk = useSignal(emojiChunk)
const button = useModel(
  () => chunk && new chunk.ComposerEmojiPicker({ services: emoji, onInsert: (value) => { model.composer.insertText(value); model.focus() } }),
  [chunk, model],
)
{button && chunk ? <chunk.ComposerEmojiButton controller={button} /> : null}
```

### (c) Recents and preferences

`createEmojiServices()` stores usage in `localStorage` under the Mac's keys (`USAGE_KEYS`), per device and shared by accounts on it, as the Mac's `UserDefaults` are. It holds which emoji were used, never message text. To keep it per account, pass `store: { get: (k) => localStorage.getItem(`${accountId}:${k}`), ... }`; to drop it on sign-out, remove the three `USAGE_KEYS`. Electron uses the same storage.

## Reaction display

`web/src/features/message/` draws chips today (order and labels in `reactions.ts`); it needs nothing from here to work. Optional upgrades:

- **Font.** Chip emoji in the emoji stack: give the chip's emoji span `fontFamily: emojiTokens.fontFamily, fontVariantEmoji: "emoji"` (`import { emojiTokens } from "../emoji/emoji.stylex"`).
- **Accessible names.** `reactionChipLabel({ emoji, count, mine }, emoji.loader.engine.peek())` gives "thumbs up, 3, including you" once the data is loaded, the emoji itself before.
- **Who reacted.** `reactionTooltip(reactors, viewerId)` builds the Mac's tooltip ("Ada, You"); `ReactionSummary` has no reactor list yet (see "Needs"), so it cannot be wired.

## Differences from the Mac, on purpose

- Skin tones also apply to emoji whose base has VS16 (☝️, ✌️, 🕵️‍♂️, 🏋️ and others): the Mac keys its variant table by the emoji with modifiers removed but VS16 kept, which never matches those bases, so `EmojiSkinTone.applying` leaves them untoned there (`EmojiPickerData.swift` lines 118-120 and 167-190). Here the key is the usage key (modifiers and VS16 removed).
- The full picker has a skin tone selector and a preview line (the Mac sets the tone in Settings and has no preview); the reaction row adds type-to-search and Delete to remove a learned pick (the Mac offers only the context menu, which is here too).
- The reaction row expands into the same popover; the Mac opens the picker as a second popover from the plus.

## Tests

`bunx vitest run src/features/emoji` from `web/`: 7 files, 155 tests. Search against every Mac expectation (`EmojiAutocompleteTests.swift`) and the ranking rules; normalize; tones; the generated data's freshness and shape; frecency, reaction counts and the tone preference (`EmojiUsageStore`, `ReactionPickerEmojisTests.swift`, all ported); the grid's keyboard model and geometry; the full picker (browse capture, tone, drawability filter, virtualization bounds, narrow columns, tabs, search and Return, every key from the field and the grid, right to left, typing, Escape, hover, per-row highlight signals, tone menu); the reaction picker (row building, add and remove recording, keys, type-to-search before the data loads, Delete, target signal and choose order, reopen); the `:` source (lazy load, rows, tone, identity, one-character rule, minimum length); the composer button; the loader's retry; the support scan. `focus.test.ts` (happy-dom, views mirrored by hand since StyleX needs its compiler, frames injected): focus into the reaction row on open when the row renders after the open, arrows, a letter reaching the search, Escape clearing then closing back to the opener, choosing and an outside press returning focus, waiting for an anchor with no layout and being placed on the first frame it has one, the composer picker's focus path and wait. `support.test.ts`: the probe's judgement over a fake measuring seam (split sequences, taller fallback glyphs, fill-color boxes, empty drawings, gray emoji, monochrome fonts, unreadable canvas), the canvas pixel scan over a fake 2D context, `check`, and the quick row skipping and backfilling.

## Not verified in a browser

No dev server or browser was run for this README's last changes. Browser findings in a production labs build (Chromium, macOS) that the fixes target: focus stayed on the body after Add Reaction; `?open=reactionFull` drew the popover at the window's corner (the lab resolved the button before React rendered it; the lookup is now lazy and the open waits); 🫡 drew clipped in the quick row. Unchecked in a browser: that those three are fixed; whether 🫡 fails the new canvas checks there or draws whole and was cut by layout (the strip, which scrolls sideways and so clips top and bottom, now has 2 px of block padding for the 1.1 hover scale); the canvas thresholds against real fonts (false positives on unusual glyphs); the popover's placement and size change when the row expands; focus moving into the search field on expand; Escape clearing the search before the popover's dismiss stack sees it (window-capture listener); 60 fps scrolling and the rendered row count in a real scroller; the canvas probe's results on macOS, Windows (flags) and Linux; `font-variant-emoji` and the font stack; StyleX compiling `fontVariantEmoji` and the dynamic row styles; the context menu inside the popover; light, dark, right to left and narrow widths in the lab.
